# allonblack — Beat the Dishonest Casino (BioE 131/231, Design Challenge 5)

A real-time Hidden Markov Model prototype. A dealer announces each die roll out loud. The app captures the announcement through the **Meta glasses' microphone** (over Bluetooth HFP) or the **phone microphone**. It runs **forward filtering** on the iPhone, predicts the **next** roll, and signals a simulated bet on six using **phone vibrations only**.

> This is a classroom simulation of probabilistic inference. It is not a gambling tool.

```
Meta glasses mic ─(Bluetooth HFP)─┐
                                  ├─► AVAudioEngine ─► SFSpeech (on-device) ─► RollParser ─► Dedup
Phone mic (fallback) ─────────────┘                                                         │
Manual buttons 1–6 / Missed ────────────────────────────────────────────────────────────────┤
Simulated dealer (HMM sampler, hidden truth kept aside) ────────────────────────────────────┤
                                                                                            ▼
               SessionEngine: observations ─► ForwardFilter ─► P(Sₜ=L|x) [posterior]
                                                     │
                                                     └─► P(Sₜ₊₁=L|x), P(xₜ₊₁=k|x) [prediction]
                                                                │
                                         BettingEngine: EV = 5·P(6) − 1, thresholds ─► SignalGate ─► Core Haptics (phone)
```
The full block diagram is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## What's in the repo

| Path | What it is |
|---|---|
| `Sources/HMMCore/` | Platform-independent engine: [ForwardFilter](Sources/HMMCore/ForwardFilter.swift), [Viterbi](Sources/HMMCore/Viterbi.swift) (retrospective only), [BettingEngine](Sources/HMMCore/BettingEngine.swift) (+ `SignalGate`), [SessionEngine](Sources/HMMCore/SessionEngine.swift) (ledger + persistence), [DealerSimulator](Sources/HMMCore/DealerSimulator.swift), [RollParser](Sources/HMMCore/RollParser.swift) (speech → roll, dedup) |
| `Sources/HMMVerification/` | 19 mathematical checks, including comparisons against brute-force enumeration of all 2^T hidden paths |
| `Sources/hmmcheck/` | CLI: runs the checks, the demo table and the dealer simulation |
| `Tests/HMMCoreTests/` | XCTest wrapper around the same checks (for Xcode ⌘U) |
| `reference/hmm_reference.py` | Independent Python reference using **exact fractions**; `scripts/crosscheck.sh` diffs it against Swift |
| `iOSApp/` | SwiftUI iPhone app (`DishonestCasino.xcodeproj`, generated from `project.yml`) |
| `docs/` | Architecture, Meta glasses integration, pitch, professor Q&A, captured output |

## 1. Verify the math on a Mac (no Xcode needed)

You need the Swift toolchain (Xcode or the Command Line Tools).

```bash
swift run hmmcheck
```

This runs all verification checks, prints the demo table for 2, 6, 6, 1, 6, 6, and runs a 10,000-roll simulated dealer. It exits with code 1 if any check fails. Other modes:

```bash
swift run hmmcheck demo 6 6 0 1 6
```
(`0` = missed roll)

```bash
swift run hmmcheck simulate 50000 7
```

```bash
./scripts/crosscheck.sh
```

`crosscheck.sh` compares Swift with the exact-arithmetic Python reference on 5 sequences, including missed rolls. With full Xcode installed you can also run `swift test`.

### Demo result (actual program output)

| t | roll | P(current die L) | **P(next die L)** | P(next = 6) | EV(6) | Signal for roll t+1 |
|---|---|---|---|---|---|---|
| 0 | — | — | 20.00% | 23.33% | +0.167 | HOLD — no vibration |
| 1 | 2 | 13.04% | 16.09% | 22.03% | +0.101 | HOLD — no vibration |
| 2 | 6 | 36.51% | 36.04% | 28.68% | +0.434 | SMALL — 1 × 150 ms |
| 3 | 6 | 62.83% | 58.40% | 36.13% | +0.807 | SMALL — 1 × 150 ms |
| 4 | 1 | 45.72% | 43.87% | 31.29% | +0.564 | SMALL — 1 × 150 ms |
| 5 | 6 | 70.10% | **64.58%** | 38.19% | +0.910 | SMALL — 1 × 150 ms |
| 6 | 6 | 84.55% | 76.86% | 42.29% | +1.114 | BIG — 2 × 150 ms, 200 ms gap |

After roll 5 the *current* die is probably loaded (70.1%). The *next* die is only 64.6% likely to be loaded, because the die can switch back (L→F = 0.10). The signal is therefore SMALL, not BIG. This is the posterior-vs-prediction distinction in one row. The full output, including the bankroll ledger and simulation, is in [docs/hmmcheck-output.txt](docs/hmmcheck-output.txt).

## 2. Build and run on a physical iPhone

Requirements:
- A Mac with **Xcode 15 or later** (full Xcode from the App Store, not just the Command Line Tools)
- An iPhone 8 or later on **iOS 17 or later** (needed for Core Haptics custom pulse lengths)
- A free Apple ID is enough for personal-device signing

1. If Xcode was just installed, point the command line at it:
   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```
2. Open the project:
   ```bash
   open iOSApp/DishonestCasino.xcodeproj
   ```
   (To regenerate it after editing `project.yml`: `brew install xcodegen`, then `cd iOSApp && xcodegen generate`.)
3. In Xcode, select the **DishonestCasino** target → **Signing & Capabilities**. Choose your **Team** (Add Account… with your Apple ID). If the bundle ID is taken, change it to something unique, such as `edu.berkeley.<you>.dishonestcasino`.
4. Connect the iPhone by USB and trust the computer. On the iPhone, turn on **Settings → Privacy & Security → Developer Mode** (the phone restarts).
5. Pick the iPhone as the run destination and press **⌘R**. The first time, approve the developer certificate on the phone under **Settings → General → VPN & Device Management**.
6. In the app, tap **Run demo 2, 6, 6, 1, 6, 6**. The phone should give one short buzz after rolls 2–5 and a double buzz after roll 6. Then tap **Listen** and say "six". Allow microphone and speech access when asked.
7. **⌘U** runs the XCTest suite in the simulator.

Keep the app in the **foreground** with the ringer/haptics on (**Settings → Sounds & Haptics → System Haptics**). iOS does not deliver Core Haptics or live speech capture to a backgrounded app.

## 3. Using the app

- **Manual buttons 1–6 / Missed roll / Undo last.** Test everything without any audio. *Missed roll* records that a roll happened without its value: the filter runs a pure prediction step and any open bet is voided.
- **Listen.** Captures speech from the glasses (when they're connected over Bluetooth) or the phone mic. The status strip shows which input is active and any rejected utterances, with the reason.
- **Pause** ignores all input. **Replay** re-walks the recorded session one step every 1.5 s, with the haptics. **Reset** clears the session.
- **Simulated dealer** generates rolls from the same HMM and stores the hidden die for scoring. Toggle *Reveal hidden die* to show the truth row under the history.
- **Settings** has the thresholds, the stake fractions, an optional ¼-Kelly policy, the speech confidence threshold and the duplicate window.
- The session (the observations only) is saved as JSON after every roll and restored on launch. All probabilities are recomputed from those observations, so restoring can never produce numbers that disagree with the history.

## 4. Meta glasses

See [docs/GLASSES.md](docs/GLASSES.md). In short, the supported path is to pair the glasses to the iPhone as a Bluetooth headset. The app then selects the **HFP** microphone with standard iOS audio APIs, which is how Meta documents glasses mic access on iOS. No Meta SDK is needed for that.

Important caveat: Meta's docs say the glasses mics are **beamformed toward the wearer's voice**, so a dealer across the table is attenuated. The robust protocol is for the wearer to **repeat the number quietly** ("six"). The phone mic is the fallback for picking up the dealer directly.

## 5. What has and hasn't been verified

| Component | Status |
|---|---|
| Forward filter, prediction, EV, decisions, Viterbi, missing data, stability, persistence, parser, dedup, simulator | **Verified**: `swift run hmmcheck` (19/19 pass), and Swift matches the exact-fraction Python reference |
| App source type-check | **Verified** against the macOS SDK with `swiftc -typecheck` |
| iOS-only code paths (`AVAudioSession`, HFP routing, `UIApplication`, `kSystemSoundID_Vibrate`) and the iOS build | **Not compiled here**: this Mac only has the Command Line Tools, which have no iOS SDK. Build in Xcode and fix any SDK-specific issues there. |
| Physical haptics, real speech-recognition accuracy and confidence values, glasses HFP routing and Bluetooth-disconnect handling | **Untested on hardware**. Needs an iPhone and the glasses. |
