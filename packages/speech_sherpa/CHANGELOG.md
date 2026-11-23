# Changelog

## 0.2.0

- Installs are verified and staged: every catalog entry records its exact
  download size, and its SHA-256 where upstream publishes one (both Parakeet
  models, Silero VAD and WeSpeaker). A download of another size or digest
  fails with `sherpa_model_download_incomplete` or
  `sherpa_model_download_corrupt`, extraction happens in a `.staging`
  directory, and files move into place only once complete. A failed install
  leaves nothing behind.
- `installRecognition`, `installVad` and `installDiarization` take an
  `AudioCancellationToken`; cancelling aborts the download and throws
  `AudioCancelledException`.
- The archive is no longer held in the caller's isolate during extraction.
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
