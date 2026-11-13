import XCTest
@testable import HMMCore
import HMMVerification

/// Runs in Xcode (⌘U) or with `swift test` on a Mac that has full Xcode installed.
/// With Command Line Tools only, use `swift run hmmcheck verify` — same checks.
final class HMMCoreTests: XCTestCase {
    func testVerificationSuite() {
        for r in VerificationSuite.runAll() {
            XCTAssertTrue(r.passed, "\(r.name):\n" + r.failures.joined(separator: "\n"))
        }
    }

    func testDemoPosteriorVersusPrediction() throws {
        var f = try ForwardFilter()
        var steps: [FilterStep] = []
        for x in [2, 6, 6, 1, 6, 6] { steps.append(try f.update(x)) }
        // Roll 5: current die likely loaded (70.1%) but next die only 64.6% → small bet, not big.
        XCTAssertEqual(steps[4].posteriorLoaded, 0.700980568, accuracy: 1e-9)
        XCTAssertEqual(steps[4].nextLoaded, 0.645833483, accuracy: 1e-9)
        XCTAssertEqual(steps[5].nextSixProbability, 0.422878812, accuracy: 1e-9)
    }
}
