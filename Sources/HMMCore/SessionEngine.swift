import Foundation

public enum ObservationSource: String, Codable, Sendable {
    case manual, speech, dealer, missed, replay
}

/// One recorded observation. Observations are the ONLY persisted ground data;
/// every probability and recommendation is recomputed from them.
public struct Observation: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// Face 1–6, or nil if the roll happened but its value was missed.
    public var roll: Int?
    public var source: ObservationSource
    public var timestamp: Date
    public var transcript: String?
    public var confidence: Double?
    /// Hidden truth — only known in simulated-dealer mode, never used for inference.
    public var hiddenState: DieState?

    public init(id: UUID = UUID(), roll: Int?, source: ObservationSource, timestamp: Date = Date(),
                transcript: String? = nil, confidence: Double? = nil, hiddenState: DieState? = nil) {
        self.id = id; self.roll = roll; self.source = source; self.timestamp = timestamp
        self.transcript = transcript; self.confidence = confidence; self.hiddenState = hiddenState
    }
}

public struct SettledBet: Codable, Equatable, Sendable {
    public let recommendation: BetRecommendation
    public let outcomeRoll: Int?
    /// Net change to the bankroll (0 for hold or a void bet on a missed roll).
    public let profit: Double
    public var isVoid: Bool { outcomeRoll == nil && recommendation.action != .hold }
}

/// Result of processing one observation.
public struct StepOutcome: Codable, Equatable, Sendable {
    public let observation: Observation
    public let filter: FilterStep
    /// The bet that had been recommended for THIS roll, now resolved.
    public let settled: SettledBet
    /// Recommendation for the NEXT roll (what the phone vibrates).
    public let next: BetRecommendation
    public let bankroll: Double
}

/// Serializable snapshot — enough to rebuild the whole session deterministically.
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public var parameters: HMMParameters
    public var betting: BettingConfig
    public var startingBankroll: Double
    public var observations: [Observation]

    public init(parameters: HMMParameters = .classroom, betting: BettingConfig = .classroom,
                startingBankroll: Double = 1000, observations: [Observation] = []) {
        self.parameters = parameters; self.betting = betting
        self.startingBankroll = startingBankroll; self.observations = observations
    }
}

/// Owns one simulation session: observations → forward filter → bet ledger.
public struct SessionEngine: Sendable {
    public private(set) var snapshot: SessionSnapshot
    public private(set) var filter: ForwardFilter
    public private(set) var outcomes: [StepOutcome] = []
    public private(set) var bankroll: Double
    /// Recommendation for the upcoming roll (before any roll: based on the prior).
    public private(set) var pending: BetRecommendation

    public init(snapshot: SessionSnapshot = SessionSnapshot()) throws {
        var fresh = snapshot
        fresh.observations = []
        self.snapshot = fresh
        self.filter = try ForwardFilter(parameters: snapshot.parameters)
        self.bankroll = snapshot.startingBankroll
        self.pending = Self.recommendation(filter: filter, forRoll: 1, bankroll: snapshot.startingBankroll, config: snapshot.betting)
        for obs in snapshot.observations { try append(obs) }
    }

    static func recommendation(filter: ForwardFilter, forRoll: Int, bankroll: Double, config: BettingConfig) -> BetRecommendation {
        BettingEngine.recommend(forRoll: forRoll, nextLoaded: filter.nextLoaded,
                                nextSixProbability: filter.nextRollDistribution[5],
                                bankroll: bankroll, config: config)
    }

    public var observations: [Observation] { snapshot.observations }
    public var parameters: HMMParameters { snapshot.parameters }
    public var betting: BettingConfig { snapshot.betting }

    /// Settles the pending bet against `obs`, updates the filter, and produces the next recommendation.
    @discardableResult
    public mutating func append(_ obs: Observation) throws -> StepOutcome {
        var trial = filter
        let step = try trial.update(obs.roll)   // throws before any state is mutated

        let bet = pending
        let profit: Double
        switch (bet.action, obs.roll) {
        case (.hold, _), (_, nil): profit = 0                       // no bet, or void bet on a missed roll
        case (_, 6?): profit = bet.stake * snapshot.betting.netPayout
        default: profit = -bet.stake
        }

        filter = trial
        bankroll += profit
        snapshot.observations.append(obs)
        let next = Self.recommendation(filter: filter, forRoll: step.index + 1, bankroll: bankroll, config: snapshot.betting)
        pending = next

        let outcome = StepOutcome(observation: obs, filter: step,
                                  settled: SettledBet(recommendation: bet, outcomeRoll: obs.roll, profit: profit),
                                  next: next, bankroll: bankroll)
        outcomes.append(outcome)
        return outcome
    }

    /// Rebuilds from scratch with new settings (keeps the observation history).
    public func reconfigured(parameters: HMMParameters? = nil, betting: BettingConfig? = nil,
                             startingBankroll: Double? = nil) throws -> SessionEngine {
        var s = snapshot
        if let parameters { s.parameters = parameters }
        if let betting { s.betting = betting }
        if let startingBankroll { s.startingBankroll = startingBankroll }
        return try SessionEngine(snapshot: s)
    }

    /// Removes the last observation (for correcting a mis-recognition).
    public func removingLast() throws -> SessionEngine {
        var s = snapshot
        if !s.observations.isEmpty { s.observations.removeLast() }
        return try SessionEngine(snapshot: s)
    }

    /// Retrospective most-likely path (display only; never used for betting).
    public var viterbiPath: [DieState] { Viterbi.decode(snapshot.observations.map(\.roll), parameters: parameters).path }

    /// View model for the state after the first `count` observations (used by live view and replay).
    public func display(after count: Int) -> DisplayState {
        let n = max(0, min(count, outcomes.count))
        if n == 0 {
            let f = try! ForwardFilter(parameters: parameters)
            let rec = Self.recommendation(filter: f, forRoll: 1, bankroll: snapshot.startingBankroll, config: betting)
            return DisplayState(rollCount: 0, latestRoll: nil, latestWasMissed: false, currentLoaded: nil,
                                nextLoaded: f.nextLoaded, nextDistribution: f.nextRollDistribution,
                                recommendation: rec, bankroll: snapshot.startingBankroll, lastSettled: nil)
        }
        let o = outcomes[n - 1]
        return DisplayState(rollCount: n, latestRoll: o.observation.roll, latestWasMissed: o.observation.roll == nil,
                            currentLoaded: o.filter.posteriorLoaded, nextLoaded: o.filter.nextLoaded,
                            nextDistribution: o.filter.nextRollDistribution, recommendation: o.next,
                            bankroll: o.bankroll, lastSettled: o.settled)
    }
}

public struct DisplayState: Equatable, Sendable {
    public let rollCount: Int
    public let latestRoll: Int?
    public let latestWasMissed: Bool
    /// P(S_t = L | x_1..t); nil before any roll.
    public let currentLoaded: Double?
    /// P(S_{t+1} = L | x_1..t)
    public let nextLoaded: Double
    public let nextDistribution: [Double]
    public let recommendation: BetRecommendation
    public let bankroll: Double
    public let lastSettled: SettledBet?

    public var nextSixProbability: Double { nextDistribution[5] }
}
