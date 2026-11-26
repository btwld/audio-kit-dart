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

  /// Name of the file a diarization install writes in [supportDirectory],
  /// recording the size of both files of the pair.
  static const String diarizationManifestFileName =
      '.speech_sherpa_diarization.json';

  /// Resolves [model] when a verified install left every required file at
  /// the size it recorded, else null.
  ///
  /// The size check runs on every resolve and costs one `stat` per file, so a
  /// file truncated or replaced after install reads as not installed instead
  /// of reaching the native loader, which aborts or hangs the process on a
  /// broken model rather than throwing. A directory without the manifest, from
  /// an interrupted or manual install, is not installed either, nor is one
  /// whose manifest cannot be read or decoded. Same-size corruption is not
  /// detected; the archive's SHA-256 is checked only during the install.
  SherpaRecognitionModelPaths? resolveRecognition(
    SherpaRecognitionModel model,
  ) {
    final paths = _resolveVerified(
      recognitionDirectory(model),
      installManifestFileName,
      _recognitionFiles(model),
    );
    if (paths == null) {
      return null;
    }
    return SherpaRecognitionModelPaths(
      model: model,
      encoder: paths[0],
      decoder: paths[1],
      tokens: paths[2],
      joiner: model.joinerFile == null ? null : paths[3],
    );
  }

  /// Resolves the Silero VAD model path when installed, else null.
  String? resolveVad() {
    final file = File(p.join(supportDirectory.path, vadModel.fileName));
    return file.existsSync() ? file.path : null;
  }

  /// Resolves the diarization pair when one install completed both files and
  /// each still has the size it recorded, else null.
  ///
  /// Both files are staged and verified before either moves into place, and
  /// the manifest moves last, so a pair one of whose downloads failed never
  /// resolves, even beside an older file of the same name.
  SherpaDiarizationModelPaths? resolveDiarization() {
    final paths = _resolveVerified(
      supportDirectory,
      diarizationManifestFileName,
      _diarizationFiles,
    );
    if (paths == null) {
      return null;
    }
    return SherpaDiarizationModelPaths(
      segmentation: paths[0],
      embedding: paths[1],
      embeddingModelId: embeddingModel.id,
    );
  }

  /// Installs [model], returning immediately when it is already present.
  ///
  /// Only the archive's [SherpaRecognitionModel.unpackedDirName] directory
  /// moves into [root]; anything else the archive holds is discarded.
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
    await _installStaged(
      name: model.displayName,
      destination: root,
      promote: <String>[model.unpackedDirName],
      manifestDirectory: model.unpackedDirName,
      manifestFileName: installManifestFileName,
      files: _recognitionFiles(model),
      onProgress: onProgress,
      cancellationToken: cancellationToken,
      stage: (staging, unpacked) => _fetchArchive(
        name: model.displayName,
        url: model.archiveUrl,
        expectedBytes: model.archiveBytes,
        expectedSha256: model.archiveSha256,
        staging: staging,
        unpacked: unpacked,
        onProgress: onProgress,
        cancellationToken: cancellationToken,
      ),
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
    final staging = await _openStaging();
    try {
      final staged = File(p.join(staging.directory.path, vadModel.fileName));
      await _download(
        name: vadModel.displayName,
        url: vadModel.url,
        expectedBytes: vadModel.sizeBytes,
        expectedSha256: vadModel.sha256,
        target: staged,
        onProgress: onProgress,
        cancellationToken: cancellationToken,
      );
      await _promote(
        staged.path,
        p.join(supportDirectory.path, vadModel.fileName),
      );
      onProgress?.call(1);
    } finally {
      await staging.discard();
    }
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
  ///
  /// Both downloads land in one staging directory and move into place only
  /// after both are verified, so a failure in either installs nothing.
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
    final segmentationDir = p.dirname(segmentation.modelFile);
    await _installStaged(
      name: 'diarization',
      destination: supportDirectory,
      promote: <String>[
        if (segmentationDir == '.') segmentation.modelFile else segmentationDir,
        embeddingModel.fileName,
      ],
      manifestDirectory: '',
      manifestFileName: diarizationManifestFileName,
      files: _diarizationFiles,
      onProgress: onProgress,
      cancellationToken: cancellationToken,
      stage: (staging, unpacked) async {
        await _fetchArchive(
          name: segmentation.displayName,
          url: segmentation.archiveUrl,
          expectedBytes: segmentation.archiveBytes,
          expectedSha256: segmentation.archiveSha256,
          staging: staging,
          unpacked: unpacked,
          onProgress: onProgress == null
              ? null
              : (progress) => onProgress(progress * 0.5),
          cancellationToken: cancellationToken,
        );
        await _download(
          name: embeddingModel.displayName,
          url: embeddingModel.url,
          expectedBytes: embeddingModel.sizeBytes,
          expectedSha256: embeddingModel.sha256,
          target: File(p.join(unpacked.path, embeddingModel.fileName)),
          onProgress: onProgress == null
              ? null
              : (progress) => onProgress(0.5 + progress * 0.5),
          cancellationToken: cancellationToken,
        );
      },
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

  /// The files a recognition install records, relative to the model's
  /// directory, in the order [resolveRecognition] reads them.
  static List<String> _recognitionFiles(SherpaRecognitionModel model) =>
      <String>[
        model.encoderFile,
        model.decoderFile,
        model.tokensFile,
        ?model.joinerFile,
      ];

  /// The files a diarization install records, relative to
  /// [supportDirectory].
  List<String> get _diarizationFiles => <String>[
    segmentationModel.modelFile,
    embeddingModel.fileName,
  ];

  /// The paths of [files] under [directory] when its [manifestFileName]
  /// records each at its current size, else null.
  ///
  /// Each file is keyed by the same relative path the install recorded. A
  /// file system or decoding error reads as not installed, so a damaged
  /// manifest never stops a later install from replacing it.
  static List<String>? _resolveVerified(
    Directory directory,
    String manifestFileName,
    List<String> files,
  ) {
    try {
      final sizes = _readManifest(
        File(p.join(directory.path, manifestFileName)),
      );
      if (sizes == null) {
        return null;
      }
      final paths = <String>[];
      for (final name in files) {
        final file = File(p.join(directory.path, name));
        final recorded = sizes[name];
        if (recorded == null ||
            !file.existsSync() ||
            file.lengthSync() != recorded) {
          return null;
        }
        paths.add(file.path);
      }
      return paths;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Runs [stage] in a fresh staging directory, then checks that it left
  /// every one of [files] under [manifestDirectory] of `unpacked`, records
  /// their sizes there, and moves only the [promote] entries into
  /// [destination], each replacing what was there.
  ///
  /// [manifestDirectory] and [promote] are relative to `unpacked` and to
  /// [destination]; an empty [manifestDirectory] puts the manifest in
  /// [destination] itself, which is removed before the files move and
  /// written after them, so nothing resolves until every file is in place.
  Future<void> _installStaged({
    required String name,
    required Directory destination,
    required List<String> promote,
    required String manifestDirectory,
    required String manifestFileName,
    required List<String> files,
    required Future<void> Function(Directory staging, Directory unpacked) stage,
    SherpaInstallProgress? onProgress,
    AudioCancellationToken? cancellationToken,
  }) async {
    final staging = await _openStaging();
    try {
      final unpacked = Directory(p.join(staging.directory.path, 'unpacked'));
      await unpacked.create(recursive: true);
      await stage(staging.directory, unpacked);
      cancellationToken?.throwIfCancelled();
      final manifestDir = p.join(unpacked.path, manifestDirectory);
      for (final file in files) {
        if (!File(p.join(manifestDir, file)).existsSync()) {
          throw sherpaSpeechFailure(
            'sherpa_model_install_incomplete',
            'install',
            'The $name archive did not contain the expected files.',
          );
        }
      }
      final stagedManifest = p.join(manifestDir, manifestFileName);
      _writeManifest(File(stagedManifest), manifestDir, files);
      await destination.create(recursive: true);
      final manifestAtRoot = manifestDirectory.isEmpty;
      final installedManifest = File(
        p.join(destination.path, manifestFileName),
      );
      if (manifestAtRoot && installedManifest.existsSync()) {
        await installedManifest.delete();
      }
      for (final entry in promote) {
        await _promote(
          p.join(unpacked.path, entry),
          p.join(destination.path, entry),
        );
      }
      if (manifestAtRoot) {
        await _promote(stagedManifest, installedManifest.path);
      }
      onProgress?.call(1);
    } finally {
      await staging.discard();
    }
  }

  /// Downloads the archive at [url] into [staging] and unpacks it into
  /// [unpacked]; extraction is the last 20% of the reported progress.
  Future<void> _fetchArchive({
    required String name,
    required String url,
    required int expectedBytes,
    required String? expectedSha256,
    required Directory staging,
    required Directory unpacked,
    SherpaInstallProgress? onProgress,
    AudioCancellationToken? cancellationToken,
  }) async {
    final archive = File(p.join(staging.path, p.basename(url)));
    await _download(
      name: name,
      url: url,
      expectedBytes: expectedBytes,
      expectedSha256: expectedSha256,
      target: archive,
      onProgress: onProgress == null
          ? null
          : (progress) => onProgress(progress * 0.8),
      cancellationToken: cancellationToken,
    );
    await _extract(
      name: name,
      archive: archive,
      unpacked: unpacked,
      onProgress: onProgress == null
          ? null
          : (progress) => onProgress(0.8 + progress * 0.2),
      cancellationToken: cancellationToken,
    );
  }

  /// Records the size of each of [files] in [directory] in [manifest]. It is
  /// written in staging, so it moves into place with the files it describes.
  static void _writeManifest(
    File manifest,
    String directory,
    List<String> files,
  ) {
    manifest.writeAsStringSync(
      jsonEncode(<String, Object>{
        'version': 1,
        'files': <String, int>{
          for (final file in files)
            file: File(p.join(directory, file)).lengthSync(),
        },
      }),
    );
  }

  /// The recorded file sizes, or null when [manifest] is missing or has
  /// another shape; reading or decoding it may throw.
  static Map<String, int>? _readManifest(File manifest) {
    if (!manifest.existsSync()) {
      return null;
    }
    final json = jsonDecode(manifest.readAsStringSync());
    if (json case {'version': 1, 'files': final Map<String, Object?> files}) {
      return <String, int>{
        for (final MapEntry(:key, :value) in files.entries)
          if (value is int) key: value,
      };
    }
    return null;
  }

  /// Moves verified [staged] content to [target], replacing it.
  static Future<void> _promote(String staged, String target) async {
    final isDirectory = FileSystemEntity.isDirectorySync(staged);
    final FileSystemEntity existing = FileSystemEntity.isDirectorySync(target)
        ? Directory(target)
        : File(target);
    if (existing.existsSync()) {
      await existing.delete(recursive: true);
    }
    await Directory(p.dirname(target)).create(recursive: true);
    await (isDirectory ? Directory(staged) : File(staged)).rename(target);
  }

  /// Staging directories held by installs running in this isolate. Locks
  /// are held per process, so they alone cannot tell another registry in
  /// this process that a directory is in use.
  static final Set<String> _activeStaging = <String>{};

  static int _stagingCounter = 0;

  /// A fresh directory under [root] that one install downloads and extracts
  /// into; nothing in it is visible to the resolvers.
  ///
  /// The install holds an exclusive lock on a sibling `.lock` file while the
  /// directory exists. Before creating its own, it removes every staging
  /// directory whose lock nobody holds: the leftovers of an install whose
  /// process exited before it could clean up.
  Future<_Staging> _openStaging() async {
    final parent = Directory(p.join(root.path, '.staging'));
    await parent.create(recursive: true);
    await _sweepAbandonedStaging(parent);
    final name =
        'install-$pid-${DateTime.now().microsecondsSinceEpoch}-'
        '${_stagingCounter++}';
    final directory = Directory(p.join(parent.path, name));
    final key = p.canonicalize(directory.path);
    _activeStaging.add(key);
    final lockFile = File('${directory.path}.lock');
    RandomAccessFile? lock;
    try {
      // The lock exists before the directory, so no sweep ever sees the
      // directory unlocked.
      lock = await lockFile.open(mode: FileMode.write);
      await lock.lock(FileLock.exclusive);
      await directory.create();
      return _Staging(directory, lockFile, lock, key);
    } on Object {
      await lock?.close();
      _activeStaging.remove(key);
      rethrow;
    }
  }

  static Future<void> _sweepAbandonedStaging(Directory parent) async {
    final List<FileSystemEntity> entries;
    try {
      entries = parent.listSync();
    } on FileSystemException {
      return;
    }
    for (final entry in entries) {
      final isLock = entry is File && entry.path.endsWith('.lock');
      final directoryPath = isLock
          ? entry.path.substring(0, entry.path.length - '.lock'.length)
          : entry.path;
      if (!isLock && entry is! Directory) continue;
      if (isLock && FileSystemEntity.isDirectorySync(directoryPath)) {
        continue; // Swept with its directory.
      }
      if (_activeStaging.contains(p.canonicalize(directoryPath))) continue;
      final lockFile = File('$directoryPath.lock');
      RandomAccessFile? lock;
      try {
        lock = await lockFile.open(mode: FileMode.append);
        await lock.lock(FileLock.exclusive);
      } on FileSystemException {
        // Another process's install holds it.
        await lock?.close();
        continue;
      }
      try {
        final directory = Directory(directoryPath);
        if (directory.existsSync()) {
          await directory.delete(recursive: true);
        }
      } on FileSystemException {
        // Left for a later sweep.
      } finally {
        await lock.close();
        _deleteQuietly(lockFile);
      }
    }
  }

  static void _deleteQuietly(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // Another sweep removed it, or it is open elsewhere.
    }
  }

  /// Streams [url] into [target], checking its exact size and, when known,
  /// its SHA-256 as the bytes arrive.
  ///
  /// One deadline covers the wait for the response and the gaps between
  /// chunks. When it passes, or [cancellationToken] fires, the transfer
  /// settles at once as stalled or cancelled: the body subscription is
  /// cancelled and the client closed, but the wait never depends on the
  /// transport honouring either. The body is written through an awaited
  /// `addStream`, so a slow disk pauses the download instead of buffering it.
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
    // Settles the transfer: completed once every byte is on disk, failed by
    // the first error, the deadline or cancellation.
    final outcome = Completer<void>();
    StreamSubscription<List<int>>? body;
    StreamController<List<int>>? checked;
    Timer? deadline;

    void fail(Object error, [StackTrace? stackTrace]) {
      if (outcome.isCompleted) return;
      deadline?.cancel();
      outcome.completeError(error, stackTrace);
      body?.cancel().ignore();
      if (checked != null && !checked.isClosed) checked.close().ignore();
      client.close();
    }

    void arm() {
      deadline?.cancel();
      deadline = Timer(stallTimeout, () => fail(_stalled(name)));
    }

    final registration = cancellationToken?.register(
      (cancellation) => fail(AudioCancelledException(cancellation)),
    );
    IOSink? sink;
    Future<void>? writing;
    try {
      arm();
      final http.StreamedResponse response;
      try {
        response = await Future.any(<Future<http.StreamedResponse>>[
          client.send(http.Request('GET', Uri.parse(url))),
          outcome.future.then<http.StreamedResponse>(
            (_) => throw StateError('settled before the response'),
          ),
        ]);
      } on Object {
        // Closing the client fails the request too; report why it closed.
        if (outcome.isCompleted) await outcome.future;
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
      var received = 0;
      final controller = checked = StreamController<List<int>>(
        sync: true,
        // A disk that is still writing is not a stalled network.
        onPause: () {
          deadline?.cancel();
          body?.pause();
        },
        onResume: () {
          if (outcome.isCompleted) return;
          arm();
          body?.resume();
        },
      );
      final output = sink = target.openWrite();
      writing = output.addStream(controller.stream).then((_) {
        if (!outcome.isCompleted) outcome.complete();
      }, onError: fail);
      arm();
      body = response.stream.listen(
        (chunk) {
          if (outcome.isCompleted) return;
          arm();
          received += chunk.length;
          if (received > expectedBytes) {
            fail(_sizeMismatch(name, expectedBytes, received));
            return;
          }
          hasher.add(chunk);
          controller.add(chunk);
          onProgress?.call((received / expectedBytes).clamp(0, 1));
        },
        onError: fail,
        onDone: () {
          if (!controller.isClosed) controller.close().ignore();
        },
        cancelOnError: true,
      );
      await outcome.future;
      deadline?.cancel();
      await output.close();
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
      deadline?.cancel();
      registration?.dispose();
      if (checked != null && !checked.isClosed) checked.close().ignore();
      try {
        await writing;
        await sink?.close();
      } on Object {
        // The transfer already failed; the staged file is discarded.
      }
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
  /// bzip2 decoder runs in a worker isolate that is given only the two paths
  /// and that cancelling kills, reporting only its end.
  Future<void> _extract({
    required String name,
    required File archive,
    required Directory unpacked,
    SherpaInstallProgress? onProgress,
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    await unpacked.create(recursive: true);
    final tar = _systemTar;
    if (tar == null) {
      await _extractInWorker(
        name: name,
        archivePath: archive.path,
        unpackedPath: unpacked.path,
        cancellationToken: cancellationToken,
      );
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

  /// Runs the bundled decoder in a spawned isolate. Only the two paths and a
  /// port cross to it, so no caller state has to be sendable, and cancelling
  /// kills it; the wait ends once the worker has exited, so nothing writes
  /// into staging after it is discarded.
  static Future<void> _extractInWorker({
    required String name,
    required String archivePath,
    required String unpackedPath,
    AudioCancellationToken? cancellationToken,
  }) async {
    final result = Completer<void>();
    final port = RawReceivePort();
    port.handler = (Object? message) {
      if (result.isCompleted) return;
      if (message == _workerDone) {
        result.complete();
      } else {
        final reason = message is List && message.isNotEmpty
            ? '${message.first}'
            : 'the decoder stopped';
        result.completeError(
          sherpaSpeechFailure(
            'sherpa_model_extract_failed',
            'install',
            'The $name archive could not be unpacked: $reason',
          ),
        );
      }
    };
    AudioCancellationRegistration? registration;
    try {
      final worker = await Isolate.spawn<(String, String, SendPort)>(
        _extractInWorkerMain,
        (archivePath, unpackedPath, port.sendPort),
        onError: port.sendPort,
        onExit: port.sendPort,
        errorsAreFatal: true,
      );
      registration = cancellationToken?.register(
        (_) => worker.kill(priority: Isolate.immediate),
      );
      await result.future;
    } on Object {
      cancellationToken?.throwIfCancelled();
      rethrow;
    } finally {
      registration?.dispose();
      port.close();
    }
  }

  static const String _workerDone = 'done';

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

/// One install's staging directory and the lock that marks it in use.
final class _Staging {
  _Staging(this.directory, this._lockFile, this._lock, this._key);

  final Directory directory;
  final File _lockFile;
  final RandomAccessFile _lock;
  final String _key;

  /// Deletes the directory, then releases and removes its lock.
  Future<void> discard() async {
    try {
      if (directory.existsSync()) {
        await directory.delete(recursive: true);
      }
    } finally {
      await _lock.close();
      SherpaModelRegistry._deleteQuietly(_lockFile);
      SherpaModelRegistry._activeStaging.remove(_key);
    }
  }
}

/// The bundled decoder's worker: extracts, then reports success.
void _extractInWorkerMain((String, String, SendPort) message) {
  final (archivePath, destinationPath, reply) = message;
  _extractTarBz2(archivePath, destinationPath);
  reply.send(SherpaModelRegistry._workerDone);
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
