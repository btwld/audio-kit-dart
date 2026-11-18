# Changelog

## 0.1.0

- Add `AecMicFilter` for echo cancellation on `audio_core` streams, with
  separate microphone and far-end inputs, delay calibration, and passthrough.
- Add `AecProcessor` for 10 ms mono PCM blocks at 8, 16, 32, and 48 kHz,
  and `probeAecRuntime` for checking native availability.
- Supply SHA-256-pinned WebRTC AEC3 runtimes for macOS arm64/x64, Linux x64,
  and Windows x64 through the Dart build hook. Support local library paths,
  pinned custom downloads, and native source builds.
