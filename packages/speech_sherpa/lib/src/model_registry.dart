// The install flow — stream to a staging file, extract off the main isolate,
// verify by required-file existence, and clean up partial downloads — is
// derived from Control Center (https://github.com/SamuelAlev/control-center),
// MIT (c) 2026 Samuel Alev. See the NOTICE file at the root of this package.
// Size and digest verification, staged promotion and cancellation are
// Audio Kit's own.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:audio_core/audio_core.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show visibleForTesting;
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
  ///
  /// [vadModel], [segmentationModel] and [embeddingModel] are the catalog
  /// entries; tests replace them with entries whose size and digest describe
  /// a fake download.
  SherpaModelRegistry({
    required this.root,
    SherpaHttpClientFactory? httpClientFactory,
    this.stallTimeout = const Duration(seconds: 30),
    @visibleForTesting bool useSystemTar = true,
    @visibleForTesting this.vadModel = SherpaFileModel.sileroVad,
    @visibleForTesting
    this.segmentationModel = SherpaArchivedFileModel.pyannoteSegmentation,
    @visibleForTesting this.embeddingModel = SherpaFileModel.wespeakerResnet34,
  }) : _httpClientFactory = httpClientFactory ?? http.Client.new,
       _systemTar = useSystemTar ? _findSystemTar() : null;

  /// How long a download may wait for its connection or for its next bytes
  /// before it fails as stalled, so a dropped connection never leaves an
  /// install waiting forever.
  final Duration stallTimeout;

  /// The system's `tar`, which unpacks an archive in seconds; null where
  /// there is none, and the bundled decoder unpacks it instead.
  final String? _systemTar;

  /// The voice-activity model [installVad] installs.
  final SherpaFileModel vadModel;

  /// The diarization segmenter [installDiarization] installs.
  final SherpaArchivedFileModel segmentationModel;

  /// The speaker-embedding model [installDiarization] installs.
  final SherpaFileModel embeddingModel;

  /// Directory that holds every installed model.
  final Directory root;

  final SherpaHttpClientFactory _httpClientFactory;

  /// Directory a recognition model unpacks into.
  Directory recognitionDirectory(SherpaRecognitionModel model) =>
      Directory(p.join(root.path, model.unpackedDirName));

  /// Directory holding the shared single-file models.
  Directory get supportDirectory => Directory(p.join(root.path, 'support'));

  /// Name of the file an install writes beside a recognition model's
  /// files, recording each one's size.
  static const String installManifestFileName = '.speech_sherpa_install.json';

  /// Resolves [model] when a verified install left every required file at
  /// the size it recorded, else null.
  ///
  /// The size check runs on every resolve and costs one `stat` per file, so a
  /// file truncated or replaced after install reads as not installed instead
  /// of reaching the native loader, which aborts or hangs the process on a
  /// broken model rather than throwing. A directory without the manifest, from
  /// an interrupted or manual install, is not installed either. Same-size
  /// corruption is not detected; the archive's SHA-256 is checked only during
  /// the install.
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

    final sizes = _readManifest(dir);
    if (sizes == null) {
      return null;
    }
    for (final file in <File?>[encoder, decoder, tokens, joiner]) {
      if (file == null) continue;
      final recorded = sizes[p.basename(file.path)];
      if (recorded == null ||
          !file.existsSync() ||
          file.lengthSync() != recorded) {
        return null;
      }
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
    final file = File(p.join(supportDirectory.path, vadModel.fileName));
    return file.existsSync() ? file.path : null;
  }

  /// Resolves the diarization pair when both files are present, else null.
  SherpaDiarizationModelPaths? resolveDiarization() {
    final segmentation = File(
      p.join(supportDirectory.path, segmentationModel.modelFile),
    );
    final embedding = File(
      p.join(supportDirectory.path, embeddingModel.fileName),
    );
    if (!segmentation.existsSync() || !embedding.existsSync()) {
      return null;
    }
    return SherpaDiarizationModelPaths(
      segmentation: segmentation.path,
      embedding: embedding.path,
      embeddingModelId: embeddingModel.id,
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
      manifestDirectory: model.unpackedDirName,
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
      model: vadModel,
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
    final segmentation = segmentationModel;
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
      model: embeddingModel,
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
    String? manifestDirectory,
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
      await _extract(
        name: name,
        archive: archive,
        unpacked: unpacked,
        onProgress: onProgress == null
            ? null
            : (progress) => onProgress(0.8 + progress * 0.2),
        cancellationToken: cancellationToken,
      );
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
      if (manifestDirectory != null) {
        _writeManifest(
          Directory(p.join(unpacked.path, manifestDirectory)),
          <String>[
            for (final file in required)
              if (p.split(file).first == manifestDirectory)
                p.relative(file, from: manifestDirectory),
          ],
        );
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

  /// Records the size of each of [files] in [directory]'s manifest. It is
  /// written in staging, so it moves into place with the files it describes.
  static void _writeManifest(Directory directory, List<String> files) {
    File(p.join(directory.path, installManifestFileName)).writeAsStringSync(
      jsonEncode(<String, Object>{
        'version': 1,
        'files': <String, int>{
          for (final file in files)
            file: File(p.join(directory.path, file)).lengthSync(),
        },
      }),
    );
  }

  /// The recorded file sizes, or null when the manifest is missing or
  /// unreadable.
  static Map<String, int>? _readManifest(Directory directory) {
    final manifest = File(p.join(directory.path, installManifestFileName));
    if (!manifest.existsSync()) {
      return null;
    }
    try {
      final json = jsonDecode(manifest.readAsStringSync());
      if (json case {'version': 1, 'files': final Map<String, Object?> files}) {
        return <String, int>{
          for (final MapEntry(:key, :value) in files.entries)
            if (value is int) key: value,
        };
      }
    } on FormatException {
      return null;
    }
    return null;
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
    // A watchdog closes the client when the connection or the body goes
    // quiet for [stallTimeout]; the transfer then fails as stalled.
    var stalled = false;
    // Ends the wait for a response that never comes; closing the client does
    // not end it on every transport.
    final quiet = Completer<void>();
    Timer? watchdog;
    void watch() {
      watchdog?.cancel();
      watchdog = Timer(stallTimeout, () {
        stalled = true;
        client.close();
        if (!quiet.isCompleted) quiet.complete();
      });
    }

    IOSink? sink;
    try {
      final http.StreamedResponse response;
      watch();
      try {
        response = await Future.any([
          client.send(http.Request('GET', Uri.parse(url))),
          // A request that never answers is not ended by closing the client
          // on every transport; the watchdog's mark ends the wait.
          Future<void>.delayed(
            stallTimeout,
          ).then<http.StreamedResponse>((_) => throw _stalled(name)),
        ]);
      } on Object {
        cancellationToken?.throwIfCancelled();
        if (stalled) throw _stalled(name);
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
        watch();
        await for (final chunk in response.stream) {
          watch();
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
        if (stalled) throw _stalled(name);
        rethrow;
      }
      watchdog?.cancel();
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
      watchdog?.cancel();
      registration?.dispose();
      await sink?.close();
      client.close();
    }
  }

  static SpeechFailure _stalled(String name) => sherpaSpeechFailure(
    'sherpa_model_download_stalled',
    'install',
    'The $name download stopped receiving data. Check the connection and '
        'try again.',
    retryable: true,
  );

  /// Unpacks [archive] into [unpacked], reporting how much of the archive
  /// has been read. The system's `tar` reads it from a pipe, so progress
  /// follows its decoding and cancelling stops it; without one, the bundled
  /// bzip2 decoder runs off the caller's isolate, reporting only its end.
  Future<void> _extract({
    required String name,
    required File archive,
    required Directory unpacked,
    SherpaInstallProgress? onProgress,
    AudioCancellationToken? cancellationToken,
  }) async {
    await unpacked.create(recursive: true);
    final tar = _systemTar;
    if (tar == null) {
      final archivePath = archive.path, unpackedPath = unpacked.path;
      await Isolate.run(() => _extractTarBz2(archivePath, unpackedPath));
      onProgress?.call(1);
      return;
    }
    final process = await Process.start(tar, [
      '-xjf',
      '-',
      '-C',
      unpacked.path,
    ]);
    final registration = cancellationToken?.register((_) => process.kill());
    try {
      final errors = process.stderr.transform(utf8.decoder).join();
      final output = process.stdout.drain<void>();
      final total = await archive.length();
      var read = 0;
      try {
        await process.stdin.addStream(
          archive.openRead().map((chunk) {
            read += chunk.length;
            onProgress?.call(total == 0 ? 1 : read / total);
            return chunk;
          }),
        );
        await process.stdin.close();
      } on Object {
        // tar stopped reading; its exit code says why.
      }
      final code = await process.exitCode;
      await output;
      cancellationToken?.throwIfCancelled();
      if (code != 0) {
        throw sherpaSpeechFailure(
          'sherpa_model_extract_failed',
          'install',
          'The $name archive could not be unpacked: ${(await errors).trim()}',
        );
      }
    } finally {
      registration?.dispose();
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

/// The system's `tar` at its fixed path, never through `PATH`: macOS and
/// Windows 10+ ship bsdtar, and Linux has GNU tar; both read bzip2 and
/// refuse entries that leave the destination.
String? _findSystemTar() {
  final candidates = Platform.isMacOS
      ? const ['/usr/bin/tar']
      : Platform.isLinux
      ? const ['/usr/bin/tar', '/bin/tar']
      : Platform.isWindows
      ? [
          p.join(
            Platform.environment['SystemRoot'] ?? r'C:\Windows',
            'System32',
            'tar.exe',
          ),
        ]
      : const <String>[];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}
