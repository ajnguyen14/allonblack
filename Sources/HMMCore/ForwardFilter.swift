import Foundation

/// Everything the forward filter knows after processing roll t.
///
/// The naming deliberately separates the two quantities students confuse most:
/// - `posteriorLoaded`  = P(S_t     = L | x_1..x_t)   — "is the die that JUST rolled loaded?"  (filtering)
/// - `nextLoaded`       = P(S_{t+1} = L | x_1..x_t)   — "will the NEXT die be loaded?"         (prediction)
/// Betting uses only the prediction, because the bet is on roll t+1.
public struct FilterStep: Codable, Equatable, Sendable {
    /// 1-based roll number t.
    public let index: Int
    /// Observed face, or nil if the announcement was missed.
    public let observation: Int?
    /// P(S_t = L | x_1..x_{t-1}) — what we believed about this roll BEFORE seeing it.
    public let priorLoaded: Double
    /// P(S_t = L | x_1..x_t) — filtered posterior for the current (just-observed) roll.
    public let posteriorLoaded: Double
    /// P(S_{t+1} = L | x_1..x_t) — one-step-ahead predicted state probability.
    public let nextLoaded: Double
    /// P(X_{t+1} = k | x_1..x_t) for k = 1...6 — posterior predictive distribution.
    public let nextRollDistribution: [Double]
    /// log P(x_1..x_t) (natural log), accumulated from the scaling constants.
    public let logLikelihood: Double

    public var nextSixProbability: Double { nextRollDistribution[5] }
}

/// Scaled (normalised) forward recursion for a 2-state HMM.
///
/// Recursion, with p_t = P(S_t | x_1..x_{t-1}) and f_t = P(S_t | x_1..x_t):
///   p_1      = π
///   f_t(i)   = p_t(i) e_i(x_t) / c_t,      c_t = Σ_i p_t(i) e_i(x_t) = P(x_t | x_1..x_{t-1})
///   p_{t+1}  = f_t · A
///   P(X_{t+1}=k | x_1..x_t) = Σ_j p_{t+1}(j) e_j(k)
/// Normalising every step keeps all quantities in [0, 1], so the filter is stable
/// for arbitrarily long sequences; log P(x_1..x_t) = Σ log c_t is kept separately.
public struct ForwardFilter: Sendable {
    public let parameters: HMMParameters
    /// P(S_{t+1} | x_1..x_t); equals the initial distribution before any roll.
    public private(set) var predicted: [Double]
    /// P(S_t | x_1..x_t); nil before the first roll.
    public private(set) var filtered: [Double]?
    public private(set) var logLikelihood: Double = 0
    public private(set) var count: Int = 0

    public init(parameters: HMMParameters = .classroom) throws {
        try parameters.validate()
        self.parameters = parameters
        self.predicted = parameters.initial
    }

    /// Probability that the next (not yet observed) die is loaded.
    public var nextLoaded: Double { predicted[1] }

    /// Posterior predictive distribution of the next face.
    public var nextRollDistribution: [Double] {
        Self.predictiveDistribution(stateProbabilities: predicted, parameters: parameters)
    }

    public static func predictiveDistribution(stateProbabilities p: [Double], parameters: HMMParameters) -> [Double] {
        let dist = (1...HMMParameters.faceCount).map { k in
            (0..<HMMParameters.stateCount).reduce(0.0) { $0 + p[$1] * parameters.emissionProbability(state: $1, roll: k) }
        }
        return normalized(dist)
    }

    /// Incorporates one observation (nil = missed roll) and returns the full step summary.
    @discardableResult
    public mutating func update(_ roll: Int?) throws -> FilterStep {
        if let roll, !(1...HMMParameters.faceCount).contains(roll) { throw HMMError.invalidRoll(roll) }

        let prior = predicted
        let joint = (0..<HMMParameters.stateCount).map { prior[$0] * parameters.emissionProbability(state: $0, roll: roll) }
        let c = joint.reduce(0, +)
        guard c > 0, c.isFinite else { throw HMMError.impossibleObservation(index: count + 1) }

        let f = Self.normalized(joint.map { $0 / c })
        let next = Self.normalized((0..<HMMParameters.stateCount).map { j in
            (0..<HMMParameters.stateCount).reduce(0.0) { $0 + f[$1] * parameters.transition[$1][j] }
        })

        filtered = f
        predicted = next
        logLikelihood += log(c)
        count += 1

        return FilterStep(
            index: count,
            observation: roll,
            priorLoaded: prior[1],
            posteriorLoaded: f[1],
            nextLoaded: next[1],
            nextRollDistribution: nextRollDistribution,
            logLikelihood: logLikelihood
        )
    }

    /// Renormalises and clamps away floating-point drift (sums slightly off 1,
    /// values like -1e-18). Inputs are non-negative with a positive sum.
    static func normalized(_ v: [Double]) -> [Double] {
        let clamped = v.map { $0.isFinite ? max(0, $0) : 0 }
        let s = clamped.reduce(0, +)
        guard s > 0 else { return Array(repeating: 1.0 / Double(v.count), count: v.count) }
        return clamped.map { min(1, $0 / s) }
    }
}
