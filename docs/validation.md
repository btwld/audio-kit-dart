# Validation

## Default workspace verification

From the Audio Kit workspace:

```sh
./tool/verify.sh
```

The script resolves packages, runs `flutter analyze`, and runs every package
test directory. These tests cover contract validation, lifecycle races,
fan-out, overflow policies and boundedness, discontinuity ranges, failure
isolation, drain/abort, processing continuity, synchronization/mixing, WAV
finalization, provider fake transports/workers, and voice generation safety.

Also run formatting and whitespace checks before committing:

```sh
dart format --output=none --set-exit-if-changed packages
git diff --check
```

The intended toolchain is Flutter 3.44 with Dart 3.12.

## Focused checks

```sh
flutter test packages/audio_core/test
flutter test packages/audio_kit_graph/test
flutter test packages/audio_processing/test
flutter test packages/audio_flutter/test
flutter test packages/speech_core/test
flutter test packages/speech_fluidaudio/test
flutter test packages/speech_mlx/test
flutter test packages/speech_deepgram/test
flutter test packages/speech_openai_tts/test
flutter test packages/voice_core/test
flutter test packages/voice_flutter/test
```

Provider adapter tests use injected fake runtimes, workers, websocket
transports, HTTP transports, and token sources unless an integration command
explicitly says otherwise. Passing them proves the adapter contract and
lifecycle, not the availability of a remote service or local model checkpoint.

## Desktop host

The example application exercises the federated plugin in a Flutter host.
On macOS, build it from the workspace root with:

```sh
cd packages/audio_flutter/example
flutter build macos --debug
```

The desktop CI jobs also build this example on Linux and Windows. Live audio
capture requires a device or a configured audio server on the target platform.

## Opt-in real integration

The adapter packages document their model and hardware requirements. In
`packages/speech_mlx`, enable `SPEECH_MLX_WEIGHTS_TESTS=1` on Apple Silicon
to run the real-checkpoint test with its required assets.

Deepgram and OpenAI adapter tests do not call production endpoints. A real
cloud smoke test must inject renewable credentials, use a non-sensitive audio
fixture, verify cancellation and finalization, and avoid logging token values.

## Long-running and hardware acceptance

Before publishing or broad deployment, run hardware tests that are deliberately
outside the deterministic default suite:

- simultaneous microphone and macOS system capture;
- selected-device changes and permission denial/recovery;
- process targeting and one-shot silent-tap rebuild;
- one capture feeding STT, VAD/EOU, WAV, and metering concurrently;
- long-running capture with route and native mailbox high-water monitoring;
- fail-capture recording overflow and valid WAV finalization on every stop or
  failure path;
- Deepgram/OpenAI disconnect, token renewal, and cancellation;
- MLX UI-isolate responsiveness, worker replacement after cancellation, and
  real incremental TTS timing;
- VAD barge-in while output is active and a cancellation-insensitive backend is
  still unwinding.

Record the exact command, hardware/OS, model IDs, credentials environment, test
duration, and result when these opt-in checks are run. Do not treat a gated skip
as a passing real-model result.
