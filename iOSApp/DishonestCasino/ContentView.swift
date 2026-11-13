import SwiftUI
import HMMCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    StatusStrip()
                    DecisionCard(state: model.display)
                    ProbabilityCards(state: model.display)
                    HistoryCard()
                    ManualEntry()
                    SessionControls()
                    DealerCard()
                    Text("Classroom simulation of HMM inference (BioE 131/231). Not for real gambling.")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(16)
            }
            .navigationTitle("Dishonest Casino")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(model) }
        }
    }
}

// MARK: - Status

struct StatusStrip: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(model.listenerState.text, systemImage: model.isListening ? "waveform" : "mic.slash")
                    .foregroundStyle(model.isListening ? .green : .secondary)
                Spacer()
                Label(inputLabel, systemImage: model.inputKind == .glassesHFP ? "eyeglasses" : "iphone")
                    .foregroundStyle(model.inputKind == .glassesHFP ? .blue : .secondary)
            }
            .font(.caption.weight(.semibold))
            HStack {
                Image(systemName: "iphone.radiowaves.left.and.right")
                Text(model.haptics.mode.rawValue)
                Spacer()
                if model.isPaused { Text("PAUSED").bold().foregroundStyle(.orange) }
                if model.isReplaying { Text("REPLAY").bold().foregroundStyle(.purple) }
            }
            .font(.caption2).foregroundStyle(.secondary)
            if !model.heardText.isEmpty {
                Text("Heard: “\(model.heardText)”").font(.caption).lineLimit(1)
            }
            Text(model.lastEvent).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    var inputLabel: String {
        switch model.inputKind {
        case .glassesHFP: return "Glasses: \(model.inputName)"
        case .otherBluetooth: return "BT: \(model.inputName)"
        case .phone: return "Phone mic"
        case .none: return "No input"
        }
    }
}

// MARK: - Decision

struct DecisionCard: View {
    let state: DisplayState
    var rec: BetRecommendation { state.recommendation }

    var color: Color {
        switch rec.action { case .hold: return .gray; case .small: return .orange; case .big: return .red }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(spacing: 2) {
                Text("LAST ROLL").font(.caption2).foregroundStyle(.secondary)
                Text(state.latestWasMissed ? "?" : state.latestRoll.map(String.init) ?? "—")
                    .font(.system(size: 54, weight: .bold, design: .rounded))
                    .accessibilityLabel("Last roll \(state.latestRoll.map(String.init) ?? "none")")
                Text("#\(state.rollCount)").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 84)
            VStack(alignment: .leading, spacing: 4) {
                Text("RECOMMENDATION FOR ROLL #\(rec.forRoll)").font(.caption2).foregroundStyle(.secondary)
                Text(rec.action.label).font(.title2.bold()).foregroundStyle(color)
                Text(rec.action == .hold ? "No vibration" : String(format: "Stake %.2f · vibration %@", rec.stake, rec.action.vibrationDescription))
                    .font(.subheadline)
                Text(rec.reason).font(.caption).foregroundStyle(.secondary)
                Text(String(format: "Bankroll %.2f", state.bankroll)).font(.subheadline.monospacedDigit().bold())
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.5)))
    }
}

// MARK: - Probabilities (posterior vs prediction kept visually separate)

struct ProbabilityCards: View {
    let state: DisplayState
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                MetricTile(title: "NOW · filtered posterior",
                           formula: "P(Sₜ = L | x₁…ₜ)",
                           value: state.currentLoaded.map(pct) ?? "—",
                           note: "Was the die that just rolled loaded?",
                           tint: .teal)
                MetricTile(title: "NEXT · prediction",
                           formula: "P(Sₜ₊₁ = L | x₁…ₜ)",
                           value: pct(state.nextLoaded),
                           note: "Used for betting",
                           tint: .indigo)
            }
            HStack(spacing: 10) {
                MetricTile(title: "NEXT · P(roll = 6)", formula: "Σⱼ P(Sₜ₊₁=j|x) eⱼ(6)",
                           value: pct(state.nextSixProbability), note: "break-even 20%", tint: .indigo)
                MetricTile(title: "EV of $1 on six (4:1)", formula: "5·P(6) − 1",
                           value: String(format: "%+.3f", state.recommendation.expectedValue),
                           note: state.recommendation.expectedValue > 0 ? "positive" : "negative",
                           tint: state.recommendation.expectedValue > 0 ? .green : .red)
            }
            PredictiveBars(dist: state.nextDistribution)
        }
    }
}

func pct(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }

struct MetricTile: View {
    let title: String, formula: String, value: String, note: String, tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(tint)
            Text(value).font(.title2.monospacedDigit().bold())
            Text(formula).font(.caption2.monospaced()).foregroundStyle(.secondary)
            Text(note).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct PredictiveBars: View {
    let dist: [Double]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NEXT · predictive distribution P(xₜ₊₁ = k | x₁…ₜ)").font(.caption2.weight(.semibold)).foregroundStyle(.indigo)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(0..<6, id: \.self) { k in
                    VStack(spacing: 2) {
                        Text(String(format: "%.0f", dist[k] * 100)).font(.caption2.monospacedDigit())
                        RoundedRectangle(cornerRadius: 3)
                            .fill(k == 5 ? Color.indigo : Color.indigo.opacity(0.35))
                            .frame(height: max(2, dist[k] * 160))
                        Text("\(k + 1)").font(.caption.bold())
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 110, alignment: .bottom)
        }
        .padding(10)
        .background(Color.indigo.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - History

struct HistoryCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let outcomes = Array(model.visibleOutcomes)
        let vit = model.viterbiPath
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("OBSERVED ROLLS (\(outcomes.count))").font(.caption2.weight(.semibold))
                Spacer()
                Text("P(L) under each = filtered posterior").font(.caption2).foregroundStyle(.secondary)
            }
            if outcomes.isEmpty {
                Text("No observations yet").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(outcomes.enumerated()), id: \.element.observation.id) { i, o in
                                VStack(spacing: 2) {
                                    Text(o.observation.roll.map(String.init) ?? "?")
                                        .font(.headline.monospacedDigit())
                                        .frame(width: 30, height: 30)
                                        .background(o.observation.roll == 6 ? Color.red.opacity(0.2) : Color.gray.opacity(0.15),
                                                    in: RoundedRectangle(cornerRadius: 6))
                                    Text(String(format: "%.0f", o.filter.posteriorLoaded * 100)).font(.system(size: 9).monospacedDigit())
                                    if i < vit.count {
                                        Text(vit[i].symbol).font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(vit[i] == .loaded ? .red : .secondary)
                                    }
                                    if model.revealTruth, let h = o.observation.hiddenState {
                                        Text(h.symbol).font(.system(size: 9, weight: .heavy))
                                            .foregroundStyle(h == .loaded ? .red : .green)
                                    }
                                }
                                .id(i)
                            }
                        }
                    }
                    .onChange(of: outcomes.count) { _, n in withAnimation { proxy.scrollTo(n - 1, anchor: .trailing) } }
                }
                Text("Row 3: Viterbi path (hindsight only — never used for live bets)" + (model.revealTruth ? " · Row 4: true hidden die" : ""))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Manual entry & controls

struct ManualEntry: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(1...6, id: \.self) { n in
                    Button { model.record(n, source: .manual) } label: {
                        Text("\(n)").font(.title2.bold()).frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(n == 6 ? .red : .blue)
                    .accessibilityLabel("Enter roll \(n)")
                }
            }
            HStack(spacing: 6) {
                Button { model.record(nil, source: .missed) } label: {
                    Label("Missed roll", systemImage: "questionmark.circle").frame(maxWidth: .infinity)
                }
                Button { model.undoLast() } label: {
                    Label("Undo last", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
        }
        .disabled(model.isReplaying)
    }
}

struct SessionControls: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 6) {
            Button { model.toggleListening() } label: {
                Label(model.isListening ? "Stop listening" : "Listen (glasses / phone mic)",
                      systemImage: model.isListening ? "mic.fill" : "mic")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(model.isListening ? .green : .accentColor)
            HStack(spacing: 6) {
                Button { model.isPaused.toggle() } label: {
                    Label(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play" : "pause").frame(maxWidth: .infinity)
                }
                Button { model.toggleReplay() } label: {
                    Label(model.isReplaying ? "Stop" : "Replay", systemImage: "backward.end.alt").frame(maxWidth: .infinity)
                }
                Button(role: .destructive) { model.reset() } label: {
                    Label("Reset", systemImage: "trash").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            Button { model.runClassroomDemo() } label: {
                Label("Run demo 2, 6, 6, 1, 6, 6", systemImage: "play.rectangle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
}

struct DealerCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SIMULATED DEALER").font(.caption2.weight(.semibold))
                Spacer()
                Button(model.dealerRunning ? "Stop dealer" : "Start dealer") { model.toggleDealer() }
                    .buttonStyle(.borderedProminent).tint(model.dealerRunning ? .red : .purple)
            }
            Text("Rolls are drawn from the same HMM (hidden state sampled, then the face). The hidden die is stored only for scoring.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Text(String(format: "Every %.1f s", model.dealerInterval)).font(.caption)
                Slider(value: $model.dealerInterval, in: 0.3...5, step: 0.1)
            }
            Toggle("Reveal hidden die in history", isOn: $model.revealTruth).font(.caption)
            if let acc = model.truthAccuracy {
                Text(String(format: "Live filter accuracy vs truth: %.1f%% over %d dealer rolls", acc.filtered * 100, acc.n))
                    .font(.caption.monospacedDigit())
            }
        }
        .padding(12)
        .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}
