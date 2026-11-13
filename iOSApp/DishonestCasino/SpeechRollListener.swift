import Foundation
import AVFoundation
import Speech

/// Where the audio comes from.
enum AudioInputKind: String {
    case glassesHFP = "Glasses mic (Bluetooth HFP)"
    case otherBluetooth = "Other Bluetooth headset mic"
    case phone = "Phone microphone"
    case none = "No input"
}

enum ListenerState: Equatable {
    case stopped
    case listening
    case paused
    case unauthorized(String)
    case unavailable(String)
    case failed(String)

    var text: String {
        switch self {
        case .stopped: return "Mic off"
        case .listening: return "Listening"
        case .paused: return "Paused"
        case .unauthorized(let s), .unavailable(let s), .failed(let s): return s
        }
    }
}

/// Final transcript for one utterance.
struct Utterance {
    let id: UUID
    let text: String
    /// Mean SFTranscriptionSegment confidence (0–1), or nil if the recogniser gave none.
    let confidence: Double?
    let time: Date
}

/// Continuous speech capture → one `Utterance` per spoken announcement.
///
/// Audio path: AVAudioEngine input tap → SFSpeechAudioBufferRecognitionRequest.
/// - If the Meta glasses are connected as a Bluetooth HFP device and `preferGlasses` is
///   true, the HFP port is selected as preferred input (this is Meta's documented iOS path
///   for glasses microphone audio; no Meta SDK call is required for it).
/// - Otherwise, or if the glasses disconnect, the built-in phone microphone is used.
///
/// Utterance segmentation: partial results are tracked; once the transcript has been
/// stable for `silenceTimeout`, the request is ended so the recogniser delivers a FINAL
/// result (which carries per-segment confidence), and a fresh request is started.
final class SpeechRollListener {
    var onUtterance: ((Utterance) -> Void)?
    var onState: ((ListenerState) -> Void)?
    var onInputChange: ((AudioInputKind, String) -> Void)?
    var onPartial: ((String) -> Void)?

    var preferGlasses = true
    var silenceTimeout: TimeInterval = 0.8

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let requestBox = RequestBox()
    private var task: SFSpeechRecognitionTask?
    private var currentID = UUID()
    private var lastPartial = ""
    private var stabilityWork: DispatchWorkItem?
    private var finalTimeout: DispatchWorkItem?
    private var deliveredIDs = Set<UUID>()
    private var taskStarted = Date()
    private(set) var isRunning = false
    private var observers: [NSObjectProtocol] = []

    /// Thread-safe holder: the audio tap runs on a real-time thread.
    final class RequestBox {
        private let lock = NSLock()
        private var request: SFSpeechAudioBufferRecognitionRequest?
        func set(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); request = r; lock.unlock() }
        func append(_ b: AVAudioPCMBuffer) { lock.lock(); request?.append(b); lock.unlock() }
        func end() { lock.lock(); request?.endAudio(); request = nil; lock.unlock() }
    }

    // MARK: Permissions

    func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speech == .authorized else {
            emit(.unauthorized("Speech recognition not authorized (Settings → Privacy)"))
            return false
        }
        #if os(iOS)
        let mic = await AVAudioApplication.requestRecordPermission()   // iOS 17+
        guard mic else {
            emit(.unauthorized("Microphone not authorized (Settings → Privacy)"))
            return false
        }
        #endif
        return true
    }

    // MARK: Start / stop

    func start() {
        guard !isRunning else { return }
        guard let recognizer, recognizer.isAvailable else {
            emit(.unavailable("Speech recognizer unavailable (offline and no on-device model?)"))
            return
        }
        do {
            try configureSession()
            try startEngine()
            startTask()
            installObservers()
            isRunning = true
            emit(.listening)
        } catch {
            emit(.failed("Audio start failed: \(error.localizedDescription)"))
            stop()
        }
    }

    func stop() {
        stabilityWork?.cancel(); finalTimeout?.cancel()
        task?.cancel(); task = nil
        requestBox.end()
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        isRunning = false
        emit(.stopped)
    }

    // MARK: Audio session & route

    private func configureSession() throws {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        // Meta's documented configuration for glasses mic capture: .playAndRecord + Bluetooth HFP.
        // (`.allowBluetooth` is the HFP option; it is named `.allowBluetoothHFP` in newer SDKs.)
        try s.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .defaultToSpeaker])
        // Without this, iOS silences ALL haptics while the session is recording.
        try s.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try s.setActive(true)
        selectPreferredInput()
        #endif
    }

    /// Picks the glasses (HFP) input when present and preferred, else the built-in mic.
    func selectPreferredInput() {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        let inputs = s.availableInputs ?? []
        let hfp = inputs.first { $0.portType == .bluetoothHFP }
        let builtIn = inputs.first { $0.portType == .builtInMic }
        try? s.setPreferredInput(preferGlasses ? (hfp ?? builtIn) : builtIn)
        reportCurrentInput()
        #else
        onInputChange?(.phone, "Mac microphone")
        #endif
    }

    func reportCurrentInput() {
        #if os(iOS)
        guard let port = AVAudioSession.sharedInstance().currentRoute.inputs.first else {
            onInputChange?(.none, "—"); return
        }
        let name = port.portName
        if port.portType == .bluetoothHFP {
            let looksLikeGlasses = name.localizedCaseInsensitiveContains("ray-ban") || name.localizedCaseInsensitiveContains("meta")
                || name.localizedCaseInsensitiveContains("oakley")
            onInputChange?(looksLikeGlasses ? .glassesHFP : .otherBluetooth, name)
        } else {
            onInputChange?(.phone, name)
        }
        #endif
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        #if os(iOS)
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
            // Bluetooth disconnect = .oldDeviceUnavailable. iOS falls back to the built-in mic;
            // we re-apply our preference (glasses come back automatically on reconnect).
            if reason == .oldDeviceUnavailable || reason == .newDeviceAvailable { self.selectPreferredInput() } else { self.reportCurrentInput() }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
            if type == .began { self.emit(.paused) } else if type == .ended { self.restartAudio() }
        })
        #endif
        // Input format changes (e.g. HFP 8/16 kHz ↔ built-in 48 kHz) stop the engine: rebuild the tap.
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main) { [weak self] _ in
            self?.restartAudio()
        })
    }

    private func restartAudio() {
        guard isRunning else { return }
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            try startEngine()
            rotateTask()
            reportCurrentInput()
            emit(.listening)
        } catch {
            emit(.failed("Audio restart failed: \(error.localizedDescription)"))
        }
    }

    private func startEngine() throws {
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)   // sample rate comes from the active route (HFP is 8 or 16 kHz)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Listener", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio input available"])
        }
        let box = requestBox
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in box.append(buffer) }
        audioEngine.prepare()
        try audioEngine.start()
    }

    // MARK: Recognition tasks (one per utterance)

    private func startTask() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = ["one", "two", "three", "four", "five", "six"]
        request.addsPunctuation = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }  // no network, no 1-min limit
        requestBox.set(request)

        let id = UUID()
        currentID = id
        lastPartial = ""
        taskStarted = Date()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async { self?.handle(id: id, result: result, error: error) }
        }
    }

    private func rotateTask() {
        stabilityWork?.cancel(); finalTimeout?.cancel()
        task?.cancel()
        requestBox.end()
        startTask()
    }

    private func handle(id: UUID, result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            if result.isFinal {
                deliver(id: id, text: text, segments: result.bestTranscription.segments)
                if id == currentID { startTask() }
                return
            }
            guard id == currentID, !text.isEmpty, text != lastPartial else { return }
            lastPartial = text
            onPartial?(text)
            scheduleEndOfUtterance(id: id)
        } else if error != nil, id == currentID {
            // Typically "no speech detected" after a quiet period; just start listening again.
            if isRunning { startTask() }
        }
    }

    /// After `silenceTimeout` with no new partial text, end this request to obtain a final result.
    private func scheduleEndOfUtterance(id: UUID) {
        stabilityWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, id == self.currentID else { return }
            let partial = self.lastPartial
            self.requestBox.end()                    // recogniser will now send isFinal
            self.currentID = UUID()                  // anything further for `id` is final-only
            self.startTask()                         // keep capturing the next announcement immediately
            // If the final never arrives, fall back to the partial text WITHOUT confidence
            // (the parser then applies its stricter no-confidence rule).
            let timeout = DispatchWorkItem { [weak self] in self?.deliver(id: id, text: partial, segments: nil) }
            self.finalTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: timeout)
        }
        stabilityWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + silenceTimeout, execute: work)
    }

    private func deliver(id: UUID, text: String, segments: [SFTranscriptionSegment]?) {
        guard !deliveredIDs.contains(id), !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        deliveredIDs.insert(id)
        var confidence: Double?
        if let segs = segments, !segs.isEmpty {
            let mean = Double(segs.map(\.confidence).reduce(0, +)) / Double(segs.count)
            confidence = mean > 0 ? mean : nil   // 0 means "not provided"
        }
        onUtterance?(Utterance(id: id, text: text, confidence: confidence, time: Date()))
    }

    private func emit(_ s: ListenerState) { onState?(s) }
}
