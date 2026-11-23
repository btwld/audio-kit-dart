// The install flow — stream to a staging file, extract off the main isolate,
// verify by required-file existence, and clean up partial downloads — is
// derived from Control Center (https://github.com/SamuelAlev/control-center),
// MIT (c) 2026 Samuel Alev. See the NOTICE file at the root of this package.
// Size and digest verification, staged promotion and cancellation are
// Audio Kit's own.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:audio_core/audio_core.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:speech_core/speech_core.dart' show SpeechFailure;

import 'failure.dart';
import 'models.dart';

/// Opens an HTTP client, so tests can substitute a transport.
typedef SherpaHttpClientFactory = http.Client Function();

/// Reports install progress in the inclusive range 0–1.
typedef SherpaInstallProgress = void Function(double progress);

/// Downloads, installs, and resolves the sherpa-onnx model files.
///
/// The registry owns no directories of its own: [root] is supplied by the
/// caller so the SDK never guesses at an application's storage layout.
///
/// An install downloads into a staging directory under [root], checks the
/// exact byte count and, when the catalog knows it, the SHA-256, extracts
/// there, and only then moves the files into place. A short, corrupt,
/// interrupted or cancelled install leaves nothing behind, so the model stays
/// unresolved until a later install succeeds.
final class SherpaModelRegistry {
  /// Creates a registry rooted at [root].
  SherpaModelRegistry({
    required this.root,
    SherpaHttpClientFactory? httpClientFactory,
  }) : _httpClientFactory = httpClientFactory ?? http.Client.new;

  /// Directory that holds every installed model.
  final Directory root;

  final SherpaHttpClientFactory _httpClientFactory;

  /// Directory a recognition model unpacks into.
  Directory recognitionDirectory(SherpaRecognitionModel model) =>
      Directory(p.join(root.path, model.unpackedDirName));

  /// Directory holding the shared single-file models.
  Directory get supportDirectory => Directory(p.join(root.path, 'support'));

  /// Resolves [model] when every required file is present, else null.
  SherpaRecognitionModelPaths? resolveRecognition(
    SherpaRecognitionModel model,
  ) {
    final dir = recognitionDirectory(model);
    final encoder = File(p.join(dir.path, model.encoderFile));
    final decoder = File(p.join(dir.path, model.decoderFile));
    final tokens = File(p.join(dir.path, model.tokensFile));
    final joinerName = model.joinerFile;
    final joiner = joinerName == null
        ? null
        : File(p.join(dir.path, joinerName));

    final complete =
        encoder.existsSync() &&
        decoder.existsSync() &&
        tokens.existsSync() &&
        (joiner == null || joiner.existsSync());
    if (!complete) {
      return null;
    }
    return SherpaRecognitionModelPaths(
      model: model,
      encoder: encoder.path,
      decoder: decoder.path,
      tokens: tokens.path,
      joiner: joiner?.path,
    );
  }

  /// Resolves the Silero VAD model path when installed, else null.
  String? resolveVad() {
    final file = File(
      p.join(supportDirectory.path, SherpaFileModel.sileroVad.fileName),
    );
    return file.existsSync() ? file.path : null;
  }

  /// Resolves the diarization pair when both files are present, else null.
  SherpaDiarizationModelPaths? resolveDiarization() {
    final segmentation = File(
      p.join(
        supportDirectory.path,
        SherpaArchivedFileModel.pyannoteSegmentation.modelFile,
      ),
    );
    final embedding = File(
      p.join(supportDirectory.path, SherpaFileModel.wespeakerResnet34.fileName),
    );
    if (!segmentation.existsSync() || !embedding.existsSync()) {
      return null;
    }
    return SherpaDiarizationModelPaths(
      segmentation: segmentation.path,
      embedding: embedding.path,
      embeddingModelId: SherpaFileModel.wespeakerResnet34.id,
    );
  }

  /// Installs [model], returning immediately when it is already present.
  ///
  /// Cancelling [cancellationToken] stops the download and discards it,
  /// throwing [AudioCancelledException].
  Future<SherpaRecognitionModelPaths> installRecognition(
    SherpaRecognitionModel model, {
    SherpaInstallProgress? onProgress,
    AudioCancellationToken? cancellationToken,
  }) async {
    final existing = resolveRecognition(model);
    if (existing != null) {
      onProgress?.call(1);
      return existing;
    }
    await _installArchive(
      name: model.displayName,
      url: model.archiveUrl,
      expectedBytes: model.archiveBytes,
      expectedSha256: model.archiveSha256,
      destination: root,
      // The archive unpacks into one directory, which must hold every file.
      required: <String>[
        p.join(model.unpackedDirName, model.encoderFile),
        p.join(model.unpackedDirName, model.decoderFile),
        p.join(model.unpackedDirName, model.tokensFile),
        if (model.joinerFile case final joiner?)
          p.join(model.unpackedDirName, joiner),
      ],
      onProgress: onProgress,
      cancellationToken: cancellationToken,
    );
    final resolved = resolveRecognition(model);
    if (resolved == null) {
      throw sherpaSpeechFailure(
        'sherpa_model_install_incomplete',
        'install',
        'The ${model.displayName} archive did not contain the expected files.',
      );
    }
    return resolved;
  }

  /// Installs the Silero VAD model, returning its path.
  Future<String> installVad({
    SherpaInstallProgress? onProgress,
    AudioCancellationToken? cancellationToken,
  }) async {
    final existing = resolveVad();
    if (existing != null) {
      onProgress?.call(1);
      return existing;
    }
    await _installFile(
      model: SherpaFileModel.sileroVad,
      onProgress: onProgress,
      cancellationToken: cancellationToken,
    );
    final resolved = resolveVad();
    if (resolved == null) {
      throw sherpaSpeechFailure(
        'sherpa_model_install_incomplete',
        'install',
        'The Silero VAD model could not be installed.',
      );
    }
    return resolved;
  }

  /// Installs the pyannote and WeSpeaker pair used for diarization.
  Future<SherpaDiarizationModelPaths> installDiarization({
    SherpaInstallProgress? onProgress,
    AudioCancellationToken? cancellationToken,
  }) async {
    final existing = resolveDiarization();
    if (existing != null) {
      onProgress?.call(1);
      return existing;
    }
    const segmentation = SherpaArchivedFileModel.pyannoteSegmentation;
    await _installArchive(
      name: segmentation.displayName,
      url: segmentation.archiveUrl,
      expectedBytes: segmentation.archiveBytes,
      expectedSha256: segmentation.archiveSha256,
      destination: supportDirectory,
      required: <String>[segmentation.modelFile],
      onProgress: onProgress == null
          ? null
          : (progress) => onProgress(progress * 0.5),
      cancellationToken: cancellationToken,
    );
    await _installFile(
      model: SherpaFileModel.wespeakerResnet34,
      onProgress: onProgress == null
          ? null
          : (progress) => onProgress(0.5 + progress * 0.5),
      cancellationToken: cancellationToken,
    );
    final resolved = resolveDiarization();
    if (resolved == null) {
      throw sherpaSpeechFailure(
        'sherpa_model_install_incomplete',
        'install',
        'The diarization models could not be installed.',
      );
    }
    return resolved;
  }

  /// Removes an installed recognition model.
  Future<void> uninstallRecognition(SherpaRecognitionModel model) async {
    final dir = recognitionDirectory(model);
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  /// A fresh directory under [root] that one install downloads and extracts
  /// into; nothing in it is visible to the resolvers.
  Future<Directory> _stagingDirectory() async {
    final staging = Directory(p.join(root.path, '.staging'));
    await staging.create(recursive: true);
    return staging.createTemp('install-');
  }

  Future<void> _installFile({
    required SherpaFileModel model,
    SherpaInstallProgress? onProgress,
    AudioCancellationToken? cancellationToken,
  }) async {
    final staging = await _stagingDirectory();
    try {
      final staged = File(p.join(staging.path, model.fileName));
      await _download(
        name: model.displayName,
        url: model.url,
        expectedBytes: model.sizeBytes,
        expectedSha256: model.sha256,
        target: staged,
        onProgress: onProgress,
        cancellationToken: cancellationToken,
      );
      await supportDirectory.create(recursive: true);
      await _promote(
        staged,
        File(p.join(supportDirectory.path, model.fileName)),
      );
      onProgress?.call(1);
    } finally {
      await _discard(staging);
    }
  }

  Future<void> _installArchive({
    required String name,
    required String url,
    required int expectedBytes,
    required String? expectedSha256,
    required Directory destination,
    required List<String> required,
    SherpaInstallProgress? onProgress,
    AudioCancellationToken? cancellationToken,
  }) async {
    final staging = await _stagingDirectory();
    try {
      final archive = File(p.join(staging.path, p.basename(url)));
      await _download(
        name: name,
        url: url,
        expectedBytes: expectedBytes,
        expectedSha256: expectedSha256,
        target: archive,
        // Extraction is the last 20% of the reported progress.
        onProgress: onProgress == null
            ? null
            : (progress) => onProgress(progress * 0.8),
        cancellationToken: cancellationToken,
      );
      final unpacked = Directory(p.join(staging.path, 'unpacked'));
      // bzip2 decoding is opaque and CPU-bound; keep it and the archive's
      // bytes off the caller's isolate so a UI stays responsive.
      final archivePath = archive.path, unpackedPath = unpacked.path;
      await Isolate.run(() => _extractTarBz2(archivePath, unpackedPath));
      cancellationToken?.throwIfCancelled();
      for (final file in required) {
        if (!File(p.join(unpacked.path, file)).existsSync()) {
          throw sherpaSpeechFailure(
            'sherpa_model_install_incomplete',
            'install',
            'The $name archive did not contain the expected files.',
          );
        }
      }
      await destination.create(recursive: true);
      // Each top-level entry replaces what was there, so a half-written
      // earlier attempt never mixes with this one.
      for (final entry in unpacked.listSync()) {
        await _promote(
          entry,
          FileSystemEntity.isDirectorySync(entry.path)
              ? Directory(p.join(destination.path, p.basename(entry.path)))
              : File(p.join(destination.path, p.basename(entry.path))),
        );
      }
      onProgress?.call(1);
    } finally {
      await _discard(staging);
    }
  }

  /// Moves verified [staged] content to [target], replacing it.
  static Future<void> _promote(
    FileSystemEntity staged,
    FileSystemEntity target,
  ) async {
    if (target.existsSync()) {
      await target.delete(recursive: true);
    }
    await staged.rename(target.path);
  }

  static Future<void> _discard(Directory staging) async {
    if (staging.existsSync()) {
      await staging.delete(recursive: true);
    }
  }

  /// Streams [url] into [target], checking its exact size and, when known,
  /// its SHA-256 as the bytes arrive.
  Future<void> _download({
    required String name,
    required String url,
    required int expectedBytes,
    required String? expectedSha256,
    required File target,
    SherpaInstallProgress? onProgress,
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    final client = _httpClientFactory();
    // Closing the client aborts a request that is waiting on the network.
    final registration = cancellationToken?.register((_) => client.close());
    IOSink? sink;
    try {
      final http.StreamedResponse response;
      try {
        response = await client.send(http.Request('GET', Uri.parse(url)));
      } on Object {
        cancellationToken?.throwIfCancelled();
        rethrow;
      }
      if (response.statusCode != 200) {
        throw sherpaSpeechFailure(
          'sherpa_model_download_failed',
          'install',
          'The model download failed with status ${response.statusCode}.',
          retryable: response.statusCode >= 500,
        );
      }
      final length = response.contentLength;
      if (length != null && length != expectedBytes) {
        throw _sizeMismatch(name, expectedBytes, length);
      }
      final digest = _DigestSink();
      final hasher = crypto.sha256.startChunkedConversion(digest);
      sink = target.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.stream) {
          cancellationToken?.throwIfCancelled();
          received += chunk.length;
          if (received > expectedBytes) {
            throw _sizeMismatch(name, expectedBytes, received);
          }
          sink.add(chunk);
          hasher.add(chunk);
          onProgress?.call((received / expectedBytes).clamp(0, 1));
        }
      } on Object {
        cancellationToken?.throwIfCancelled();
        rethrow;
      }
      cancellationToken?.throwIfCancelled();
      await sink.flush();
      await sink.close();
      sink = null;
      hasher.close();
      if (received != expectedBytes) {
        throw _sizeMismatch(name, expectedBytes, received);
      }
      if (expectedSha256 != null && digest.value.toString() != expectedSha256) {
        throw sherpaSpeechFailure(
          'sherpa_model_download_corrupt',
          'install',
          'The $name download is corrupt. Try again.',
          retryable: true,
        );
      }
    } finally {
      registration?.dispose();
      await sink?.close();
      client.close();
    }
  }

  static SpeechFailure _sizeMismatch(String name, int expected, int actual) =>
      sherpaSpeechFailure(
        'sherpa_model_download_incomplete',
        'install',
        'The $name download has $actual bytes instead of $expected. Try again.',
        retryable: true,
      );
}

/// Holds the digest a chunked hash produces.
final class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? _value;

  crypto.Digest get value => _value!;

  @override
  void add(crypto.Digest data) => _value = data;

  @override
  void close() {}
}

/// Extracts the `.tar.bz2` at [archivePath] into [destinationPath].
void _extractTarBz2(String archivePath, String destinationPath) {
  final tarBytes = BZip2Decoder().decodeBytes(
    File(archivePath).readAsBytesSync(),
  );
  final archive = TarDecoder().decodeBytes(tarBytes);
  for (final entry in archive) {
    if (!entry.isFile) {
      continue;
    }
    // Reject traversal outside the destination before writing anything.
    final normalized = p.normalize(entry.name);
    if (p.isAbsolute(normalized) || normalized.startsWith('..')) {
      continue;
    }
    final file = File(p.join(destinationPath, normalized));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(entry.readBytes() ?? const <int>[]);
  }
}
