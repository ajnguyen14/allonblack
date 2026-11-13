import SwiftUI
import HMMCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var cfg = BettingConfig.classroom

    var body: some View {
        NavigationStack {
            Form {
                Section("Betting policy") {
                    Picker("Policy", selection: $cfg.policy) {
                        Text("Classroom thresholds").tag(BettingPolicy.thresholds)
                        Text("¼-Kelly (expected log utility)").tag(BettingPolicy.kelly)
                    }
                    if cfg.policy == .thresholds {
                        slider("Small-bet threshold P(next L)", $cfg.smallLoadedThreshold, 0...1)
                        slider("Big-bet threshold P(next L)", $cfg.bigLoadedThreshold, 0...1)
                    } else {
                        slider("Kelly multiplier", $cfg.kellyMultiplier, 0.05...1)
                    }
                    slider("Small stake (fraction of bankroll)", $cfg.smallStakeFraction, 0...0.05, fmt: "%.3f")
                    slider("Big stake / cap (fraction of bankroll)", $cfg.bigStakeFraction, 0...0.10, fmt: "%.3f")
                    Text("Payout: \(Int(cfg.netPayout)):1 net · EV = \(Int(cfg.netPayout + 1))·P(6) − 1").font(.caption)
                }
                Section("Speech input") {
                    Toggle("Prefer glasses mic (Bluetooth HFP)", isOn: $model.preferGlasses)
                    slider("Minimum recognition confidence", $model.minConfidence, 0...1)
                    slider("Duplicate window (s)", $model.dedupeWindow, 0...6, fmt: "%.1f")
                    Text("A repeat of the same number within the window is treated as the same announcement. Manual buttons bypass it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Replay") {
                    Toggle("Vibrate during replay", isOn: $model.hapticsDuringReplay)
                }
                Section("Model (fixed for the assignment)") {
                    Text("π(L)=0.20 · F→L 0.05 · L→F 0.10\nFair: 1/6 each · Loaded: P(6)=0.5, P(1–5)=0.1")
                        .font(.caption.monospaced())
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if cfg.bigLoadedThreshold < cfg.smallLoadedThreshold { cfg.bigLoadedThreshold = cfg.smallLoadedThreshold }
                        model.updateBetting(cfg)
                        dismiss()
                    }
                }
            }
            .onAppear { cfg = model.engine.betting }
        }
    }

    func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, fmt: String = "%.2f") -> some View {
        VStack(alignment: .leading) {
            HStack { Text(title).font(.caption); Spacer(); Text(String(format: fmt, value.wrappedValue)).font(.caption.monospacedDigit()) }
            Slider(value: value, in: range)
        }
    }
}
