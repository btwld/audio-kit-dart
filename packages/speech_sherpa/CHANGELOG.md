# Changelog

## 0.2.0

- Installs are verified and staged: every catalog entry records its exact
  download size, and its SHA-256 where upstream publishes one (both Parakeet
  models, Silero VAD and WeSpeaker). A download of another size or digest
  fails with `sherpa_model_download_incomplete` or
  `sherpa_model_download_corrupt`, extraction happens in a `.staging`
  directory, and files move into place only once complete. A failed install
  leaves nothing behind.
- A recognition install writes `.speech_sherpa_install.json` with each
  file's size, and `resolveRecognition` returns a model only while every file
  still matches it. A truncated or deleted file, or a directory without the
  manifest, reads as not installed, so a broken model never reaches the
  native loader, which aborts or hangs the process instead of throwing.
  Directories installed by 0.1.x have no manifest and install again. A
  manifest that cannot be read or decoded, such as one with an invalid UTF-8
  byte, also reads as not installed instead of throwing, and a later install
  replaces it. Files are recorded and looked up by the same path relative to
  the model directory, so a model whose files sit in a subdirectory resolves.
- An archive install moves only the model's own directory into place, never
  the archive's other top-level entries, so an install cannot replace or
  delete unrelated files under the registry root.
- `installDiarization` stages both models together and writes
  `.speech_sherpa_diarization.json` once both are verified;
  `resolveDiarization` requires it and checks both files' sizes. A failed
  download of either model leaves the pair unresolved. Pairs installed by
  0.1.x have no manifest and install again.
- Staging directories left by a process that exited mid-install are removed
  by the next install. Each running install holds a lock beside its staging
  directory, so a sweep never removes one still in use by another process or
  by another registry in the same isolate.
- `installRecognition`, `installVad` and `installDiarization` take an
  `AudioCancellationToken`; cancelling aborts the download and throws
  `AudioCancelledException`.
- The archive is no longer held in the caller's isolate during extraction.
- Archives unpack with the system's `tar` (macOS, Linux, Windows 10+) read
  from a pipe: about twice as fast as the bundled decoder on Parakeet v3,
  without its 900 MB peak, reporting progress through the last 20% and
  stopped by cancellation. An archive `tar` refuses, such as one with an
  entry outside the destination, fails with `sherpa_model_extract_failed`.
  Platforms without `tar` keep the bundled decoder.
- A download that receives nothing for `stallTimeout` (30 s by default),
  before or during its body, fails with the retryable
  `sherpa_model_download_stalled` instead of waiting forever. The stall and
  cancellation end the body subscription and the wait themselves, so they
  take effect on a transport whose stream survives closing the client, and
  a close-delimited response that goes quiet reports as stalled, not
  incomplete. One deadline covers the whole transfer and no timer outlives
  it.
- The download is written through an awaited `addStream`, so a slow disk
  pauses the response instead of buffering it in memory.
- Without a system `tar`, the bundled decoder runs in a spawned worker
  isolate given only the two paths; cancelling kills it instead of letting it
  run to the end, and progress callbacks no longer need to be sendable.
- `SherpaModelRegistry` takes the VAD, segmentation and embedding models as
  test-only parameters that default to the catalog. Every addition is
  optional, so existing calls are unchanged.
- Fix the Parakeet TDT 0.6B v2 and Whisper turbo entries, whose download URLs
  returned 404: their IDs are now `sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8`
  and `sherpa-onnx-whisper-turbo`, matching the upstream archives.

## 0.1.1

- Update repository and issue links for the move to the concepta.dev publisher.

## 0.1.0

- Initial package: cross-platform batch speech-to-text, Silero voice-activity
  detection, pyannote + WeSpeaker diarization with provenance-tagged speaker
  embeddings, and an on-demand model registry, all over sherpa-onnx.
- Streaming speech-to-text over sherpa's `OnlineRecognizer`, emitting volatile
  `RecognitionPartial` hypotheses that are confirmed as `RecognitionFinal` when
  the endpointer closes a segment. Runs on its own long-lived worker isolate.
- Streaming Zipformer models in the catalog: `streamingZipformerEn` (English,
  296 MB, the streaming default) and `streamingZipformerEn20M` (English,
  122 MB, low-power). Recognition capability is now declared per model, so a
  batch model never advertises `streamingSpeechToText` and vice versa.
- `SherpaStreamingRecognitionOptions` exposes sherpa's three endpointing rules.
  They are silence timers over decoder state, not an end-of-utterance model.
- `transcribe` refuses audio shorter than
  `SpeechAudioGuards.minimumRecognitionDuration` with the typed
  `speech_audio_too_short` failure, the same guard every batch provider
  enforces. This replaces the empty-audio path that returned an empty
  transcript: "too short to try" and "the user said nothing" are different
  answers and only one of them is actionable.
