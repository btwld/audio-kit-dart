# speech_sherpa

Cross-platform implementation of the provider-neutral speech contracts, backed
by [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx). This is the inference
floor for every platform without an on-device Apple runtime: the same models
run on macOS, Windows, Linux, iOS, and Android through ONNX Runtime.

```dart
final registry = SherpaModelRegistry(root: modelsDirectory);
await registry.installRecognition(SherpaRecognitionModel.defaultModel);

final provider = SherpaSpeechProvider(registry: registry);
final result = await provider.transcribe(
  BatchRecognitionRequest(audio: recordedFile),
);
print(result.text);
await provider.close();
```

## Capabilities

| Capability | Status |
| --- | --- |
| Batch speech-to-text | Implemented |
| Streaming speech-to-text | Implemented (streaming Zipformer) — see below |
| Voice-activity detection | Implemented (Silero) |
| Diarization | Implemented (pyannote + WeSpeaker) |
| Speaker embeddings | Implemented, provenance-tagged |
| Text-to-speech | Not implemented |

Recognition capability is declared **per model**, not provider-wide. A streaming
Zipformer cannot be batch-decoded and Parakeet cannot be streamed, so each model
descriptor advertises exactly one of the two and `transcribe` and
`prepareStreamingRecognition` resolve from disjoint halves of the catalog.

## Streaming recognition

```dart
await registry.installRecognition(SherpaRecognitionModel.streamingZipformerEn);

final session = await provider.prepareStreamingRecognition(
  StreamingRecognitionRequest(inputFormat: captureFormat),
);
session.results.listen((event) {
  switch (event) {
    case RecognitionPartial(:final transcript):
      renderVolatile(transcript.text); // replaces the previous partial
    case RecognitionFinal(:final transcript):
      appendConfirmed(transcript.text); // never revised again
    default:
      break;
  }
});
await session.write(frame);
await session.finish();
```

Each accepted chunk yields the hypothesis for the segment being decoded, emitted
as a volatile `RecognitionPartial` that replaces the last one; when the segment
closes, the same hypothesis is re-emitted as a confirmed `RecognitionFinal` and
the decoder resets. An unchanged hypothesis is not republished, so a chunk of
silence costs a consumer nothing.

**Two caveats worth reading before choosing this over batch.**

*Accuracy is an open question.* Streaming Zipformer against batch Parakeet v3 has
not been evaluated here. Streaming buys latency by decoding with a fixed chunk
and a bounded left context — it cannot revise a word once the encoder has moved
past it, and it is a smaller English-only model besides. If a transcript is
produced after the fact, batch remains the better answer; if you need words on
screen while someone is speaking, this is the path. Applications can also
send rolling windows to a batch recognizer when higher latency is acceptable.

*The endpointer is rule-based, not semantic.* `enableEndpoint` runs sherpa's
three silence rules — trailing silence before speech, trailing silence after
speech, and a maximum utterance length — over decoder state. It decides where
one confirmed segment ends. It cannot tell a thinking pause from a finished
thought, so it is not an end-of-utterance model, and it must not be used to
decide that a speaker has yielded the turn. Use a dedicated end-of-utterance
provider for turn detection. Configure the silence rules through
`SherpaStreamingRecognitionOptions`.

## Platforms

| Platform | Notes |
| --- | --- |
| macOS | x64 and arm64 |
| Windows | x64 |
| Linux | x64 |
| iOS | arm64 |
| Android | arm64, armeabi-v7a, x86, x86_64 |

Native libraries ship with the `sherpa_onnx` platform packages. A host that
cannot resolve the library by leaf name can pass a directory to
`SherpaNativeRuntime(libraryDirectory: ...)`.

## Models

Nothing is bundled. The registry downloads on demand into a directory you
supply, so the SDK never guesses at an application's storage layout.

| Model | Kind | Download | SHA-256 checked | Languages |
| --- | --- | --- | --- | --- |
| Parakeet TDT 0.6B v3 int8 (batch default) | transducer | 487 MB | yes | 25 European |
| Parakeet TDT 0.6B v2 int8 | transducer | 482 MB | yes | English |
| Whisper turbo int8 | whisper | 564 MB | no | 99+ |
| Whisper base.en int8 | whisper | 209 MB | no | English |
| Streaming Zipformer 2023-06-26 (streaming default) | streaming transducer | 310 MB | no | English |
| Streaming Zipformer 20M 2023-02-17 | streaming transducer | 128 MB | no | English |
| Silero VAD | vad | 0.6 MB | yes | — |
| pyannote segmentation 3.0 | diarization | 7 MB | no | — |
| WeSpeaker ResNet34 (VoxCeleb) | embedding | 27 MB | yes | English |

Each catalog entry records the exact download size, and its SHA-256 where the
upstream release publishes one; the older k2-fsa assets publish none, so for
them the size is the check. An install downloads into a `.staging` directory
under the registry root, rejects a download whose size or digest differs,
extracts there, and only then moves the model's own directory into place;
anything else the archive holds is discarded, so an install never touches
other files under the root. A short, corrupt, interrupted or cancelled install
leaves nothing behind, so the model stays unresolved, and staging left by a
process that exited mid-install is removed by the next install. Every
`install*` method takes an `AudioCancellationToken`; a cancelled install
throws `AudioCancelledException`. A download that receives nothing for
`stallTimeout` (30 s by default) fails as `sherpa_model_download_stalled`,
and both the stall and cancellation end the install even on a transport
that keeps its stream open after the client closes. The body is written with
disk backpressure, so a slow disk slows the download instead of buffering it
in memory. Archives unpack with the system's `tar` where there is one, which
reports progress; elsewhere the bundled decoder unpacks them in a worker
isolate that cancellation stops.

A recognition install also writes `.speech_sherpa_install.json` beside the
model's files, recording each file's size. `resolveRecognition` returns the
model only when that manifest is present and every file still has its recorded
size. A file truncated or deleted after install, or a directory nobody
installed, therefore reads as not installed instead of reaching the native
loader, which aborts or hangs the process on a broken model rather than
throwing. A manifest that cannot be read or decoded also reads as not
installed, and the next install replaces it. Same-size corruption is not
detected after install; the digest is checked only while installing.

`installDiarization` stages the segmentation and embedding models together
and moves them into place only once both are verified, then writes
`.speech_sherpa_diarization.json` in the support directory.
`resolveDiarization` returns the pair only while that manifest is present and
both files still have their recorded sizes, so a pair one of whose downloads
failed never resolves, even beside an older file of the same name.

The streaming entries use the `chunk-16-left-128` export with an int8 encoder
and joiner and an fp32 decoder, matching the upstream Flutter streaming example.
The 20M variant is the low-power option for phones and single-board hosts, at
correspondingly lower accuracy.

Recognition weights are hundreds of megabytes. Call
`SherpaSpeechProvider.unloadRecognizer()` when a recording session ends to
release them; the next `transcribe` reloads lazily.

## Two gotchas worth knowing

Both are encoded in this package, and both are easy to reintroduce by
"cleaning up" the code that looks redundant.

**`modelType` stays empty.** sherpa auto-routes NeMo-Parakeet versus k2-Zipformer
from the model metadata. Setting `modelType: 'transducer'` — which reads like the
obviously correct value — makes every Parakeet model fail on a `vocab_size`
metadata lookup.

**Bindings are per-isolate.** sherpa resolves its native symbols into
isolate-local statics, so every isolate touching the API must call
`ensureSherpaBindings()` for itself. Skipping it in a worker surfaces as
`Please initialize sherpa-onnx first`, which reads like a missing model rather
than a missing symbol.

## Threading

A batch decode is a synchronous FFI call lasting hundreds of milliseconds to
seconds. Recognition therefore runs on a long-lived worker isolate, with audio
crossing as `TransferableTypedData`; diarization uses a throwaway isolate,
because it runs once per recording rather than once per window. Audio stays
`Float32List` end to end — sherpa consumes float32 natively, so there is no
PCM16 detour.

Streaming gets a **second worker of the same shape**, not a mode of the batch
one. A streaming step is short, but it is still synchronous FFI and still
belongs off the main isolate; the reason it is a separate worker is that a
streaming session is stateful across commands — the `OnlineStream` *is* the
session, so reset and finish only mean anything relative to the stream a
previous accept fed, where the batch worker creates and frees its stream inside
one command. Sharing one isolate would also queue a multi-second batch decode
ahead of a 100 ms chunk that has to keep up with real time. Driver calls are
serialized by the session, because each one mutates the decode stream the next
one reads.

## Testing

Unit tests inject a fake `SherpaRuntime` and run without ONNX Runtime, model
files, or isolates. Tests that exercise the real native path are gated behind an
environment variable so CI never downloads hundreds of megabytes:

```sh
SPEECH_SHERPA_MODELS=~/models flutter test --tags integration
```

## Attribution

The worker-isolate transcriber, model registry, and diarization configuration
are derived from [Control Center](https://github.com/SamuelAlev/control-center),
MIT © 2026 Samuel Alev. See `NOTICE`. sherpa-onnx itself is Apache-2.0,
© k2-fsa.
