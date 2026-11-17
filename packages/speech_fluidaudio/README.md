# speech_fluidaudio

FluidAudio adapters for the provider-neutral `speech_core` contracts.

The package exposes streaming and batch STT, VAD, end-of-utterance detection,
batch diarization, and TTS while keeping `fluidaudio_dart` types inside the
adapter boundary.

```dart
import 'package:speech_fluidaudio/speech_fluidaudio.dart';

final provider = FluidAudioSpeechProvider(runtime: FluidNativeRuntime());
```

Capture and playback remain in `audio_flutter`. This lets one capture feed
FluidAudio, recording, meters, or another cloud/local provider through the
same `audio_kit_graph`.

Streaming sessions listen to live capture, which restarts on its own, so a
frame that does not continue the one before it does not end them: the audio on
either side of the break is handed to the model back to back, and event times
count the audio the model was given. To end a session at the first break
instead:

```dart
final strict = FluidAudioSpeechProvider(
  streamingDiscontinuityPolicy: FluidDiscontinuityPolicy.fail,
);
```

Batch operations always refuse discontinuous audio.

FluidAudio inference is on-device and currently targets supported Apple
platforms.
