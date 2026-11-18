# Integrating Audio Kit

Prepare a capture source, subscribe to its events, and attach the routes that
need its first frame before starting it. Use one `AudioHub` for each physical
source. A microphone and a system-audio tap can have different clocks.

## Route capture to speech providers

Use a lossless route for a streaming recognizer that needs continuous audio.
Give meters and other optional consumers their own bounded routes so a slow UI
can drop stale frames independently. For batch recognition, collect a finite
utterance in a `BufferedAudioSource` and pass it to the selected provider.

Keep model selection, credentials, and provider options in the application’s
composition code. A Deepgram streaming session takes a renewable
`DeepgramTokenSource`. An MLX batch session uses a long-lived worker. Both
consume audio through the shared contracts.

## Record and play audio

For source-native recording, provide a recording path to a capture backend that
supports it. To record the graph’s PCM format, attach a `WavFileAudioSink`
from `package:audio_processing/audio_processing_io.dart`. Choose the route’s
overflow policy and the sink’s abort policy according to whether partial
recordings are useful to the application.

A `TextToSpeechProvider` returns an `AudioSource`. `GraphVoiceSpeechOutput`
can send its frames to playback and additional recording or analysis routes.
`GraphVoiceInput` shares a microphone between streaming speech recognition and
voice activity detection.

See the [capture example](../README.md#one-capture-multiple-consumers) for
startup ordering and the [architecture guide](architecture.md) for route
capacity, clock domains, and session shutdown.
