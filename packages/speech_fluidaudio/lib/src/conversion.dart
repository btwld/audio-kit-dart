import 'dart:async';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:audio_processing/audio_processing.dart';
import 'package:speech_core/speech_core.dart';

import 'options.dart';
import 'session_support.dart';

/// Stateful conversion from one fixed input format to 16 kHz mono PCM.
///
/// The output is one unbroken stream whatever the input did: the converter
/// numbers its frames itself, so their sequences and sample offsets always
/// follow on and none carries a discontinuity. Consumers that cut the output
/// into fixed chunks therefore never see a break of their own. Timestamps are
/// left as the source reported them.
final class FluidPcm16MonoConverter {
  /// Creates a converter for [inputFormat].
  ///
  /// [discontinuityPolicy] defaults to [FluidDiscontinuityPolicy.fail], which
  /// suits finite audio; the streaming sessions pass their own.
  FluidPcm16MonoConverter(
    this.inputFormat, {
    this.discontinuityPolicy = FluidDiscontinuityPolicy.fail,
  });

  /// Fixed caller-facing format.
  final AudioFormat inputFormat;

  /// What [process] does with a frame that does not continue the one before.
  final FluidDiscontinuityPolicy discontinuityPolicy;

  final AudioDownmixer _downmixer = AudioDownmixer();
  final AudioResampler _resampler = AudioResampler(outputSampleRate: 16000);
  AudioStreamKey? _stream;
  int? _expectedInputOffset;
  var _outputSampleOffset = 0;
  var _outputSequence = 0;
  var _resumedDiscontinuityCount = 0;

  /// Number of breaks in the input that [process] has carried on across.
  ///
  /// Only [FluidDiscontinuityPolicy.resume] counts any. A tally for the
  /// converter's whole life: [reset] leaves it alone.
  int get resumedDiscontinuityCount => _resumedDiscontinuityCount;

  /// Converts one input frame while retaining resampler state.
  ///
  /// Under [FluidDiscontinuityPolicy.fail] a frame marked discontinuous is
  /// refused with `fluid_discontinuous_audio`. Under
  /// [FluidDiscontinuityPolicy.resume] a break, marked or shown by a jump in
  /// sample offsets, drains what the resampler held of the audio before it and
  /// starts the audio after it from fresh state, so nothing is interpolated
  /// across the gap.
  List<AudioFrame> process(AudioFrame frame) {
    if (frame.format != inputFormat) {
      throw fluidAudioFailure(
        'fluid_format_mismatch',
        AudioFailureStage.processing,
        'The audio frame format does not match the prepared session.',
      );
    }
    final resumes = discontinuityPolicy == FluidDiscontinuityPolicy.resume;
    if (frame.discontinuity != null && !resumes) {
      throw fluidAudioFailure(
        'fluid_discontinuous_audio',
        AudioFailureStage.processing,
        'FluidAudio cannot safely process a discontinuous speech route.',
      );
    }
    final key = AudioStreamKey.fromFrame(frame);
    final existing = _stream;
    if (existing != null && existing != key) {
      throw fluidAudioFailure(
        'fluid_multiple_tracks',
        AudioFailureStage.processing,
        'A FluidAudio speech session accepts exactly one audio track.',
      );
    }
    _stream = key;

    final output = <AudioFrame>[];
    var input = frame;
    final expectedOffset = _expectedInputOffset;
    // A mark on the very first frame separates it from audio this converter
    // never saw, so there is nothing to carry on across.
    final broke =
        existing != null &&
        (frame.discontinuity != null ||
            (expectedOffset != null && expectedOffset != frame.sampleOffset));
    if (resumes && broke) {
      output.addAll(_resampler.flush(stream: key));
      _resumedDiscontinuityCount += 1;
    }
    if (frame.discontinuity != null) {
      // Cleared so the transforms do not reset a second time or pass it on.
      input = AudioFrame.owned(
        format: frame.format,
        samples: frame.samples,
        sourceId: frame.sourceId,
        trackId: frame.trackId,
        clockId: frame.clockId,
        sequence: frame.sequence,
        sampleOffset: frame.sampleOffset,
        timestamp: frame.timestamp,
      );
    }
    _expectedInputOffset = frame.endSampleOffset;

    for (final mono in _downmixer.process(input)) {
      output.addAll(_resampler.process(mono));
    }
    return <AudioFrame>[for (final converted in output) _renumber(converted)];
  }

  /// Flushes the resampler look-behind.
  List<AudioFrame> flush() {
    final key = _stream;
    if (key == null) {
      return const <AudioFrame>[];
    }
    return <AudioFrame>[
      for (final converted in _resampler.flush(stream: key))
        _renumber(converted),
    ];
  }

  /// Discards all transform state.
  void reset() {
    _downmixer.reset();
    _resampler.reset();
    _stream = null;
    _expectedInputOffset = null;
    _outputSampleOffset = 0;
    _outputSequence = 0;
  }

  /// Places [converted], which the transforms own, next on the output stream.
  AudioFrame _renumber(AudioFrame converted) {
    final output = AudioFrame.owned(
      format: converted.format,
      samples: converted.samples,
      sourceId: converted.sourceId,
      trackId: converted.trackId,
      clockId: converted.clockId,
      sequence: _outputSequence,
      sampleOffset: _outputSampleOffset,
      timestamp: converted.timestamp,
    );
    _outputSequence += 1;
    _outputSampleOffset += output.frameCount;
    return output;
  }
}

/// Collected 16 kHz mono PCM from a finite provider-neutral source.
final class FluidCollectedAudio {
  const FluidCollectedAudio({required this.samples, required this.duration});

  /// Contiguous PCM samples.
  final Float32List samples;

  /// Duration derived from collected samples.
  final Duration duration;
}

/// Starts and drains a finite source using subscribe-before-start ordering.
Future<FluidCollectedAudio> collectFluidAudio(
  AudioSource source, {
  AudioCancellationToken? cancellation,
  void Function(double progress)? onProgress,
  required int maximumConvertedSamples,
}) async {
  if (maximumConvertedSamples <= 0) {
    throw ArgumentError.value(
      maximumConvertedSamples,
      'maximumConvertedSamples',
      'Must be positive.',
    );
  }
  cancellation?.throwIfCancelled();
  onProgress?.call(0);

  AudioSourceSession? session;
  StreamSubscription<AudioFrame>? framesSubscription;
  StreamSubscription<AudioSessionStatus>? statusSubscription;
  final done = Completer<void>();
  Object? completionError;
  StackTrace? completionStackTrace;
  final Future<void> observedDone = done.future.catchError((
    Object error,
    StackTrace stackTrace,
  ) {
    completionError = error;
    completionStackTrace = stackTrace;
  });
  final chunks = <Float32List>[];
  var sampleCount = 0;
  var acceptingFrames = true;
  FluidPcm16MonoConverter? converter;

  void completeError(Object error, [StackTrace? stackTrace]) {
    if (!done.isCompleted) {
      acceptingFrames = false;
      done.completeError(error, stackTrace ?? StackTrace.current);
    }
  }

  void append(AudioFrame output) {
    if (!acceptingFrames) {
      return;
    }
    if (output.samples.length > maximumConvertedSamples - sampleCount) {
      throw fluidSpeechFailure(
        'fluid_batch_audio_too_long',
        'preprocessing',
        'The audio source exceeds the configured FluidAudio batch limit.',
      );
    }
    final samples = Float32List.fromList(output.samples);
    chunks.add(samples);
    sampleCount += samples.length;
  }

  try {
    session = await source.prepare(cancellationToken: cancellation);
    cancellation?.throwIfCancelled();
    converter = FluidPcm16MonoConverter(session.format);

    framesSubscription = session.frames.listen(
      (frame) {
        if (!acceptingFrames) {
          return;
        }
        try {
          for (final output in converter!.process(frame)) {
            append(output);
          }
        } catch (error, stackTrace) {
          completeError(error, stackTrace);
        }
      },
      onError: completeError,
      onDone: () {
        if (!done.isCompleted) {
          done.complete();
        }
      },
    );
    statusSubscription = session.statuses.listen((status) {
      final failure = status.failure;
      if (status.state == AudioSessionState.failed && failure != null) {
        completeError(failure);
      }
    });

    if (cancellation != null) {
      unawaited(
        cancellation.whenCancelled.then((_) async {
          if (!done.isCompleted) {
            completeError(AudioCancelledException(cancellation.cancellation!));
          }
          await session?.abort(
            failure: fluidAudioFailure(
              'fluid_cancelled',
              AudioFailureStage.provider,
              'The FluidAudio operation was cancelled.',
            ),
          );
        }),
      );
    }

    await session.start(cancellationToken: cancellation);
    onProgress?.call(0.25);
    await observedDone;
    if (completionError case final Object error) {
      Error.throwWithStackTrace(
        error,
        completionStackTrace ?? StackTrace.current,
      );
    }

    for (final output in converter.flush()) {
      append(output);
    }
    onProgress?.call(0.5);
  } finally {
    await framesSubscription?.cancel();
    await statusSubscription?.cancel();
    await session?.close();
  }

  final samples = Float32List(sampleCount);
  var offset = 0;
  for (final chunk in chunks) {
    samples.setRange(offset, offset + chunk.length, chunk);
    offset += chunk.length;
  }
  return FluidCollectedAudio(
    samples: samples,
    duration: AudioFormat(
      sampleRate: 16000,
      channels: 1,
    ).durationForFrames(sampleCount),
  );
}

/// Converts arbitrary caught failures into a safe speech-layer failure.
SpeechFailure fluidSpeechFailure(
  String code,
  String stage,
  String message, {
  bool retryable = false,
  Object? cause,
}) {
  if (cause case final SpeechFailure failure) {
    return failure;
  }
  return SpeechFailure(
    code: code,
    stage: stage,
    providerId: 'fluidaudio',
    retryable: retryable,
    safeMessage: message,
    safeCause: cause?.runtimeType.toString(),
  );
}

/// Normalizes a BCP-47 tag to the ISO 639-1-style prefix FluidAudio accepts.
String? fluidLanguageCode(String? languageTag) {
  final value = languageTag?.trim();
  if (value == null || value.isEmpty) {
    return null;
  }
  return value.split(RegExp('[-_]')).first.toLowerCase();
}
