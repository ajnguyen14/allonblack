import Foundation
import SwiftUI
import HMMCore

/// Glue between inputs (speech / manual / simulated dealer), the HMM session, and the haptic output.
/// All probabilities shown come from `SessionEngine`, recomputed from the observation history.
@MainActor
final class AppModel: ObservableObject {
    // Inference state
    @Published private(set) var engine: SessionEngine
    // Input / status
    @Published private(set) var listenerState: ListenerState = .stopped
    @Published private(set) var inputKind: AudioInputKind = .none
    @Published private(set) var inputName: String = "—"
    @Published private(set) var heardText: String = ""
    @Published private(set) var lastEvent: String = "Ready. Tap a number or start listening."
    @Published var isPaused = false { didSet { if isPaused { stopDealer() } } }
    // Simulated dealer
    @Published private(set) var dealerRunning = false
    @Published var dealerInterval: Double = 2.0
    @Published var revealTruth = false
    @Published private(set) var dealerSeed: UInt64 = 131
    // Replay
    @Published private(set) var replayPosition: Int?    // number of rolls shown while replaying
    // Settings
    @Published var minConfidence: Double = 0.40
    @Published var dedupeWindow: Double = 2.5
    @Published var preferGlasses = true { didSet { listener.preferGlasses = preferGlasses; listener.selectPreferredInput() } }
    @Published var hapticsDuringReplay = true

    let haptics = HapticSignaler()
    private let listener = SpeechRollListener()
    private var gate = SignalGate()
    private var dedupe = AnnouncementDeduplicator()
    private var dealer: DealerSimulator
    private var dealerTask: Task<Void, Never>?
    private var replayTask: Task<Void, Never>?
    private let store = SessionStore()

    init() {
        let snapshot = store.load() ?? SessionSnapshot()
        engine = (try? SessionEngine(snapshot: snapshot)) ?? (try! SessionEngine())
        dealer = DealerSimulator(seed: 131)
        // A restored session must not re-vibrate for recommendations already signalled.
        gate = SignalGate()
        _ = gate.shouldSignal(engine.pending)

        listener.onUtterance = { [weak self] u in Task { @MainActor in self?.handleUtterance(u) } }
        listener.onState = { [weak self] s in Task { @MainActor in self?.listenerState = s } }
        listener.onPartial = { [weak self] t in Task { @MainActor in self?.heardText = t } }
        listener.onInputChange = { [weak self] kind, name in
            Task { @MainActor in
                guard let self else { return }
                if self.inputKind == .glassesHFP && kind != .glassesHFP && self.listener.isRunning {
                    self.lastEvent = "Glasses disconnected → using \(kind.rawValue.lowercased()). Session state kept."
                }
                self.inputKind = kind; self.inputName = name
            }
        }
        haptics.onError = { [weak self] msg in Task { @MainActor in self?.lastEvent = msg } }
    }

    // MARK: Derived view state

    var display: DisplayState { engine.display(after: replayPosition ?? engine.outcomes.count) }
    var visibleOutcomes: ArraySlice<StepOutcome> { engine.outcomes.prefix(replayPosition ?? engine.outcomes.count) }
    var viterbiPath: [DieState] { engine.viterbiPath }
    var isReplaying: Bool { replayPosition != nil }

    var truthAccuracy: (filtered: Double, n: Int)? {
        let scored = engine.outcomes.compactMap { o in o.observation.hiddenState.map { ($0, o.filter.posteriorLoaded) } }
        guard !scored.isEmpty else { return nil }
        let ok = scored.filter { ($0.1 >= 0.5) == ($0.0 == .loaded) }.count
        return (Double(ok) / Double(scored.count), scored.count)
    }

    // MARK: Observation intake

    /// Single entry point for every observation source.
    func record(_ roll: Int?, source: ObservationSource, transcript: String? = nil, confidence: Double? = nil,
                hidden: DieState? = nil) {
        guard !isPaused, !isReplaying else {
            lastEvent = "Ignored \(roll.map(String.init) ?? "missed roll"): \(isPaused ? "paused" : "replay in progress")"
            return
        }
        do {
            let o = try engine.append(Observation(roll: roll, source: source, transcript: transcript,
                                                  confidence: confidence, hiddenState: hidden))
            store.save(engine.snapshot)
            signal(o.next)
            let settled = o.settled
            var msg = "Roll \(o.filter.index): \(roll.map(String.init) ?? "missed") (\(source.rawValue))"
            if settled.recommendation.action != .hold {
                msg += settled.isVoid ? " · bet voided" : String(format: " · bet %@ %.2f", settled.profit >= 0 ? "won" : "lost", abs(settled.profit))
            }
            lastEvent = msg
        } catch {
            lastEvent = "Rejected: \(error)"
        }
    }

    private func signal(_ rec: BetRecommendation) {
        if gate.shouldSignal(rec) { haptics.play(rec.action) }
    }

    private func handleUtterance(_ u: Utterance) {
        heardText = u.text
        let parser = RollParser(minimumConfidence: minConfidence)
        switch parser.parse(u.text, confidence: u.confidence) {
        case .rejected(let why):
            lastEvent = "Heard \"\(u.text)\" — rejected: \(why)"
        case .accepted(let roll):
            dedupe.window = dedupeWindow
            guard dedupe.admit(roll, at: u.time, utterance: u.id) else {
                lastEvent = "Heard \"\(u.text)\" — \(RollRejection.duplicate(roll))"
                return
            }
            record(roll, source: .speech, transcript: u.text, confidence: u.confidence)
        }
    }

    // MARK: Listening

    func toggleListening() {
        if listener.isRunning { listener.stop(); return }
        Task {
            if await listener.requestPermissions() {
                listener.preferGlasses = preferGlasses
                listener.start()
            }
        }
    }

    var isListening: Bool { listener.isRunning }

    // MARK: Session controls

    func undoLast() {
        guard !isReplaying, let e = try? engine.removingLast() else { return }
        engine = e
        store.save(engine.snapshot)
        // Do not re-vibrate: mark the restored pending recommendation as already signalled.
        _ = gate.shouldSignal(engine.pending)
        lastEvent = "Removed last observation"
    }

    func reset() {
        stopDealer(); stopReplay()
        let fresh = SessionSnapshot(parameters: engine.parameters, betting: engine.betting,
                                    startingBankroll: engine.snapshot.startingBankroll)
        engine = (try? SessionEngine(snapshot: fresh)) ?? engine
        gate.reset(); _ = gate.shouldSignal(engine.pending)
        dedupe.reset()
        dealerSeed &+= 1
        dealer = DealerSimulator(parameters: engine.parameters, seed: dealerSeed)
        store.save(engine.snapshot)
        lastEvent = "Session reset"
    }

    func updateBetting(_ cfg: BettingConfig) {
        guard let e = try? engine.reconfigured(betting: cfg) else { return }
        engine = e
        _ = gate.shouldSignal(engine.pending)
        store.save(engine.snapshot)
    }

    /// Feeds the classroom sequence 2, 6, 6, 1, 6, 6 one roll at a time (with real haptics).
    func runClassroomDemo() {
        reset()
        stopDealer()
        dealerTask = Task { [weak self] in
            for r in [2, 6, 6, 1, 6, 6] {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                guard let self, !Task.isCancelled else { return }
                self.record(r, source: .manual)
            }
        }
    }

    // MARK: Simulated dealer

    func toggleDealer() { dealerRunning ? stopDealer() : startDealer() }

    private func startDealer() {
        guard !isReplaying else { return }
        isPaused = false
        dealerRunning = true
        dealerTask?.cancel()
        dealerTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.dealerRunning {
                let (state, roll) = self.dealer.roll()
                self.record(roll, source: .dealer, hidden: state)
                try? await Task.sleep(nanoseconds: UInt64(self.dealerInterval * 1_000_000_000))
            }
        }
    }

    private func stopDealer() {
        dealerRunning = false
        dealerTask?.cancel(); dealerTask = nil
    }

    // MARK: Replay (re-walks the recorded session step by step; live input is ignored meanwhile)

    func toggleReplay() { isReplaying ? stopReplay() : startReplay() }

    private func startReplay() {
        guard !engine.outcomes.isEmpty else { return }
        stopDealer()
        replayPosition = 0
        var replayGate = SignalGate()
        replayTask = Task { [weak self] in
            guard let self else { return }
            let total = self.engine.outcomes.count
            for n in 1...total {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                self.replayPosition = n
                let rec = self.engine.outcomes[n - 1].next
                if self.hapticsDuringReplay, replayGate.shouldSignal(rec) { self.haptics.play(rec.action) }
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.replayPosition = nil
        }
    }

    private func stopReplay() {
        replayTask?.cancel(); replayTask = nil
        replayPosition = nil
    }

    func appBecameActive() { haptics.resume(); if listener.isRunning { listener.selectPreferredInput() } }
}

/// Persists the observation history (the only ground data) to Application Support as JSON.
struct SessionStore {
    private var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("casino-session.json")
    }

    func load() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    func save(_ s: SessionSnapshot) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
