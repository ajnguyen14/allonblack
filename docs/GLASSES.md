# Meta glasses integration

Researched against Meta's Wearables developer docs ("Use device microphones and speakers", Device Access Toolkit integration overview) in November 2026. Re-check those pages before the demo, because the SDK changes often.

## What Meta documents for iOS microphone access

- The Wearables Device Access Toolkit (DAT) does **not** expose its own microphone API for the standard path. Glasses audio reaches an iOS app over **Bluetooth HFP** through normal `AVAudioSession` and `AVAudioEngine` APIs.
- Meta's recommended setup: `.playAndRecord` category, `.default` mode, the Bluetooth HFP option, then select the `.bluetoothHFP` port as the preferred input and tap the `AVAudioEngine` input node. The sample rate comes from the HFP negotiation (8 or 16 kHz mono).
- The glasses **beamform toward the wearer's voice**. Ambient sound, including another person's voice, is attenuated.
- A second path, **camera-stream audio** (16-bit PCM delivered alongside DAT video), exists only in development and beta channels and is *not* beamformed. If you combine HFP with a DAT camera stream, HFP must be configured and settled first.

## What this app does

| Capability | Status in this prototype |
|---|---|
| Phone-mic speech → roll → HMM → phone haptics | **Implemented.** This is the primary, fully working mode. |
| Glasses mic via Bluetooth HFP | **Implemented** with Meta's documented iOS audio configuration (`SpeechRollListener.configureSession` / `selectPreferredInput`). It needs no Meta SDK and no Meta developer registration. **Not yet tested on real glasses.** |
| Status shows "Glasses" vs "Phone mic" | Implemented. An HFP port whose name contains "Ray-Ban", "Meta" or "Oakley" is labelled as glasses; any other HFP device is labelled "BT". |
| Glasses disconnect → automatic phone-mic fallback | Implemented through route-change notifications. **Not hardware-tested.** |
| DAT SDK (camera, camera-stream audio, sessions) | **Not used.** The challenge needs only audio, and HFP covers it without the beta-only camera-audio path. |
| Vibration on the glasses | **Not attempted.** The spec requires phone vibration, and the glasses have no documented haptic actuator. |
| On-glasses speech recognition or app code | **Not possible** with the documented SDK. Recognition runs on the phone. |

## Setup

1. Pair the glasses with the iPhone in the **Meta AI** app. They also appear under iOS **Settings → Bluetooth** as a connected audio device.
2. Open DishonestCasino. Leave **Settings → Prefer glasses mic** on, then tap **Listen**.
3. The status strip should show a glasses icon with the device name. If it shows "Phone mic", open Control Center → the audio route picker, or reconnect the glasses.
4. Do a test by saying "six". The heard text and the accept/reject reason appear in the status strip.

## Recommended classroom protocol

Because the mics favor the wearer, the wearer should **quietly repeat each announced number** ("six"). That gives clean, close-talk audio and avoids recording the dealer twice. If the wearer would rather not speak, turn off *Prefer glasses mic* and set the phone on the table near the dealer.

## Things to check on the day (unverified here)

- That the HFP route actually comes up while the Meta AI app is connected. Some firmware versions may hold the audio link.
- Real `SFTranscriptionSegment.confidence` values on 8/16 kHz HFP audio. Tune *Minimum recognition confidence* if valid "six"s get rejected.
- The latency from announcement to buzz. The silence detector waits about 0.8 s after speech stops.
