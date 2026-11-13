import Foundation

/// Small, fast, seedable PRNG (SplitMix64) so simulations are reproducible.
public struct SplitMix64: RandomNumberGenerator, Codable, Sendable {
    public private(set) var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform double in [0, 1).
    public mutating func unit() -> Double { Double(next() >> 11) * 0x1.0p-53 }
}

/// Dishonest dealer that generates rolls FROM THE SAME HMM the player assumes.
/// The hidden state is exposed only for evaluation, never to the inference engine.
public struct DealerSimulator: Sendable {
    public let parameters: HMMParameters
    public private(set) var rng: SplitMix64
    public private(set) var currentState: DieState?

    public init(parameters: HMMParameters = .classroom, seed: UInt64) {
        self.parameters = parameters
        self.rng = SplitMix64(seed: seed)
    }

    static func sample(_ p: [Double], _ u: Double) -> Int {
        var acc = 0.0
        for (i, w) in p.enumerated() {
            acc += w
            if u < acc { return i }
        }
        return p.count - 1
    }

    public mutating func roll() -> (state: DieState, roll: Int) {
        let probs = currentState.map { parameters.transition[$0.rawValue] } ?? parameters.initial
        let s = DieState(rawValue: Self.sample(probs, rng.unit()))!
        currentState = s
        let face = Self.sample(parameters.emission[s.rawValue], rng.unit()) + 1
        return (s, face)
    }
}

/// Predictive-accuracy evaluation of the live (forward-only) system against ground truth.
public struct SimulationReport: Sendable, CustomStringConvertible {
    public let rolls: Int
    public let seed: UInt64
    public let fractionLoaded: Double
    /// Accuracy of argmax P(S_t | x_1..t) vs true S_t.
    public let filteredStateAccuracy: Double
    /// Accuracy of argmax P(S_{t+1} | x_1..t) vs true S_{t+1}.
    public let predictedStateAccuracy: Double
    /// Accuracy of retrospective Viterbi path vs true path (hindsight — not available live).
    public let viterbiAccuracy: Double
    /// Brier score of P(next = 6) predictions (lower is better) and the baseline of always predicting 1/6.
    public let brierSix: Double
    public let brierSixFairBaseline: Double
    /// Mean predicted P(6) vs observed frequency of 6 (calibration in the large).
    public let meanPredictedSix: Double
    public let observedSixRate: Double
    /// Average log-loss (nats) of the predictive distribution over faces.
    public let predictiveLogLoss: Double
    public let finalBankroll: [String: Double]
    public let betsPlaced: [String: Int]
    /// Total net profit / total amount staked (return per $1 bet).
    public let returnPerDollar: [String: Double]

    public var description: String {
        var s = ""
        s += "Simulated dealer: \(rolls) rolls, seed \(seed)\n"
        s += String(format: "  fraction of rolls truly loaded        %.3f (stationary %.3f)\n", fractionLoaded, HMMParameters.classroom.stationaryLoaded)
        s += String(format: "  filtered state accuracy  (live)       %.3f\n", filteredStateAccuracy)
        s += String(format: "  next-state accuracy      (live)       %.3f\n", predictedStateAccuracy)
        s += String(format: "  Viterbi path accuracy    (hindsight)  %.3f\n", viterbiAccuracy)
        s += String(format: "  Brier score P(next=6): HMM %.4f vs fair-die baseline %.4f\n", brierSix, brierSixFairBaseline)
        s += String(format: "  mean predicted P(6) %.4f vs observed rate %.4f\n", meanPredictedSix, observedSixRate)
        s += String(format: "  predictive log-loss %.4f nats (uniform = %.4f)\n", predictiveLogLoss, log(6.0))
        for k in finalBankroll.keys.sorted() {
            let b = finalBankroll[k]!
            let shown = b < 1e7 ? String(format: "%.2f", b) : String(format: "≈10^%.1f (compounding)", log10(b))
            s += String(format: "  policy %-11@ %5d bets, return per $1 staked %+.3f, bankroll 1000 → %@\n",
                            k, betsPlaced[k] ?? 0, returnPerDollar[k] ?? 0, shown)
        }
        s += "  (The simulated dealer follows the assumed HMM exactly, so this is a best case; see docs on model misspecification.)\n"
        return s
    }

    public static func run(rolls n: Int, seed: UInt64, parameters: HMMParameters = .classroom,
                           startingBankroll: Double = 1000) throws -> SimulationReport {
        var dealer = DealerSimulator(parameters: parameters, seed: seed)
        let draws = (0..<n).map { _ in dealer.roll() }

        var thresholdCfg = BettingConfig.classroom
        thresholdCfg.policy = .thresholds
        var kellyCfg = BettingConfig.classroom
        kellyCfg.policy = .kelly
        var engines: [(String, SessionEngine)] = [
            ("thresholds", try SessionEngine(snapshot: SessionSnapshot(parameters: parameters, betting: thresholdCfg, startingBankroll: startingBankroll))),
            ("kelly-0.25", try SessionEngine(snapshot: SessionSnapshot(parameters: parameters, betting: kellyCfg, startingBankroll: startingBankroll))),
        ]

        var filterOK = 0, predOK = 0, brier = 0.0, brierBase = 0.0, sumP6 = 0.0, sixes = 0, logLoss = 0.0
        var predictedNextLoaded = parameters.initial[1]
        var predictedDist = ForwardFilter.predictiveDistribution(stateProbabilities: parameters.initial, parameters: parameters)

        for (t, d) in draws.enumerated() {
            // Score the prediction made BEFORE this roll.
            if (predictedNextLoaded >= 0.5) == (d.state == .loaded) { predOK += 1 }
            let p6 = predictedDist[5], y = d.roll == 6 ? 1.0 : 0.0
            brier += (p6 - y) * (p6 - y)
            brierBase += (1.0 / 6.0 - y) * (1.0 / 6.0 - y)
            sumP6 += p6; sixes += Int(y)
            logLoss -= log(max(predictedDist[d.roll - 1], 1e-300))

            let obs = Observation(roll: d.roll, source: .dealer, timestamp: Date(timeIntervalSince1970: Double(t)), hiddenState: d.state)
            var first: StepOutcome?
            for i in engines.indices {
                let o = try engines[i].1.append(obs)
                if first == nil { first = o }
            }
            let f = first!.filter
            if (f.posteriorLoaded >= 0.5) == (d.state == .loaded) { filterOK += 1 }
            predictedNextLoaded = f.nextLoaded
            predictedDist = f.nextRollDistribution
        }

        let vit = Viterbi.decode(draws.map { $0.roll }, parameters: parameters).path
        let vitOK = zip(vit, draws).filter { $0.0 == $0.1.state }.count
        let N = Double(n)
        var banks: [String: Double] = [:], bets: [String: Int] = [:], roi: [String: Double] = [:]
        for (name, e) in engines {
            banks[name] = e.bankroll
            let placed = e.outcomes.filter { $0.settled.recommendation.action != .hold }
            bets[name] = placed.count
            let staked = placed.reduce(0.0) { $0 + $1.settled.recommendation.stake }
            roi[name] = staked > 0 ? placed.reduce(0.0) { $0 + $1.settled.profit } / staked : 0
        }
        return SimulationReport(
            rolls: n, seed: seed,
            fractionLoaded: Double(draws.filter { $0.state == .loaded }.count) / N,
            filteredStateAccuracy: Double(filterOK) / N, predictedStateAccuracy: Double(predOK) / N,
            viterbiAccuracy: Double(vitOK) / N,
            brierSix: brier / N, brierSixFairBaseline: brierBase / N,
            meanPredictedSix: sumP6 / N, observedSixRate: Double(sixes) / N,
            predictiveLogLoss: logLoss / N, finalBankroll: banks, betsPlaced: bets, returnPerDollar: roi)
    }
}
