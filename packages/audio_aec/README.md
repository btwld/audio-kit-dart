# audio_aec

Acoustic echo cancellation for Audio Kit streams, over WebRTC AEC3.

A microphone picks up whatever is playing out of the speakers. Downstream
recognition transcribes that bleed as a degraded duplicate of the far side,
wrongly attributed to the local speaker. This package feeds a system loopback
capture to AEC3 as the far-end reference and subtracts it from the microphone at
the signal level.

On macOS (Apple Silicon and Intel), glibc-based Linux x64, and Windows x64, Dart’s build
hook downloads the matching [native runtime][runtime] and verifies its SHA-256
digest. Applications can call `probeAecRuntime()` to check availability for a
specific format before starting capture.

[runtime]: https://github.com/btwld/audio-kit-dart/releases/tag/audio_aec-native-v0.1.0

## Layers

| Layer | Type | Needs a native library |
|---|---|---|
| Six-symbol C ABI + loader | `AecBindings`, `FfiAecBindings`, `AecUnavailable` | yes |
| One stateful engine instance | `AecProcessor`, `AecEngine`, `AecMetrics` | yes |
| Stream composition | `AecMicFilter`, `AecMicFilterSession` | no (passthrough works) |

The pure math this builds on — envelope cross-correlation delay estimation
(`AecDelayEstimator`) and 10 ms block accumulation (`AecBlockAccumulator`) —
lives in `audio_processing` and needs nothing native.

```dart
import 'package:audio_aec/audio_aec.dart';

final filter = AecMicFilter(
  near: microphoneSource,           // the mic, captured dry
  far: loopbackSource,              // system audio, the far-end reference
  processor: AecProcessor.create(), // throws AecUnavailable if no library
);

final session = await filter.prepare();
session.frames.listen(handleCleanedFrame);
await session.start();
```

With no processor, `AecMicFilter(near: mic)` — or the clearer
`AecMicFilter.passthrough(near: mic)` — reproduces the microphone exactly. That
is the in-person capture mode, where there is no loopback and so nothing to
cancel. It is *not* a fallback for a missing library: that surfaces as
`AecUnavailable`, loudly, rather than quietly recording an echo-laden track.

## Contract

- **Mono float32 at a WebRTC-supported rate (8, 16, 32, or 48 kHz).** The
  engine is created for one sample rate and the filter rejects a capture that
  disagrees, because feeding AEC3 the wrong rate produces no error and no
  cancellation. Resample to the configured rate and downmix to mono upstream
  when the capture format differs.
- **One 10 ms block per native call**, from 80 samples at 8 kHz through 480 at
  48 kHz — the unit `AudioProcessing::GetFrameSize` defines. `AecProcessor`
  throws on any other size rather than asserting, since a wrong-sized block is
  a memory-correctness problem, not a wrong number. Chunk sizes coming off a
  capture backend are chopped to that unit by `AecBlockAccumulator`.
- **One far-end block per near-end block.** When the loopback stalls, the
  reference is zero-padded rather than left to go stale, and
  `referenceBlocksZeroPadded` counts it.
- **The filter emits a single output**: the cleaned microphone. It consumes the
  far source exclusively as the reference and does not re-emit it. If you also
  need the loopback audio downstream, fan it out with `AudioRouter` before
  handing it here.
- **The output stream cannot be paused.** Pausing would propagate backpressure
  into a realtime capture and starve the engine's render buffer; a stalled
  consumer buffers this filter's own controller instead.

### Capture dry

Do not enable echo cancellation, AGC, or noise suppression on the microphone
device. On macOS that switches it to Voice-Processing I/O, which ducks playback
and breaks the system tap — killing the reference this package needs. Software
AEC exists precisely because the OS-level alternative destroys the loopback.

## Main-isolate only

`AecProcessor` owns a raw native pointer. A pointer is an address in this
process's heap with no ownership attached: it is not sendable across isolates,
and the AEC3 instance behind it is stateful — the adaptive filter, the render
buffer, and the delay estimate all advance with every block, without internal
locking. Every call for a given processor must come from the isolate that
created it.

This is not worth engineering around. Each 10 ms block is sub-millisecond work,
far cheaper than shipping audio over a port, and Audio Kit's stream graph is
main-isolate plumbing already.

## Delay calibration

The microphone and the loopback are two independent operating-system captures
with drifting clocks and a delivery offset that depends entirely on the user's
hardware, so AEC3 alone often never locks onto the echo. `AecDelayEstimator`
measures the real offset live by cross-correlating the two energy envelopes on
one shared arrival clock. The filter then buffers the microphone so the
reference leads by a target 80 ms, and feeds AEC3 a real `stream_delay_ms` that
keeps tracking the live measurement as the clocks drift.

Until that measurement locks, the microphone passes through the engine with no
buffering and no delay hint — never worse than the no-AEC baseline. Watch it
through the session:

```dart
if (session.isLocked) {
  print('lead ${session.streamDelayMs}ms, mic buffer ${session.micBufferMs}ms');
  print('ERLE ${session.metrics().erle}dB');  // > 0 means echo is coming out
}
```

`referenceBlocksMatched` and `referenceBlocksZeroPadded` are the other half of
the picture: a climbing zero-pad count means the reference stream is not keeping
up, and cancellation is degrading for reasons that have nothing to do with the
engine.

## float32 to int16 and back

Audio Kit is float32 end to end. AEC3 is int16-only, so this package is the one
place in the graph where audio makes a lossy round trip:

| Edge | Direction |
|---|---|
| Far-end reference feed | float32 → int16 |
| Capture in and out | float32 → int16 → float32 |

At the supported mono rates the conversion cost is negligible; the reason to state it is
precision, not performance. One round trip quantizes to within a single step
(`1/32767`). Stacking a second one — running the AEC and then a provider that
demands PCM16 — should be avoided by ordering the graph deliberately, not by
accident. Conversion uses `floatToPcm16` / `pcm16ToFloat` from
`audio_processing`, which clamp rather than wrap.

## Loader resolution order

`AecProcessor.create()` resolves a library by trying, in order:

1. An explicit `libraryPath` argument.
2. A **code asset registered by `hook/build.dart`**, when your SDK ran build
   hooks and the hook had a binary to offer. This one has no path — the SDK
   copies the library next to your build output and it is addressed by asset id
   — so it is resolved through `@Native` externals rather than
   `DynamicLibrary.open`. See [`doc/DISTRIBUTION.md`](https://github.com/btwld/audio-kit-dart/blob/main/packages/audio_aec/doc/DISTRIBUTION.md).
3. The `AUDIO_AEC_LIBRARY` environment variable, naming the library file itself
   (not a directory).
4. Conventional locations beside the running executable: the executable's own
   directory, plus the desktop bundle layout — `../Frameworks` on macOS, `lib/`
   on Linux.
5. The bare platform file name (`libaec_ffi.dylib`, `libaec_ffi.so`,
   `aec_ffi.dll`), letting the operating system's search path resolve it. Note
   that this can also resolve an image the host process has already loaded.

Steps 3–5 are unchanged from before build hooks existed, which is what keeps a
consumer who ignores hooks entirely on exactly the old behaviour.

When nothing resolves, or a library resolves but is missing a symbol, you get an
`AecUnavailable` listing every path tried and how to supply one. Nothing
crashes, and there is no silent degradation. An embedder that knows its own
bundle layout can bypass the policy with `FfiAecBindings.openFrom(candidates)`.

For a settings screen or capture capability probe, use `probeAecRuntime()`.
Unlike `NativeAssetAecBindings.available` (which answers only whether an asset
symbol resolves), the runtime probe calls `aec_create` for the requested format
and destroys the temporary handle before returning. `isAvailable` is therefore
true only when that concrete engine can really instantiate:

```dart
final capability = probeAecRuntime(sampleRate: 48000);
if (capability.isAvailable) {
  print('AEC3 ${capability.version ?? 'unknown version'}');
}
```

## Native library

Install the package with `dart pub add audio_aec`. The first build for a
supported target needs network access to fetch the runtime. Dart bundles the
verified library with the application. The macOS binaries target 12.0 or later.
Use `dart run`, `dart test`, or `dart build cli` for a standalone Dart
application. Flutter runs the hook during desktop builds.

For offline builds, point the hook at a local library in the consuming
application’s root `pubspec.yaml`.

```yaml
hooks:
  user_defines:
    audio_aec:
      prebuilt: path/to/libaec_ffi.dylib
```

If the hook cannot supply a library, `probeAecRuntime()` reports the failure
and `AecProcessor.create()` can still load an explicitly supplied library.
See the [distribution guide](https://github.com/btwld/audio-kit-dart/blob/main/packages/audio_aec/doc/DISTRIBUTION.md) for build requirements,
custom URLs, signing, and release verification.

## Attribution

The Dart integration and native shim include adaptations from Control Center
(MIT, © 2026 Samuel Alev). The runtime includes WebRTC audio processing and
Abseil. See the [bundled notices](https://github.com/btwld/audio-kit-dart/blob/main/packages/audio_aec/NOTICE)
for the applicable licenses and redistribution terms.
