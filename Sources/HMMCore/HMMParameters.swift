import Foundation

/// Hidden state of the dealer's die.
public enum DieState: Int, Codable, CaseIterable, Sendable {
    case fair = 0
    case loaded = 1

    public var symbol: String { self == .fair ? "F" : "L" }
}

public enum HMMError: Error, Equatable, CustomStringConvertible {
    case invalidParameters(String)
    case invalidRoll(Int)
    /// The observation has zero probability under every state given the past.
    case impossibleObservation(index: Int)

    public var description: String {
        switch self {
        case .invalidParameters(let why): return "Invalid HMM parameters: \(why)"
        case .invalidRoll(let r): return "Invalid roll \(r); must be 1–6"
        case .impossibleObservation(let i): return "Observation \(i) has zero probability under the model"
        }
    }
}

/// Two-state (Fair / Loaded) HMM over die faces 1–6.
///
/// Conventions (state index 0 = F, 1 = L):
/// - `initial[i]`        = P(S_1 = i)                  — the hidden state of the FIRST roll
/// - `transition[i][j]`  = P(S_{t+1} = j | S_t = i)
/// - `emission[i][k-1]`  = P(X_t = k | S_t = i)
public struct HMMParameters: Codable, Equatable, Sendable {
    public var initial: [Double]
    public var transition: [[Double]]
    public var emission: [[Double]]

    public init(initial: [Double], transition: [[Double]], emission: [[Double]]) {
        self.initial = initial
        self.transition = transition
        self.emission = emission
    }

    /// Parameters specified for the BioE 131/231 classroom demonstration.
    public static let classroom = HMMParameters(
        initial: [0.80, 0.20],
        transition: [
            [0.95, 0.05], // F -> F, F -> L
            [0.10, 0.90], // L -> F, L -> L
        ],
        emission: [
            Array(repeating: 1.0 / 6.0, count: 6),
            [0.10, 0.10, 0.10, 0.10, 0.10, 0.50],
        ]
    )

    public static let stateCount = 2
    public static let faceCount = 6

    public func validate(tolerance: Double = 1e-9) throws {
        func checkDistribution(_ v: [Double], _ name: String, count: Int) throws {
            guard v.count == count else { throw HMMError.invalidParameters("\(name) must have \(count) entries") }
            guard v.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw HMMError.invalidParameters("\(name) has negative or non-finite entries")
            }
            let s = v.reduce(0, +)
            guard abs(s - 1) <= tolerance else { throw HMMError.invalidParameters("\(name) sums to \(s), not 1") }
        }
        try checkDistribution(initial, "initial", count: Self.stateCount)
        guard transition.count == Self.stateCount, emission.count == Self.stateCount else {
            throw HMMError.invalidParameters("need exactly \(Self.stateCount) transition and emission rows")
        }
        for i in 0..<Self.stateCount {
            try checkDistribution(transition[i], "transition row \(i)", count: Self.stateCount)
            try checkDistribution(emission[i], "emission row \(i)", count: Self.faceCount)
        }
    }

    /// P(X = roll | S = state). A missing observation (`nil`) carries no
    /// information, so its "emission" is 1 for every state (it marginalises out).
    @inline(__always)
    public func emissionProbability(state: Int, roll: Int?) -> Double {
        guard let roll else { return 1.0 }
        return emission[state][roll - 1]
    }

    /// Long-run fraction of time the die is loaded: a / (a + b), a = P(F→L), b = P(L→F).
    public var stationaryLoaded: Double {
        let a = transition[0][1], b = transition[1][0]
        return a / (a + b)
    }
}
