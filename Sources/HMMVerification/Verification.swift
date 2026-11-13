import Foundation
import HMMCore

public struct CheckResult: Sendable {
    public let name: String
    public let failures: [String]
    public var passed: Bool { failures.isEmpty }
}

/// Independent reference computations used to verify the production filter.
public enum BruteForce {
    /// Enumerates all 2^T hidden paths. Returns (P(S_T = L | x), P(S_{T+1} = L | x),
    /// P(X_{T+1} = k | x), P(x)). Missing observations are marginalised out.
    public static func posterior(_ xs: [Int?], _ p: HMMParameters = .classroom)
        -> (current: Double, next: Double, nextDist: [Double], evidence: Double) {
        let T = xs.count
        precondition(T >= 1 && T <= 20)
        var endMass = [0.0, 0.0], total = 0.0
        for mask in 0..<(1 << T) {
            var prob = 1.0
            var prev = -1
            for t in 0..<T {
                let s = (mask >> t) & 1
                prob *= (t == 0 ? p.initial[s] : p.transition[prev][s])
                if let x = xs[t] { prob *= p.emission[s][x - 1] }
                prev = s
            }
            endMass[(mask >> (T - 1)) & 1] += prob
            total += prob
        }
        let cur = endMass[1] / total
        let fF = endMass[0] / total
        let next = fF * p.transition[0][1] + cur * p.transition[1][1]
        let dist = (0..<6).map { k in (1 - next) * p.emission[0][k] + next * p.emission[1][k] }
        return (cur, next, dist, total)
    }

    /// Exhaustive most-probable path (ties broken toward the first found).
    public static func bestPath(_ xs: [Int?], _ p: HMMParameters = .classroom) -> ([DieState], Double) {
        let T = xs.count
        var best = -1.0, bestMask = 0
        for mask in 0..<(1 << T) {
            var prob = 1.0, prev = -1
            for t in 0..<T {
                let s = (mask >> t) & 1
                prob *= (t == 0 ? p.initial[s] : p.transition[prev][s])
                if let x = xs[t] { prob *= p.emission[s][x - 1] }
                prev = s
            }
            if prob > best { best = prob; bestMask = mask }
        }
        return ((0..<T).map { DieState(rawValue: (bestMask >> $0) & 1)! }, log(best))
    }
}

public enum VerificationSuite {
    public static let demoSequence: [Int?] = [2, 6, 6, 1, 6, 6]

    public static func runAll() -> [CheckResult] {
        [
            check("Parameters validate; bad parameters rejected", parameters),
            check("Roll 1 matches hand calculation", firstRollByHand),
            check("Forward filter == brute-force enumeration (demo sequence, every prefix)", demoVsBruteForce),
            check("Forward filter == brute force on 300 random sequences incl. missing rolls", randomVsBruteForce),
            check("Predictive identities: Σ=1, P(6)=1/6+P(L)/3, next = f·A", predictiveIdentities),
            check("Missing observation = pure prediction step", missingObservation),
            check("Numerical stability over 200,000 rolls", stability),
            check("Log-likelihood == log of brute-force evidence", logLikelihood),
            check("Viterbi == exhaustive best path", viterbi),
            check("EV formula and betting thresholds (boundaries)", bettingRules),
            check("EV floor: with these parameters EV(six) is never negative", evFloor),
            check("Kelly alternative policy", kellyPolicy),
            check("Demo sequence decisions and bankroll ledger", demoDecisions),
            check("Signal gate: one vibration per roll", signalGate),
            check("Speech parser: accept/reject rules", parser),
            check("Duplicate announcement protection", dedupe),
            check("Session persistence round-trip reproduces every number", persistence),
            check("Invalid roll leaves session unchanged", invalidRoll),
            check("Simulated dealer: deterministic, stationary, calibrated", simulator),
        ]
    }

    // MARK: - helpers

    final class Collector {
        var failures: [String] = []
        func expect(_ cond: Bool, _ msg: @autoclosure () -> String) { if !cond { failures.append(msg()) } }
        func close(_ a: Double, _ b: Double, tol: Double = 1e-12, _ what: @autoclosure () -> String) {
            if !(abs(a - b) <= tol) { failures.append("\(what()): got \(a), expected \(b) (|Δ|=\(abs(a - b)))") }
        }
    }

    static func check(_ name: String, _ body: (Collector) throws -> Void) -> CheckResult {
        let c = Collector()
        do { try body(c) } catch { c.failures.append("threw \(error)") }
        return CheckResult(name: name, failures: c.failures)
    }

    // MARK: - checks

    static func parameters(_ c: Collector) throws {
        try HMMParameters.classroom.validate()
        var bad = HMMParameters.classroom
        bad.transition[0] = [0.9, 0.2]
        c.expect((try? bad.validate()) == nil, "row summing to 1.1 accepted")
        bad = .classroom; bad.emission[1][5] = -0.1
        c.expect((try? bad.validate()) == nil, "negative emission accepted")
        c.close(HMMParameters.classroom.stationaryLoaded, 1.0 / 3.0, "stationary P(L)")
    }

    static func firstRollByHand(_ c: Collector) throws {
        var f = try ForwardFilter()
        // Before any roll the prediction is the initial distribution.
        c.close(f.nextLoaded, 0.2, "prior P(L)")
        c.close(f.nextRollDistribution[5], 0.8 / 6 + 0.2 * 0.5, "prior P(6)")
        let s = try f.update(2)
        // f_1(L) = 0.2·0.1 / (0.8/6 + 0.2·0.1) = 0.02 / 0.153333… = 3/23
        c.close(s.posteriorLoaded, 3.0 / 23.0, "P(S1=L|2)")
        // p_2(L) = (3/23)·0.9 + (20/23)·0.05 = 3.7/23
        c.close(s.nextLoaded, 3.7 / 23.0, "P(S2=L|2)")
        c.close(s.nextSixProbability, 1.0 / 6.0 + (3.7 / 23.0) / 3.0, "P(X2=6|2)")
    }

    static func demoVsBruteForce(_ c: Collector) throws {
        var f = try ForwardFilter()
        for t in 1...demoSequence.count {
            let s = try f.update(demoSequence[t - 1])
            let b = BruteForce.posterior(Array(demoSequence[0..<t]))
            c.close(s.posteriorLoaded, b.current, "t=\(t) posterior")
            c.close(s.nextLoaded, b.next, "t=\(t) next")
            for k in 0..<6 { c.close(s.nextRollDistribution[k], b.nextDist[k], "t=\(t) P(next=\(k + 1))") }
        }
    }

    static func randomVsBruteForce(_ c: Collector) throws {
        var rng = SplitMix64(seed: 7)
        for trial in 0..<300 {
            let T = 1 + Int(rng.next() % 12)
            let xs: [Int?] = (0..<T).map { _ in rng.unit() < 0.1 ? nil : Int(rng.next() % 6) + 1 }
            var f = try ForwardFilter()
            var last: FilterStep!
            for x in xs { last = try f.update(x) }
            let b = BruteForce.posterior(xs)
            c.close(last.posteriorLoaded, b.current, tol: 1e-10, "trial \(trial) \(xs) posterior")
            c.close(last.nextLoaded, b.next, tol: 1e-10, "trial \(trial) next")
            c.close(last.nextSixProbability, b.nextDist[5], tol: 1e-10, "trial \(trial) P(6)")
        }
    }

    static func predictiveIdentities(_ c: Collector) throws {
        var f = try ForwardFilter()
        for x in [6, 6, 6, 1, 2, 6, 3, 4, 5, 6, 6] {
            let s = try f.update(x)
            c.close(s.nextRollDistribution.reduce(0, +), 1, tol: 1e-12, "Σ P(next)")
            c.close(s.nextSixProbability, 1.0 / 6.0 + s.nextLoaded / 3.0, tol: 1e-12, "P(6) identity")
            for k in 0..<5 { c.close(s.nextRollDistribution[k], 1.0 / 6.0 - s.nextLoaded / 15.0, tol: 1e-12, "P(\(k + 1)) identity") }
            let expectNext = s.posteriorLoaded * 0.90 + (1 - s.posteriorLoaded) * 0.05
            c.close(s.nextLoaded, expectNext, tol: 1e-12, "p_{t+1} = f_t·A")
        }
    }

    static func missingObservation(_ c: Collector) throws {
        var f = try ForwardFilter()
        try f.update(6)
        let before = f.nextLoaded
        let s = try f.update(nil)
        c.close(s.posteriorLoaded, before, "missing roll: posterior should equal prior")
        c.close(s.nextLoaded, before * 0.9 + (1 - before) * 0.05, "missing roll: one transition step")
        // Many missing rolls converge to the stationary distribution.
        for _ in 0..<500 { try f.update(nil) }
        c.close(f.nextLoaded, 1.0 / 3.0, tol: 1e-9, "missing rolls → stationary")
    }

    static func stability(_ c: Collector) throws {
        for pattern in [[6], [1], [6, 6, 6, 1], [2, 3]] {
            var f = try ForwardFilter()
            for i in 0..<200_000 {
                let s = try f.update(pattern[i % pattern.count])
                if !(s.posteriorLoaded.isFinite && (0...1).contains(s.posteriorLoaded) && (0...1).contains(s.nextLoaded)) {
                    c.expect(false, "pattern \(pattern) roll \(i) produced \(s.posteriorLoaded)"); break
                }
            }
            c.expect(f.logLikelihood.isFinite && f.logLikelihood < 0, "pattern \(pattern) log-likelihood \(f.logLikelihood)")
        }
        // A naive unscaled forward pass underflows to 0 here; ours must not.
        var f = try ForwardFilter()
        for _ in 0..<5000 { try f.update(1) }
        c.expect(f.logLikelihood > -1e5 && f.logLikelihood.isFinite, "log-likelihood underflow")
    }

    static func logLikelihood(_ c: Collector) throws {
        let xs: [Int?] = [2, 6, nil, 6, 1, 6, 6, 3]
        var f = try ForwardFilter()
        for x in xs { try f.update(x) }
        c.close(f.logLikelihood, log(BruteForce.posterior(xs).evidence), tol: 1e-10, "log P(x)")
    }

    static func viterbi(_ c: Collector) throws {
        var rng = SplitMix64(seed: 99)
        for trial in 0..<200 {
            let T = 1 + Int(rng.next() % 12)
            let xs: [Int?] = (0..<T).map { _ in rng.unit() < 0.1 ? nil : Int(rng.next() % 6) + 1 }
            let v = Viterbi.decode(xs)
            let b = BruteForce.bestPath(xs)
            c.close(v.logProbability, b.1, tol: 1e-9, "trial \(trial) \(xs) best log-prob")
        }
        let demo = Viterbi.decode(demoSequence).path.map(\.symbol).joined()
        c.expect(demo.count == 6, "Viterbi demo path length")
    }

    static func bettingRules(_ c: Collector) {
        c.close(BettingEngine.expectedValue(sixProbability: 1.0 / 6.0), -1.0 / 6.0, "fair die EV")
        c.close(BettingEngine.expectedValue(sixProbability: 0.5), 1.5, "loaded die EV")
        c.close(BettingEngine.expectedValue(sixProbability: 0.2), 0, tol: 1e-15, "break-even P(6)=0.2")
        func act(_ pL: Double, _ p6: Double) -> BetRecommendation {
            BettingEngine.recommend(forRoll: 1, nextLoaded: pL, nextSixProbability: p6, bankroll: 1000)
        }
        c.expect(act(0.34999, 0.4).action == .hold, "34.999% should hold")
        c.expect(act(0.35, 0.4).action == .small, "35% should be small")
        c.expect(act(0.64999, 0.4).action == .small, "64.999% should be small")
        c.expect(act(0.65, 0.4).action == .big, "65% should be big")
        c.expect(act(0.9, 0.19).action == .hold, "negative EV must hold even if P(L) high")
        c.expect(act(0.9, 0.2).action == .hold, "EV exactly 0 must hold")
        c.close(act(0.5, 0.4).stake, 5, "small stake = 0.5% of 1000")
        c.close(act(0.8, 0.4).stake, 20, "big stake = 2% of 1000")
        c.expect(BetAction.hold.vibrationPulses == 0 && BetAction.small.vibrationPulses == 1 && BetAction.big.vibrationPulses == 2, "pulse counts")
    }

    /// Lowest reachable P(next L) is the fixed point of a never-ending run of non-sixes:
    /// 0.4q² − 0.51q + 0.05 = 0 → q* ≈ 0.10702 → P(6) ≈ 0.20234 > 0.2 → EV ≥ +0.0117.
    /// So under the classroom model the "negative EV" clause never fires; the 35% threshold does all the holding.
    static func evFloor(_ c: Collector) throws {
        let qStar = (0.51 - (0.51 * 0.51 - 4 * 0.4 * 0.05).squareRoot()) / 0.8
        var f = try ForwardFilter()
        var minNext = 1.0
        for _ in 0..<300 { minNext = min(minNext, try f.update(1).nextLoaded) }
        c.close(minNext, qStar, tol: 1e-9, "min P(next L)")
        c.expect(BettingEngine.expectedValue(sixProbability: 1.0 / 6.0 + qStar / 3.0) > 0.0117, "EV floor > 0")
    }

    static func kellyPolicy(_ c: Collector) {
        var cfg = BettingConfig.classroom
        cfg.policy = .kelly
        c.close(BettingEngine.kellyFraction(sixProbability: 0.5), 0.375, "Kelly f* at P(6)=0.5, b=4")
        let none = BettingEngine.recommend(forRoll: 1, nextLoaded: 0, nextSixProbability: 1.0 / 6.0, bankroll: 1000, config: cfg)
        c.expect(none.action == .hold && none.stake == 0, "Kelly holds at negative EV")
        let capped = BettingEngine.recommend(forRoll: 1, nextLoaded: 0.9, nextSixProbability: 0.46, bankroll: 1000, config: cfg)
        c.expect(capped.action == .big, "Kelly big at high P(6)")
        c.close(capped.stake, 20, "Kelly stake capped at 2%")
        let small = BettingEngine.recommend(forRoll: 1, nextLoaded: 0.2, nextSixProbability: 0.21, bankroll: 1000, config: cfg)
        c.expect(small.action == .small, "Kelly small at slight edge")
        c.close(small.stake, 1000 * 0.25 * 0.05 / 4, tol: 1e-9, "quarter Kelly stake")
    }

    /// Expected classroom decisions for 2,6,6,1,6,6, pinned from the hand-checkable
    /// values (P(next L) after each roll: 16.09%, 36.04%, 58.40%, 43.87%, 64.58%, 76.86%),
    /// which are cross-checked against brute force above and the Python reference.
    /// Note roll 5: posterior P(current L) = 70.1% but P(next L) = 64.58% < 65% → SMALL, not BIG.
    public static let expectedDemoActions: [BetAction] = [.hold, .small, .small, .small, .small, .big]
    public static let expectedDemoNextLoaded: [Double] = [0.160869565, 0.360361842, 0.584032690, 0.438650514, 0.645833483, 0.768636436]

    static func demoDecisions(_ c: Collector) throws {
        var e = try SessionEngine()
        c.expect(e.pending.action == .hold, "before any roll: hold (P(L)=0.2)")
        var bank = 1000.0
        for (i, x) in demoSequence.enumerated() {
            let bet = e.pending
            let o = try e.append(Observation(roll: x, source: .manual))
            let expectedProfit = bet.action == .hold ? 0 : (x == 6 ? 4 * bet.stake : -bet.stake)
            bank += expectedProfit
            c.close(o.settled.profit, expectedProfit, "roll \(i + 1) profit")
            c.close(o.bankroll, bank, "roll \(i + 1) bankroll")
            c.close(o.filter.nextLoaded, expectedDemoNextLoaded[i], tol: 1e-9, "roll \(i + 1) pinned P(next L)")
            c.expect(o.next.action == expectedDemoActions[i], "roll \(i + 1): expected \(expectedDemoActions[i]) got \(o.next.action) (P(next L)=\(o.filter.nextLoaded), EV=\(o.next.expectedValue))")
            c.close(o.next.expectedValue, 5 * o.filter.nextSixProbability - 1, "roll \(i + 1) EV = 5P(6)-1")
        }
    }

    static func signalGate(_ c: Collector) {
        var g = SignalGate()
        let big = BettingEngine.recommend(forRoll: 3, nextLoaded: 0.8, nextSixProbability: 0.4, bankroll: 1000)
        c.expect(g.shouldSignal(big), "first signal for roll 3")
        c.expect(!g.shouldSignal(big), "second signal for roll 3 suppressed")
        let older = BettingEngine.recommend(forRoll: 2, nextLoaded: 0.8, nextSixProbability: 0.4, bankroll: 1000)
        c.expect(!g.shouldSignal(older), "stale recommendation suppressed")
        let hold = BettingEngine.recommend(forRoll: 4, nextLoaded: 0.1, nextSixProbability: 0.17, bankroll: 1000)
        c.expect(!g.shouldSignal(hold), "hold never vibrates")
        c.expect(!g.shouldSignal(big), "roll 3 still suppressed after roll 4")
    }

    static func parser(_ c: Collector) {
        let p = RollParser()
        let cases: [(String, Double?, RollParseResult)] = [
            ("six", 0.9, .accepted(6)), ("Six!", 0.9, .accepted(6)), ("6", 0.8, .accepted(6)),
            ("it's a two", 0.8, .accepted(2)), ("five", nil, .accepted(5)), ("six six", 0.9, .accepted(6)),
            ("to", 0.9, .accepted(2)), ("for", 0.9, .accepted(4)),
            ("I went to the store", 0.9, .rejected(.homophoneNeedsIsolation("to"))),
            ("seven", 0.9, .rejected(.outOfRange(7))), ("12", 0.9, .rejected(.outOfRange(12))),
            ("two six", 0.9, .rejected(.ambiguous([2, 6]))), ("six", 0.2, .rejected(.lowConfidence(0.2))),
            ("hello there", 0.9, .rejected(.noNumber)), ("", 0.9, .rejected(.empty)),
            ("the dealer rolled a three okay", nil, .rejected(.lowConfidence(0))),
        ]
        for (text, conf, want) in cases {
            let got = p.parse(text, confidence: conf)
            c.expect(got == want, "parse(\"\(text)\", \(String(describing: conf))) = \(got), want \(want)")
        }
    }

    static func dedupe(_ c: Collector) {
        var d = AnnouncementDeduplicator(window: 2.5)
        let t0 = Date(timeIntervalSince1970: 0)
        let u = UUID()
        c.expect(d.admit(6, at: t0, utterance: u), "first 6 admitted")
        c.expect(!d.admit(6, at: t0.addingTimeInterval(5), utterance: u), "same utterance id rejected")
        c.expect(!d.admit(6, at: t0.addingTimeInterval(1), utterance: UUID()), "repeat 6 within window rejected")
        c.expect(d.admit(6, at: t0.addingTimeInterval(4), utterance: UUID()), "6 after window admitted")
        c.expect(d.admit(2, at: t0.addingTimeInterval(4.5), utterance: UUID()), "different value admitted")
    }

    static func persistence(_ c: Collector) throws {
        var e = try SessionEngine()
        for x in [2, 6, nil, 6, 1, 6, 6] as [Int?] { try e.append(Observation(roll: x, source: x == nil ? .missed : .manual)) }
        let data = try JSONEncoder().encode(e.snapshot)
        let restored = try SessionEngine(snapshot: JSONDecoder().decode(SessionSnapshot.self, from: data))
        c.expect(restored.outcomes == e.outcomes, "restored outcomes differ")
        c.close(restored.bankroll, e.bankroll, "restored bankroll")
        c.expect(restored.pending == e.pending, "restored pending recommendation")
        let undone = try e.removingLast()
        c.expect(undone.outcomes.count == e.outcomes.count - 1 && undone.outcomes == Array(e.outcomes.dropLast()), "undo")
    }

    static func invalidRoll(_ c: Collector) throws {
        var e = try SessionEngine()
        try e.append(Observation(roll: 6, source: .manual))
        let before = e.outcomes
        c.expect((try? e.append(Observation(roll: 7, source: .manual))) == nil, "roll 7 accepted")
        c.expect(e.outcomes == before && e.observations.count == 1, "state mutated by invalid roll")
    }

    static func simulator(_ c: Collector) throws {
        var a = DealerSimulator(seed: 42), b = DealerSimulator(seed: 42)
        c.expect((0..<100).allSatisfy { _ in a.roll() == b.roll() }, "same seed → same rolls")
        let r = try SimulationReport.run(rolls: 50_000, seed: 2026)
        c.close(r.fractionLoaded, 1.0 / 3.0, tol: 0.03, "fraction loaded ≈ stationary 1/3")
        c.close(r.meanPredictedSix, r.observedSixRate, tol: 0.01, "calibration: mean P(6) ≈ observed")
        c.expect(r.brierSix < r.brierSixFairBaseline, "HMM beats fair-die baseline on Brier")
        c.expect(r.filteredStateAccuracy > 0.7, "filtered accuracy \(r.filteredStateAccuracy)")
        c.expect(r.viterbiAccuracy >= r.filteredStateAccuracy - 0.02, "hindsight Viterbi ≳ live filter")
    }
}
