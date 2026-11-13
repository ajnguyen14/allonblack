import Foundation

public enum RollRejection: Equatable, Sendable, CustomStringConvertible {
    case empty
    case noNumber
    case outOfRange(Int)
    case ambiguous([Int])
    case lowConfidence(Double)
    case homophoneNeedsIsolation(String)
    case duplicate(Int)

    public var description: String {
        switch self {
        case .empty: return "nothing heard"
        case .noNumber: return "no die number in utterance"
        case .outOfRange(let n): return "\(n) is not a die face"
        case .ambiguous(let ns): return "ambiguous: heard \(ns.map(String.init).joined(separator: " and "))"
        case .lowConfidence(let c): return String(format: "low confidence (%.2f)", c)
        case .homophoneNeedsIsolation(let w): return "\"\(w)\" only accepted when spoken alone"
        case .duplicate(let n): return "duplicate announcement of \(n) ignored"
        }
    }
}

public enum RollParseResult: Equatable, Sendable {
    case accepted(Int)
    case rejected(RollRejection)

    public var roll: Int? { if case .accepted(let r) = self { return r }; return nil }
}

/// Converts a speech transcript ("six!", "It's a 6", "two") into a die face, or a
/// reason for rejecting it. Conservative by design: a wrong observation corrupts the
/// posterior, while a rejected one can simply be re-announced or tapped manually.
public struct RollParser: Sendable {
    /// Minimum mean segment confidence (SFTranscriptionSegment.confidence, 0–1).
    public var minimumConfidence: Double

    public init(minimumConfidence: Double = 0.40) { self.minimumConfidence = minimumConfidence }

    static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "zero": 0, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    ]
    /// Words speech recognisers commonly return for a spoken die number. They are
    /// also ordinary English words, so they only count when they are the entire utterance.
    static let homophones: [String: Int] = [
        "won": 1, "to": 2, "too": 2, "tu": 2, "for": 4, "fore": 4, "sex": 6, "sicks": 6, "sics": 6, "fiv": 5, "free": 3,
    ]

    public static func tokens(_ transcript: String) -> [String] {
        transcript.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// - Parameter confidence: mean segment confidence, or nil if the recogniser did not provide one.
    ///   When confidence is unavailable, only utterances of at most three words are accepted.
    public func parse(_ transcript: String, confidence: Double?) -> RollParseResult {
        let toks = Self.tokens(transcript)
        guard !toks.isEmpty else { return .rejected(.empty) }

        var numbers: [Int] = []
        for t in toks {
            if let n = Self.numberWords[t] { numbers.append(n) }
            else if let n = Int(t) { numbers.append(n) }
        }
        if numbers.isEmpty {
            if toks.count == 1, let h = Self.homophones[toks[0]] { numbers = [h] }
            else if let h = toks.first(where: { Self.homophones[$0] != nil }) {
                return .rejected(toks.count > 1 ? .homophoneNeedsIsolation(h) : .noNumber)
            } else { return .rejected(.noNumber) }
        }

        let distinct = Array(Set(numbers)).sorted()
        // "six ... six" (dealer repeating themself) is one announcement; "two six" is ambiguous.
        guard distinct.count == 1 else { return .rejected(.ambiguous(distinct)) }
        let n = distinct[0]
        guard (1...6).contains(n) else { return .rejected(.outOfRange(n)) }

        if let c = confidence {
            guard c >= minimumConfidence else { return .rejected(.lowConfidence(c)) }
        } else if toks.count > 3 {
            return .rejected(.lowConfidence(0))
        }
        return .accepted(n)
    }
}

/// Prevents one physical announcement from being recorded twice (e.g. the
/// recogniser emitting the same final result twice, or a dealer repeating
/// "six... six"). A repeat of the same value inside `window` seconds is dropped.
/// Genuine consecutive equal rolls are separated by a physical roll and are
/// normally further apart; the window is configurable, and manual entry bypasses it.
public struct AnnouncementDeduplicator: Sendable {
    public var window: TimeInterval
    private var last: (value: Int, time: Date)?
    private var seenUtterances: Set<UUID> = []

    public init(window: TimeInterval = 2.5) { self.window = window }

    public mutating func admit(_ value: Int, at time: Date, utterance: UUID? = nil) -> Bool {
        if let u = utterance {
            guard !seenUtterances.contains(u) else { return false }
            seenUtterances.insert(u)
        }
        if let l = last, l.value == value, time.timeIntervalSince(l.time) < window { return false }
        last = (value, time)
        return true
    }

    public mutating func reset() { last = nil; seenUtterances.removeAll() }
}
