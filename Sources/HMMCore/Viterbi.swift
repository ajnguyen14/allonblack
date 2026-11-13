import Foundation

/// Most-likely hidden-state path, computed in log space.
///
/// RETROSPECTIVE ONLY. Viterbi conditions on the whole sequence (including rolls
/// after t), so it must never drive a live bet on roll t+1. The app shows it as a
/// labelled "hindsight" row under the roll history.
public enum Viterbi {
    public struct Result: Equatable, Sendable {
        public let path: [DieState]
        /// log P(x_1..x_T, best path)
        public let logProbability: Double
    }

    public static func decode(_ observations: [Int?], parameters: HMMParameters = .classroom) -> Result {
        let n = observations.count
        let S = HMMParameters.stateCount
        guard n > 0 else { return Result(path: [], logProbability: 0) }

        func safeLog(_ x: Double) -> Double { x > 0 ? log(x) : -Double.infinity }
        let logA = parameters.transition.map { $0.map(safeLog) }

        var delta = (0..<S).map { safeLog(parameters.initial[$0]) + safeLog(parameters.emissionProbability(state: $0, roll: observations[0])) }
        var back = Array(repeating: Array(repeating: 0, count: S), count: n)

        for t in 1..<n {
            var next = Array(repeating: -Double.infinity, count: S)
            for j in 0..<S {
                var best = -Double.infinity, arg = 0
                for i in 0..<S {
                    let v = delta[i] + logA[i][j]
                    if v > best { best = v; arg = i }
                }
                next[j] = best + safeLog(parameters.emissionProbability(state: j, roll: observations[t]))
                back[t][j] = arg
            }
            delta = next
        }

        var last = delta[1] > delta[0] ? 1 : 0
        let logP = delta[last]
        var path = Array(repeating: DieState.fair, count: n)
        path[n - 1] = DieState(rawValue: last)!
        if n > 1 {
            for t in stride(from: n - 1, to: 0, by: -1) {
                last = back[t][last]
                path[t - 1] = DieState(rawValue: last)!
            }
        }
        return Result(path: path, logProbability: logP)
    }
}
