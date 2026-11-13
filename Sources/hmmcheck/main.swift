// hmmcheck — command-line verification, demo table, and simulation.
//
//   swift run hmmcheck            # verification suite + demo + 10k-roll simulation
//   swift run hmmcheck verify     # verification only (exit code 1 on failure)
//   swift run hmmcheck demo [r1 r2 ...]   # step table (default 2 6 6 1 6 6; use 0 for a missed roll)
//   swift run hmmcheck simulate [rolls] [seed]
//   swift run hmmcheck csv [r1 r2 ...]      # machine-readable rows for cross-checking
import Foundation
import HMMCore
import HMMVerification

func pct(_ x: Double) -> String { String(format: "%6.2f%%", x * 100) }
func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

func runVerify() -> Bool {
    print("== Mathematical verification ==")
    var ok = true
    for r in VerificationSuite.runAll() {
        print("\(r.passed ? "PASS" : "FAIL")  \(r.name)")
        for f in r.failures.prefix(10) { print("        - \(f)") }
        ok = ok && r.passed
    }
    print(ok ? "All checks passed.\n" : "SOME CHECKS FAILED.\n")
    return ok
}

func runDemo(_ rolls: [Int?]) throws {
    print("== Demo: observed rolls \(rolls.map { $0.map(String.init) ?? "?" }.joined(separator: ", ")) ==")
    print("Columns: P(S_t=L|x1..t) is the CURRENT-roll posterior; P(S_t+1=L|x1..t) is the NEXT-roll prediction.")
    print("Bet / vibration is for roll t+1. Bankroll is after settling the bet that was placed on roll t.\n")
    var e = try SessionEngine()
    let p0 = e.display(after: 0)
    print(String(format: " t  roll  P(cur L)  P(next L)  P(next=6)    EV(6)   action for t+1   vibration                stake  bankroll"))
    print(String(format: " 0   —        —     %@   %@  %+7.4f   %@ %@ %6.2f  %8.2f",
                 pct(p0.nextLoaded), pct(p0.nextSixProbability), p0.recommendation.expectedValue,
                 pad(p0.recommendation.action.label, 16), pad(p0.recommendation.action.vibrationDescription, 23), p0.recommendation.stake, p0.bankroll))
    for x in rolls {
        let o = try e.append(Observation(roll: x, source: x == nil ? .missed : .manual))
        let n = o.next
        print(String(format: "%2d   %@   %@   %@   %@  %+7.4f   %@ %@ %6.2f  %8.2f",
                     o.filter.index, x.map { " \($0)" } ?? " ?", pct(o.filter.posteriorLoaded), pct(o.filter.nextLoaded),
                     pct(o.filter.nextSixProbability), n.expectedValue, pad(n.action.label, 16), pad(n.action.vibrationDescription, 23), n.stake, o.bankroll))
    }
    let vit = Viterbi.decode(rolls).path.map(\.symbol).joined(separator: " ")
    print("\nViterbi (retrospective, hindsight only — NOT used for betting): \(vit)")
    print(String(format: "log P(observations) = %.6f\n", e.filter.logLikelihood))
}

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "verify":
        exit(runVerify() ? 0 : 1)
    case "demo":
        let rolls: [Int?] = args.count > 1 ? args.dropFirst().map { Int($0).flatMap { $0 == 0 ? nil : $0 } } : VerificationSuite.demoSequence
        try runDemo(rolls)
    case "csv":   // machine-readable demo rows, used by scripts/crosscheck.sh
        let rolls: [Int?] = args.count > 1 ? args.dropFirst().map { Int($0).flatMap { $0 == 0 ? nil : $0 } } : VerificationSuite.demoSequence
        var e = try SessionEngine()
        for x in rolls {
            let o = try e.append(Observation(roll: x, source: .manual))
            print(String(format: "%d,%.9f,%.9f,%.9f,%+.9f,%@", o.filter.index, o.filter.posteriorLoaded, o.filter.nextLoaded,
                         o.filter.nextSixProbability, o.next.expectedValue, o.next.action.rawValue.uppercased()))
        }
    case "simulate":
        let n = args.count > 1 ? Int(args[1]) ?? 10_000 : 10_000
        let seed = args.count > 2 ? UInt64(args[2]) ?? 131 : 131
        print(try SimulationReport.run(rolls: n, seed: seed))
    default:
        let ok = runVerify()
        try runDemo(VerificationSuite.demoSequence)
        print("== Simulated dealer evaluation ==")
        print(try SimulationReport.run(rolls: 10_000, seed: 131))
        exit(ok ? 0 : 1)
    }
} catch {
    print("error: \(error)")
    exit(2)
}
