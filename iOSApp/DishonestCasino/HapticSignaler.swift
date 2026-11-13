import Foundation
import CoreHaptics
import HMMCore
#if os(iOS)
import AudioToolbox
#endif

/// Plays the betting signal on the PHONE's Taptic Engine.
///
/// - Small bet: one 150 ms continuous haptic.
/// - Big bet:   two 150 ms continuous haptics, 200 ms apart (onsets at 0 ms and 350 ms).
///
/// Platform facts this class accounts for:
/// - Core Haptics supports custom durations (`.hapticContinuous` + `duration`) on iPhone 8
///   and later. iPads and older iPhones report `supportsHaptics == false`.
/// - Haptics only play while the app is in the FOREGROUND; the engine is stopped by the
///   system when the app is backgrounded and restarted here when it returns.
/// - While the audio session is RECORDING (speech input), iOS suppresses haptics unless
///   `AVAudioSession.setAllowHapticsAndSystemSoundsDuringRecording(true)` is set — the
///   speech listener sets it (see SpeechRollListener.configureSession).
/// - Fallback when Core Haptics is unavailable: `kSystemSoundID_Vibrate` (fixed ~400 ms
///   buzz, duration NOT configurable). Pulses are then spaced 600 ms apart so two
///   remain distinguishable. This is a degradation, reported in the UI.
final class HapticSignaler {
    enum Mode: String { case coreHaptics = "Core Haptics (150 ms pulses)", systemVibrate = "Fallback: system vibrate (~400 ms, fixed)", none = "No vibration hardware" }

    static let pulseDuration: TimeInterval = 0.150
    static let pulseGap: TimeInterval = 0.200

    private(set) var mode: Mode
    private var engine: CHHapticEngine?
    private var engineNeedsStart = true
    var onError: ((String) -> Void)?

    init() {
        if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
            mode = .coreHaptics
        } else {
            #if os(iOS)
            mode = .systemVibrate
            #else
            mode = .none
            #endif
        }
        prepare()
    }

    func prepare() {
        guard mode == .coreHaptics, engine == nil else { return }
        do {
            let e = try CHHapticEngine()
            e.playsHapticsOnly = true            // no audio from this engine; don't touch the recording session
            e.isAutoShutdownEnabled = false      // keep latency low during the demo
            e.stoppedHandler = { [weak self] _ in self?.engineNeedsStart = true }
            e.resetHandler = { [weak self] in
                self?.engineNeedsStart = true
                try? self?.startIfNeeded()
            }
            engine = e
            try startIfNeeded()
        } catch {
            onError?("Haptic engine failed: \(error.localizedDescription)")
        }
    }

    private func startIfNeeded() throws {
        guard let engine, engineNeedsStart else { return }
        try engine.start()
        engineNeedsStart = false
    }

    /// Call when the app returns to the foreground.
    func resume() {
        engineNeedsStart = true
        try? startIfNeeded()
    }

    static func pattern(pulses: Int) throws -> CHHapticPattern {
        let events = (0..<pulses).map { i in
            CHHapticEvent(eventType: .hapticContinuous,
                          parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                                       CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)],
                          relativeTime: Double(i) * (pulseDuration + pulseGap),
                          duration: pulseDuration)
        }
        return try CHHapticPattern(events: events, parameters: [])
    }

    /// Plays the vibration for `action` (no-op for hold).
    func play(_ action: BetAction) {
        let pulses = action.vibrationPulses
        guard pulses > 0 else { return }
        switch mode {
        case .coreHaptics:
            do {
                try startIfNeeded()
                let player = try engine?.makePlayer(with: Self.pattern(pulses: pulses))
                try player?.start(atTime: CHHapticTimeImmediate)
            } catch {
                engineNeedsStart = true
                onError?("Haptic playback failed: \(error.localizedDescription)")
            }
        case .systemVibrate:
            #if os(iOS)
            for i in 0..<pulses {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.6) {
                    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                }
            }
            #endif
        case .none:
            break
        }
    }
}
