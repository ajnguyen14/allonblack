import Foundation

public enum BetAction: String, Codable, Sendable, CaseIterable {
    case hold, small, big

    /// Number of 150 ms phone vibrations used to signal the action.
    public var vibrationPulses: Int {
        switch self {
        case .hold: return 0
        case .small: return 1
        case .big: return 2
        }
    }

    public var label: String {
        switch self {
        case .hold: return "HOLD"
        case .small: return "SMALL BET ON 6"
        case .big: return "BIG BET ON 6"
        }
    }

    public var vibrationDescription: String {
        switch self {
        case .hold: return "no vibration"
        case .small: return "1 × 150 ms"
        case .big: return "2 × 150 ms, 200 ms gap"
        }
    }
}

public enum BettingPolicy: String, Codable, Sendable, CaseIterable {
    /// The classroom rule: EV sign + fixed thresholds on P(next die loaded).
    case thresholds
    /// Expected-log-utility alternative: fractional Kelly stake, capped.
    case kelly
}

public struct BettingConfig: Codable, Equatable, Sendable {
    /// Net profit per unit staked when the bet wins ("4:1").
    public var netPayout: Double = 4
    public var smallLoadedThreshold: Double = 0.35
    public var bigLoadedThreshold: Double = 0.65
    public var smallStakeFraction: Double = 0.005
    public var bigStakeFraction: Double = 0.02
    public var policy: BettingPolicy = .thresholds
    /// Fraction of full Kelly used by the `.kelly` policy.
    public var kellyMultiplier: Double = 0.25

    public init() {}
    public static let classroom = BettingConfig()
}

/// The recommendation for an upcoming roll, made BEFORE that roll is observed.
public struct BetRecommendation: Codable, Equatable, Sendable {
    /// Index (1-based) of the roll this bet is for.
    public let forRoll: Int
    public let action: BetAction
    public let nextLoaded: Double
    public let nextSixProbability: Double
    /// Expected net profit per 1 unit staked: (b+1)·P(6) − 1 (= 5·P(6) − 1 at 4:1).
    public let expectedValue: Double
    /// Full-Kelly fraction max(0, EV / b), shown for reference in both policies.
    public let kellyFraction: Double
    /// Simulated currency staked (0 for hold).
    public let stake: Double
    public let reason: String
}

public enum BettingEngine {
    public static func expectedValue(sixProbability p: Double, netPayout b: Double = 4) -> Double {
        (b + 1) * p - 1
    }

    public static func kellyFraction(sixProbability p: Double, netPayout b: Double = 4) -> Double {
        max(0, expectedValue(sixProbability: p, netPayout: b) / b)
    }

    public static func recommend(forRoll: Int, nextLoaded: Double, nextSixProbability pSix: Double,
                                 bankroll: Double, config: BettingConfig = .classroom) -> BetRecommendation {
        let ev = expectedValue(sixProbability: pSix, netPayout: config.netPayout)
        let kelly = kellyFraction(sixProbability: pSix, netPayout: config.netPayout)
        let action: BetAction
        let fraction: Double
        let reason: String

        switch config.policy {
        case .thresholds:
            if ev <= 0 {
                action = .hold; fraction = 0
                reason = String(format: "EV %+.3f ≤ 0", ev)
            } else if nextLoaded < config.smallLoadedThreshold {
                action = .hold; fraction = 0
                reason = String(format: "P(next L) %.1f%% < %.0f%%", nextLoaded * 100, config.smallLoadedThreshold * 100)
            } else if nextLoaded < config.bigLoadedThreshold {
                action = .small; fraction = config.smallStakeFraction
                reason = String(format: "EV > 0 and %.0f%% ≤ P(next L) < %.0f%%", config.smallLoadedThreshold * 100, config.bigLoadedThreshold * 100)
            } else {
                action = .big; fraction = config.bigStakeFraction
                reason = String(format: "EV > 0 and P(next L) ≥ %.0f%%", config.bigLoadedThreshold * 100)
            }
        case .kelly:
            let f = min(config.kellyMultiplier * kelly, config.bigStakeFraction)
            if f <= 0 {
                action = .hold; fraction = 0
                reason = "Kelly stake is 0 (EV ≤ 0)"
            } else if f >= config.bigStakeFraction / 2 {
                action = .big; fraction = f
                reason = String(format: "%.2f×Kelly = %.2f%% of bankroll (cap %.1f%%)", config.kellyMultiplier, f * 100, config.bigStakeFraction * 100)
            } else {
                action = .small; fraction = f
                reason = String(format: "%.2f×Kelly = %.2f%% of bankroll", config.kellyMultiplier, f * 100)
            }
        }

        return BetRecommendation(forRoll: forRoll, action: action, nextLoaded: nextLoaded,
                                 nextSixProbability: pSix, expectedValue: ev, kellyFraction: kelly,
                                 stake: max(0, bankroll) * fraction, reason: reason)
    }
}

/// Guarantees at most one vibration per recommendation (i.e. per recognised roll),
/// even if the UI re-renders, a speech result is delivered twice, or the same
/// recommendation is re-published.
public struct SignalGate: Codable, Equatable, Sendable {
    public private(set) var lastSignaledRoll: Int = 0
    public init() {}

    /// Returns true exactly once for each new `forRoll` index (and never for older ones).
    public mutating func shouldSignal(_ rec: BetRecommendation) -> Bool {
        guard rec.forRoll > lastSignaledRoll else { return false }
        lastSignaledRoll = rec.forRoll
        return rec.action.vibrationPulses > 0
    }

    public mutating func reset() { lastSignaledRoll = 0 }
}
