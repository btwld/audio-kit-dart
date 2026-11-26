import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:audio_core/audio_core.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:speech_core/speech_core.dart';
import 'package:speech_sherpa/speech_sherpa.dart';

import 'support/fakes.dart';

/// Skips a test that needs the system's `tar` where the registry has none.
final Object noSystemTar = Platform.isMacOS || Platform.isLinux
    ? false
    : 'no system tar';

/// Builds a real `.tar.bz2` holding [files].
Uint8List buildArchiveOf(Map<String, List<int>> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.add(ArchiveFile.bytes(entry.key, entry.value));
  }
  final tar = TarEncoder().encodeBytes(archive);
  return Uint8List.fromList(BZip2Encoder().encode(tar));
}

/// [length] bytes bzip2 cannot shrink, so an archive of them spans many
/// read chunks.
Uint8List noise(int length, {int seed = 1}) {
  final random = Random(seed);
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

/// Fails a test that would otherwise wait forever on a hung transfer.
const Timeout hangs = Timeout(Duration(seconds: 10));

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('speech_sherpa_registry');
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  /// Builds a real `.tar.bz2` so the extraction path is exercised end to end.
  Uint8List buildArchive(Map<String, String> files) => buildArchiveOf({
    for (final entry in files.entries) entry.key: utf8.encode(entry.value),
  });

  group('resolve', () {
    test('returns null until every required file exists', () {
      final registry = SherpaModelRegistry(root: root);
      const model = SherpaRecognitionModel.parakeetTdtV3;
      final dir = registry.recognitionDirectory(model)
        ..createSync(recursive: true);

      File('${dir.path}/${model.encoderFile}').writeAsStringSync('e');
      File('${dir.path}/${model.decoderFile}').writeAsStringSync('d');
      File('${dir.path}/${model.tokensFile}').writeAsStringSync('t');
      File('${dir.path}/${model.joinerFile}').writeAsStringSync('j');
      // Every file is there, but no verified install recorded them.
      expect(registry.resolveRecognition(model), isNull);

      writeInstallManifest(dir, <String>[
        model.encoderFile,
        model.decoderFile,
        model.tokensFile,
        model.joinerFile!,
      ]);
      final resolved = registry.resolveRecognition(model);
      expect(resolved, isNotNull);
      expect(resolved!.joiner, isNotNull);
      expect(resolved.model.id, model.id);
    });

    test('a Whisper model needs no joiner', () {
      final registry = SherpaModelRegistry(root: root);
      const model = SherpaRecognitionModel.whisperBaseEn;
      final dir = registry.recognitionDirectory(model)
        ..createSync(recursive: true);
      File('${dir.path}/${model.encoderFile}').writeAsStringSync('e');
      File('${dir.path}/${model.decoderFile}').writeAsStringSync('d');
      File('${dir.path}/${model.tokensFile}').writeAsStringSync('t');
      writeInstallManifest(dir, <String>[
        model.encoderFile,
        model.decoderFile,
        model.tokensFile,
      ]);

      final resolved = registry.resolveRecognition(model);
      expect(resolved, isNotNull);
      expect(resolved!.joiner, isNull);
    });

    test('diarization needs both halves of the pair', () {
      final registry = SherpaModelRegistry(root: root);
      final support = registry.supportDirectory..createSync(recursive: true);
      File(
        '${support.path}/${SherpaFileModel.wespeakerResnet34.fileName}',
      ).writeAsStringSync('embedding');

      expect(registry.resolveDiarization(), isNull);

      final segmentation = File(
        '${support.path}/'
        '${SherpaArchivedFileModel.pyannoteSegmentation.modelFile}',
      );
      segmentation.parent.createSync(recursive: true);
      segmentation.writeAsStringSync('segmentation');
      // Both files are there, but no install recorded them as a pair.
      expect(registry.resolveDiarization(), isNull);

      writeInstallManifest(support, <String>[
        SherpaArchivedFileModel.pyannoteSegmentation.modelFile,
        SherpaFileModel.wespeakerResnet34.fileName,
      ], name: SherpaModelRegistry.diarizationManifestFileName);
      final resolved = registry.resolveDiarization();
      expect(resolved, isNotNull);
      // The embedding model ID travels with the vectors it produces.
      expect(resolved!.embeddingModelId, SherpaFileModel.wespeakerResnet34.id);
    });
  });

  group('install', () {
    /// A transducer entry whose size and digest describe [archive], so the
    /// install checks pass; [sha256] and [bytes] override them to break it.
    SherpaRecognitionModel modelFor(
      Uint8List archive, {
      String? sha256,
      int? bytes,
      String url = 'https://example.test/test-transducer.tar.bz2',
    }) => SherpaRecognitionModel(
      id: 'test-transducer',
      displayName: 'Test transducer',
      kind: SherpaRecognitionModelKind.transducer,
      archiveUrl: url,
      archiveBytes: bytes ?? archive.length,
      archiveSha256: sha256 ?? crypto.sha256.convert(archive).toString(),
      unpackedDirName: 'test-transducer',
      encoderFile: 'encoder.onnx',
      decoderFile: 'decoder.onnx',
      joinerFile: 'joiner.onnx',
      tokensFile: 'tokens.txt',
    );

    Uint8List completeArchive() => buildArchive(<String, String>{
      'test-transducer/encoder.onnx': 'encoder',
      'test-transducer/decoder.onnx': 'decoder',
      'test-transducer/joiner.onnx': 'joiner',
      'test-transducer/tokens.txt': 'tokens',
    });

    /// Nothing a failed install leaves may resolve or linger.
    void expectNothingInstalled(
      SherpaModelRegistry registry,
      SherpaRecognitionModel model,
    ) {
      expect(registry.resolveRecognition(model), isNull);
      expect(registry.recognitionDirectory(model).existsSync(), isFalse);
      final staging = Directory('${root.path}/.staging');
      expect(
        staging.existsSync() ? staging.listSync() : const <FileSystemEntity>[],
        isEmpty,
        reason: 'no staged download survives',
      );
    }

    test('downloads, verifies and extracts a recognition archive', () async {
      final archive = completeArchive();
      final model = modelFor(archive);
      final client = _FakeClient({model.archiveUrl: archive});
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => client,
      );

      final progress = <double>[];
      final paths = await registry.installRecognition(
        model,
        onProgress: progress.add,
      );

      expect(File(paths.encoder).readAsStringSync(), 'encoder');
      expect(File(paths.joiner!).existsSync(), isTrue);
      expect(progress.last, 1);
      expect(client.requested, <String>[model.archiveUrl]);
      expect(
        Directory('${root.path}/.staging').listSync(),
        isEmpty,
        reason: 'staging is cleaned after a successful install',
      );
    });

    test(
      'is idempotent and skips the network when already installed',
      () async {
        final archive = completeArchive();
        final model = modelFor(archive);
        final client = _FakeClient({model.archiveUrl: archive});
        final registry = SherpaModelRegistry(
          root: root,
          httpClientFactory: () => client,
        );

        await registry.installRecognition(model);
        await registry.installRecognition(model);

        expect(client.requested, hasLength(1));
      },
    );

    test('a corrupt download installs nothing', () async {
      final archive = completeArchive();
      final model = modelFor(archive, sha256: '0' * 64);
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => _FakeClient({model.archiveUrl: archive}),
      );

      await expectLater(
        registry.installRecognition(model),
        throwsA(
          isA<SpeechFailure>()
              .having((f) => f.code, 'code', 'sherpa_model_download_corrupt')
              .having((f) => f.retryable, 'retryable', isTrue),
        ),
      );
      expectNothingInstalled(registry, model);
    });

    test('a download of another size installs nothing', () async {
      final archive = completeArchive();
      for (final bytes in <int>[archive.length + 1, archive.length - 1]) {
        final model = modelFor(archive, bytes: bytes);
        final registry = SherpaModelRegistry(
          root: root,
          httpClientFactory: () => _FakeClient({model.archiveUrl: archive}),
        );
        await expectLater(
          registry.installRecognition(model),
          throwsA(
            isA<SpeechFailure>().having(
              (f) => f.code,
              'code',
              'sherpa_model_download_incomplete',
            ),
          ),
          reason: 'expected $bytes bytes, got ${archive.length}',
        );
        expectNothingInstalled(registry, model);
      }
    });

    test('a short body without a length header installs nothing', () async {
      final archive = completeArchive();
      final model = modelFor(archive);
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => _FakeClient({
          model.archiveUrl: Uint8List.sublistView(archive, 0, 10),
        }, sendLength: false),
      );

      await expectLater(
        registry.installRecognition(model),
        throwsA(
          isA<SpeechFailure>().having(
            (f) => f.code,
            'code',
            'sherpa_model_download_incomplete',
          ),
        ),
      );
      expectNothingInstalled(registry, model);
    });

    test('an interrupted download installs nothing', () async {
      final archive = completeArchive();
      final model = modelFor(archive);
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () =>
            _FakeClient({model.archiveUrl: archive}, failAfterFirstChunk: true),
      );

      await expectLater(
        registry.installRecognition(model),
        throwsA(isA<http.ClientException>()),
      );
      expectNothingInstalled(registry, model);
    });

    test('cancelling a download installs nothing', () async {
      final archive = completeArchive();
      final model = modelFor(archive);
      final controller = AudioCancellationController();
      final client = _FakeClient({
        model.archiveUrl: archive,
      }, holdAfterFirstChunk: true);
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => client,
      );

      final install = registry.installRecognition(
        model,
        cancellationToken: controller.token,
        onProgress: (progress) {
          if (progress > 0) controller.cancel();
        },
      );

      await expectLater(install, throwsA(isA<AudioCancelledException>()));
      expect(client.closed, isTrue, reason: 'the transfer is aborted');
      expectNothingInstalled(registry, model);
    });

    test('cancelling ends a body that outlives closing the client', () async {
      final archive = completeArchive();
      final model = modelFor(archive);
      final controller = AudioCancellationController();
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => _FakeClient(
          {model.archiveUrl: archive},
          holdAfterFirstChunk: true,
          ignoreClose: true,
        ),
      );

      final install = registry.installRecognition(
        model,
        cancellationToken: controller.token,
        onProgress: (progress) {
          if (progress > 0) controller.cancel();
        },
      );

      await expectLater(install, throwsA(isA<AudioCancelledException>()));
      expectNothingInstalled(registry, model);
    }, timeout: hangs);

    test('a slow disk holds the download back', () async {
      final body = noise(2 << 20);
      final vad = SherpaFileModel(
        id: 'test-vad',
        displayName: 'Test VAD',
        url: 'https://example.test/vad.onnx',
        fileName: 'vad.onnx',
        sizeBytes: body.length,
      );
      int onDisk() {
        final staging = Directory('${root.path}/.staging');
        for (final entry in staging.listSync(recursive: true)) {
          if (entry is File && entry.path.endsWith('vad.onnx')) {
            return entry.lengthSync();
          }
        }
        return 0;
      }

      final ahead = <int>[];
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => _PacedClient(
          body,
          chunkSize: 256 * 1024,
          beforeChunk: (sent) => ahead.add(sent - onDisk()),
        ),
        vadModel: vad,
      );

      await registry.installVad();

      expect(ahead, hasLength(8));
      expect(
        ahead,
        everyElement(0),
        reason: 'no chunk is read before the previous one is on disk',
      );
    });

    group('a verified install stops resolving when', () {
      late SherpaModelRegistry registry;
      late SherpaRecognitionModel model;
      late Directory dir;

      setUp(() async {
        final archive = completeArchive();
        model = modelFor(archive);
        registry = SherpaModelRegistry(
          root: root,
          httpClientFactory: () => _FakeClient({model.archiveUrl: archive}),
        );
        await registry.installRecognition(model);
        dir = registry.recognitionDirectory(model);
        expect(registry.resolveRecognition(model), isNotNull);
      });

      test('a file is truncated', () {
        // A truncated model reaches the native loader, which aborts or hangs
        // the process instead of throwing.
        File('${dir.path}/encoder.onnx').writeAsStringSync('enc');
        expect(registry.resolveRecognition(model), isNull);
      });

      test('a file is deleted', () {
        File('${dir.path}/joiner.onnx').deleteSync();
        expect(registry.resolveRecognition(model), isNull);
      });

      test('the manifest records other sizes', () {
        writeInstallManifest(dir, <String>['encoder.onnx', 'decoder.onnx']);
        File('${dir.path}/encoder.onnx').writeAsStringSync('encoder, longer');
        expect(registry.resolveRecognition(model), isNull);
      });

      test('the manifest is missing', () {
        File(
          '${dir.path}/${SherpaModelRegistry.installManifestFileName}',
        ).deleteSync();
        expect(registry.resolveRecognition(model), isNull);
      });

      test('the manifest is not valid JSON', () {
        File(
          '${dir.path}/${SherpaModelRegistry.installManifestFileName}',
        ).writeAsStringSync('{');
        expect(registry.resolveRecognition(model), isNull);
      });

      test('the manifest is not valid UTF-8', () {
        File(
          '${dir.path}/${SherpaModelRegistry.installManifestFileName}',
        ).writeAsBytesSync(<int>[0x7b, 0xff, 0x7d]);
        expect(registry.resolveRecognition(model), isNull);
      });

      test('the manifest cannot be read', () {
        final manifest = File(
          '${dir.path}/${SherpaModelRegistry.installManifestFileName}',
        )..deleteSync();
        Directory(manifest.path).createSync();
        expect(registry.resolveRecognition(model), isNull);
      });
    });

    test('a retry replaces a manifest that cannot be decoded', () async {
      final archive = completeArchive();
      final model = modelFor(archive);
      final client = _FakeClient({model.archiveUrl: archive});
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => client,
      );
      await registry.installRecognition(model);
      File(
        '${registry.recognitionDirectory(model).path}/'
        '${SherpaModelRegistry.installManifestFileName}',
      ).writeAsBytesSync(<int>[0xff]);

      final paths = await registry.installRecognition(model);

      expect(File(paths.encoder).readAsStringSync(), 'encoder');
      expect(registry.resolveRecognition(model), isNotNull);
      expect(client.requested, hasLength(2));
    });

    test('only the model directory moves into place', () async {
      final archive = buildArchive(<String, String>{
        'test-transducer/encoder.onnx': 'encoder',
        'test-transducer/decoder.onnx': 'decoder',
        'test-transducer/joiner.onnx': 'joiner',
        'test-transducer/tokens.txt': 'tokens',
        'docs/LICENSE': 'license',
        'README.md': 'readme',
      });
      final model = modelFor(archive);
      final notes = File('${root.path}/docs/local-notes')
        ..createSync(recursive: true)
        ..writeAsStringSync('kept');
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => _FakeClient({model.archiveUrl: archive}),
      );

      await registry.installRecognition(model);

      expect(registry.resolveRecognition(model), isNotNull);
      expect(notes.readAsStringSync(), 'kept');
      expect(File('${root.path}/docs/LICENSE').existsSync(), isFalse);
      expect(File('${root.path}/README.md').existsSync(), isFalse);
    });

    test('a model whose files sit in a subdirectory resolves', () async {
      final archive = buildArchive(<String, String>{
        'test-nested/sub/encoder.onnx': 'encoder',
        'test-nested/sub/decoder.onnx': 'decoder',
        'test-nested/tokens.txt': 'tokens',
      });
      final model = SherpaRecognitionModel(
        id: 'test-nested',
        displayName: 'Test nested',
        kind: SherpaRecognitionModelKind.whisper,
        archiveUrl: 'https://example.test/test-nested.tar.bz2',
        archiveBytes: archive.length,
        archiveSha256: crypto.sha256.convert(archive).toString(),
        unpackedDirName: 'test-nested',
        encoderFile: 'sub/encoder.onnx',
        decoderFile: 'sub/decoder.onnx',
        tokensFile: 'tokens.txt',
      );
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => _FakeClient({model.archiveUrl: archive}),
      );

      final paths = await registry.installRecognition(model);

      expect(File(paths.encoder).readAsStringSync(), 'encoder');
      expect(registry.resolveRecognition(model), isNotNull);
    });

    group('staging', () {
      test('a later install removes what an exited install left', () async {
        final abandoned = Directory('${root.path}/.staging/install-abandoned')
          ..createSync(recursive: true);
        File('${abandoned.path}/archive.tar.bz2').writeAsStringSync('part');
        File('${root.path}/.staging/install-gone.lock').writeAsStringSync('');
        final archive = completeArchive();
        final model = modelFor(archive);
        final registry = SherpaModelRegistry(
          root: root,
          httpClientFactory: () => _FakeClient({model.archiveUrl: archive}),
        );

        await registry.installRecognition(model);

        expect(Directory('${root.path}/.staging').listSync(), isEmpty);
      });

      test('an install keeps the staging of one still running', () async {
        final archive = completeArchive();
        final model = modelFor(archive);
        final controller = AudioCancellationController();
        final started = Completer<void>();
        final running = SherpaModelRegistry(
          root: root,
          httpClientFactory: () => _FakeClient({
            model.archiveUrl: archive,
          }, holdAfterFirstChunk: true),
          stallTimeout: const Duration(minutes: 1),
        );
        final held = running.installRecognition(
          model,
          cancellationToken: controller.token,
          onProgress: (progress) {
            if (progress > 0 && !started.isCompleted) started.complete();
          },
        );
        await started.future;
        List<FileSystemEntity> stagedDirectories() => Directory(
          '${root.path}/.staging',
        ).listSync().whereType<Directory>().toList();
        final before = stagedDirectories();
        expect(before, hasLength(1));

        final body = Uint8List.fromList(<int>[1, 2, 3, 4]);
        final vad = SherpaFileModel(
          id: 'test-vad',
          displayName: 'Test VAD',
          url: 'https://example.test/vad.onnx',
          fileName: 'vad.onnx',
          sizeBytes: body.length,
        );
        await SherpaModelRegistry(
          root: root,
          httpClientFactory: () => _FakeClient({vad.url: body}),
          vadModel: vad,
        ).installVad();

        expect(
          stagedDirectories().map((entry) => entry.path),
          before.map((entry) => entry.path),
          reason: 'the running install keeps its staging',
        );
        controller.cancel();
        await expectLater(held, throwsA(isA<AudioCancelledException>()));
        expect(Directory('${root.path}/.staging').listSync(), isEmpty);
      });
    });

    test('a later install replaces a half-written earlier one', () async {
      final archive = completeArchive();
      final model = modelFor(archive);
      final stale = SherpaModelRegistry(root: root).recognitionDirectory(model)
        ..createSync(recursive: true);
      File('${stale.path}/stale.onnx').writeAsStringSync('left over');
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => _FakeClient({model.archiveUrl: archive}),
      );

      await registry.installRecognition(model);

      expect(File('${stale.path}/stale.onnx').existsSync(), isFalse);
      expect(registry.resolveRecognition(model), isNotNull);
    });

    test(
      'the catalog size rejects a download that is not Silero VAD',
      () async {
        final body = Uint8List.fromList(<int>[1, 2, 3, 4]);
        final registry = SherpaModelRegistry(
          root: root,
          httpClientFactory: () =>
              _FakeClient({SherpaFileModel.sileroVad.url: body}),
        );

        // The fake body is not the real Silero VAD, so the catalog's size
        // rejects it.
        await expectLater(
          registry.installVad(),
          throwsA(
            isA<SpeechFailure>().having(
              (f) => f.code,
              'code',
              'sherpa_model_download_incomplete',
            ),
          ),
        );
        expect(registry.resolveVad(), isNull);
      },
    );

    test('downloads, verifies and installs the bare VAD file', () async {
      final body = Uint8List.fromList(<int>[1, 2, 3, 4]);
      final vad = SherpaFileModel(
        id: 'test-vad',
        displayName: 'Test VAD',
        url: 'https://example.test/vad.onnx',
        fileName: 'vad.onnx',
        sizeBytes: body.length,
        sha256: crypto.sha256.convert(body).toString(),
      );
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => _FakeClient({vad.url: body}),
        vadModel: vad,
      );

      final path = await registry.installVad();

      expect(File(path).readAsBytesSync(), <int>[1, 2, 3, 4]);
      expect(registry.resolveVad(), path);
      expect(Directory('${root.path}/.staging').listSync(), isEmpty);
    });

    test('installs the diarization pair from archive plus bare file', () async {
      final archive = buildArchive(<String, String>{
        'segmentation/model.onnx': 'segmentation-model',
      });
      final segmentation = SherpaArchivedFileModel(
        id: 'test-segmentation',
        displayName: 'Test segmentation',
        archiveUrl: 'https://example.test/segmentation.tar.bz2',
        archiveBytes: archive.length,
        archiveSha256: crypto.sha256.convert(archive).toString(),
        modelFile: 'segmentation/model.onnx',
      );
      final embeddingBody = Uint8List.fromList(<int>[9, 9]);
      final embedding = SherpaFileModel(
        id: 'test-embedding',
        displayName: 'Test embedding',
        url: 'https://example.test/embedding.onnx',
        fileName: 'embedding.onnx',
        sizeBytes: embeddingBody.length,
      );
      final client = _FakeClient({
        segmentation.archiveUrl: archive,
        embedding.url: embeddingBody,
      });
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => client,
        segmentationModel: segmentation,
        embeddingModel: embedding,
      );

      final paths = await registry.installDiarization();

      expect(File(paths.segmentation).readAsStringSync(), 'segmentation-model');
      expect(File(paths.embedding).readAsBytesSync(), <int>[9, 9]);
      expect(paths.embeddingModelId, 'test-embedding');
      expect(
        client.requested,
        containsAll(<String>[segmentation.archiveUrl, embedding.url]),
      );
    });

    group('diarization', () {
      late SherpaArchivedFileModel segmentation;
      late SherpaFileModel embedding;
      late Map<String, Uint8List> bodies;

      setUp(() {
        final archive = buildArchive(<String, String>{
          'segmentation/model.onnx': 'segmentation-model',
        });
        segmentation = SherpaArchivedFileModel(
          id: 'test-segmentation',
          displayName: 'Test segmentation',
          archiveUrl: 'https://example.test/segmentation.tar.bz2',
          archiveBytes: archive.length,
          archiveSha256: crypto.sha256.convert(archive).toString(),
          modelFile: 'segmentation/model.onnx',
        );
        final embeddingBody = Uint8List.fromList(<int>[9, 9]);
        embedding = SherpaFileModel(
          id: 'test-embedding',
          displayName: 'Test embedding',
          url: 'https://example.test/embedding.onnx',
          fileName: 'embedding.onnx',
          sizeBytes: embeddingBody.length,
        );
        bodies = {
          segmentation.archiveUrl: archive,
          embedding.url: embeddingBody,
        };
      });

      SherpaModelRegistry registryWith(_FakeClient client) =>
          SherpaModelRegistry(
            root: root,
            httpClientFactory: () => client,
            segmentationModel: segmentation,
            embeddingModel: embedding,
          );

      test('a failed embedding download leaves the pair unresolved', () async {
        final registry = registryWith(
          _FakeClient(bodies, statusCodes: {embedding.url: 503}),
        );
        // An older, broken embedding file of the same name.
        File('${registry.supportDirectory.path}/${embedding.fileName}')
          ..createSync(recursive: true)
          ..writeAsBytesSync(<int>[1]);

        await expectLater(
          registry.installDiarization(),
          throwsA(
            isA<SpeechFailure>().having(
              (f) => f.code,
              'code',
              'sherpa_model_download_failed',
            ),
          ),
        );

        expect(registry.resolveDiarization(), isNull);
        expect(
          File(
            '${registry.supportDirectory.path}/${segmentation.modelFile}',
          ).existsSync(),
          isFalse,
          reason: 'neither file moves into place alone',
        );
        expect(Directory('${root.path}/.staging').listSync(), isEmpty);
      });

      test('a file changed after install stops resolving', () async {
        final registry = registryWith(_FakeClient(bodies));
        final paths = await registry.installDiarization();
        expect(registry.resolveDiarization(), isNotNull);

        File(paths.embedding).writeAsBytesSync(<int>[1]);

        expect(registry.resolveDiarization(), isNull);
      });
    });

    test('reports a retryable failure for a server error', () async {
      final client = _FakeClient(const {}, statusCode: 503);
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => client,
      );

      await expectLater(
        registry.installVad(),
        throwsA(
          isA<SpeechFailure>()
              .having((f) => f.code, 'code', 'sherpa_model_download_failed')
              .having((f) => f.retryable, 'retryable', isTrue),
        ),
      );
      expect(registry.resolveVad(), isNull);
    });

    test('reports a non-retryable failure for a client error', () async {
      final client = _FakeClient(const {}, statusCode: 404);
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => client,
      );

      await expectLater(
        registry.installVad(),
        throwsA(
          isA<SpeechFailure>().having((f) => f.retryable, 'retryable', isFalse),
        ),
      );
    });

    test('fails when the archive lacks the expected files', () async {
      final archive = buildArchive(<String, String>{
        'test-transducer/README.md': 'nothing useful',
      });
      final model = modelFor(archive);
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => _FakeClient({model.archiveUrl: archive}),
      );

      await expectLater(
        registry.installRecognition(model),
        throwsA(
          isA<SpeechFailure>().having(
            (f) => f.code,
            'code',
            'sherpa_model_install_incomplete',
          ),
        ),
      );
      expectNothingInstalled(registry, model);
    });

    group('an archive entry that escapes the destination', () {
      Uint8List escaping() => buildArchive(<String, String>{
        '../escaped.onnx': 'nope',
        'test-transducer/encoder.onnx': 'e',
        'test-transducer/decoder.onnx': 'd',
        'test-transducer/joiner.onnx': 'j',
        'test-transducer/tokens.txt': 't',
      });

      void expectNotEscaped() {
        expect(File('${root.path}/escaped.onnx').existsSync(), isFalse);
        expect(File('${root.parent.path}/escaped.onnx').existsSync(), isFalse);
      }

      test('fails the install with the system tar', () async {
        final archive = escaping();
        final model = modelFor(archive);
        final registry = SherpaModelRegistry(
          root: root,
          httpClientFactory: () => _FakeClient({model.archiveUrl: archive}),
        );

        await expectLater(
          registry.installRecognition(model),
          throwsA(
            isA<SpeechFailure>().having(
              (failure) => failure.code,
              'code',
              'sherpa_model_extract_failed',
            ),
          ),
        );
        expectNotEscaped();
        expectNothingInstalled(registry, model);
      }, skip: noSystemTar);

      test('is skipped by the bundled decoder', () async {
        final archive = escaping();
        final model = modelFor(archive);
        final registry = SherpaModelRegistry(
          root: root,
          httpClientFactory: () => _FakeClient({model.archiveUrl: archive}),
          useSystemTar: false,
        );

        await registry.installRecognition(model);
        expectNotEscaped();
      });
    });

    test('the bundled decoder installs where there is no system tar', () async {
      final archive = completeArchive();
      final model = modelFor(archive);
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => _FakeClient({model.archiveUrl: archive}),
        useSystemTar: false,
      );

      final progress = <double>[];
      final paths = await registry.installRecognition(
        model,
        onProgress: progress.add,
      );

      expect(File(paths.encoder).readAsStringSync(), 'encoder');
      expect(progress.last, 1);
    });

    test('cancelling stops the bundled decoder while it unpacks', () async {
      final archive = buildArchiveOf(<String, List<int>>{
        'test-transducer/encoder.onnx': noise(6 << 20),
        'test-transducer/decoder.onnx': utf8.encode('decoder'),
        'test-transducer/joiner.onnx': utf8.encode('joiner'),
        'test-transducer/tokens.txt': utf8.encode('tokens'),
      });
      final model = modelFor(archive);
      final controller = AudioCancellationController();
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => _FakeClient({model.archiveUrl: archive}),
        useSystemTar: false,
      );

      final progress = <double>[];
      final install = registry.installRecognition(
        model,
        cancellationToken: controller.token,
        // The callback holds the controller, which cannot cross isolates.
        onProgress: (value) {
          progress.add(value);
          if (value == 0.8) {
            Timer(const Duration(milliseconds: 100), controller.cancel);
          }
        },
      );

      await expectLater(install, throwsA(isA<AudioCancelledException>()));
      expect(
        progress.where((value) => value > 0.8),
        isEmpty,
        reason: 'the decoder stops instead of running to the end',
      );
      expectNothingInstalled(registry, model);
    });

    test(
      'unpacking reports its progress after the download, up to 1',
      () async {
        // Several read chunks, so progress has values between the ends.
        final archive = buildArchiveOf(<String, List<int>>{
          'test-transducer/encoder.onnx': noise(300 * 1024),
          'test-transducer/decoder.onnx': utf8.encode('decoder'),
          'test-transducer/joiner.onnx': utf8.encode('joiner'),
          'test-transducer/tokens.txt': utf8.encode('tokens'),
        });
        final model = modelFor(archive);
        final registry = SherpaModelRegistry(
          root: root,
          httpClientFactory: () => _FakeClient({model.archiveUrl: archive}),
        );

        final progress = <double>[];
        await registry.installRecognition(model, onProgress: progress.add);

        final unpacking = progress.where((value) => value > 0.8).toList();
        expect(unpacking, isNotEmpty, reason: 'unpacking is not silent');
        expect(
          unpacking.where((value) => value < 1),
          isNotEmpty,
          reason: 'progress follows the archive as tar reads it',
        );
        expect(unpacking.last, 1);
        for (var i = 1; i < progress.length; i++) {
          expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
        }
      },
      skip: noSystemTar,
    );

    test('an archive tar cannot read installs nothing', () async {
      final archive = Uint8List.fromList(utf8.encode('not a bzip2 archive'));
      final model = modelFor(archive);
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => _FakeClient({model.archiveUrl: archive}),
      );

      await expectLater(
        registry.installRecognition(model),
        throwsA(
          isA<SpeechFailure>().having(
            (failure) => failure.code,
            'code',
            'sherpa_model_extract_failed',
          ),
        ),
      );
      expectNothingInstalled(registry, model);
    }, skip: noSystemTar);

    group('a download that stalls fails as retryable, installing nothing,', () {
      Matcher stalled() => throwsA(
        isA<SpeechFailure>()
            .having(
              (failure) => failure.code,
              'code',
              'sherpa_model_download_stalled',
            )
            .having((failure) => failure.retryable, 'retryable', isTrue),
      );

      test('before the response arrives', () async {
        final archive = completeArchive();
        final model = modelFor(archive);
        final client = _FakeClient({
          model.archiveUrl: archive,
        }, holdHeaders: true);
        final registry = SherpaModelRegistry(
          root: root,
          httpClientFactory: () => client,
          stallTimeout: const Duration(milliseconds: 50),
        );

        await expectLater(registry.installRecognition(model), stalled());
        expect(client.closed, isTrue);
        expectNothingInstalled(registry, model);
      });

      test('on a transport whose body outlives closing the client', () async {
        final archive = completeArchive();
        final model = modelFor(archive);
        final client = _FakeClient(
          {model.archiveUrl: archive},
          holdAfterFirstChunk: true,
          ignoreClose: true,
        );
        final registry = SherpaModelRegistry(
          root: root,
          httpClientFactory: () => client,
          stallTimeout: const Duration(milliseconds: 50),
        );

        await expectLater(registry.installRecognition(model), stalled());
        expectNothingInstalled(registry, model);
      }, timeout: hangs);

      test('on a real connection that goes quiet without a length', () async {
        final archive = completeArchive();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final release = Completer<void>();
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          await server.close(force: true);
        });
        server.listen((request) async {
          final response = request.response
            ..persistentConnection = false
            // No length and no chunking: the body ends when the socket does.
            ..headers.chunkedTransferEncoding = false
            ..add(Uint8List.sublistView(archive, 0, archive.length ~/ 2));
          await response.flush();
          await release.future;
          await response.close();
        });
        final model = modelFor(
          archive,
          url: 'http://127.0.0.1:${server.port}/test-transducer.tar.bz2',
        );
        final registry = SherpaModelRegistry(
          root: root,
          stallTimeout: const Duration(milliseconds: 200),
        );

        await expectLater(registry.installRecognition(model), stalled());
        expectNothingInstalled(registry, model);
      });

      test('in the middle of the body', () async {
        final archive = completeArchive();
        final model = modelFor(archive);
        final client = _FakeClient({
          model.archiveUrl: archive,
        }, holdAfterFirstChunk: true);
        final registry = SherpaModelRegistry(
          root: root,
          httpClientFactory: () => client,
          stallTimeout: const Duration(milliseconds: 50),
        );

        await expectLater(registry.installRecognition(model), stalled());
        expect(client.closed, isTrue);
        expectNothingInstalled(registry, model);
      });
    });

    test('uninstall removes an installed model directory', () async {
      final archive = completeArchive();
      final model = modelFor(archive);
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => _FakeClient({model.archiveUrl: archive}),
      );

      await registry.installRecognition(model);
      expect(registry.resolveRecognition(model), isNotNull);

      await registry.uninstallRecognition(model);
      expect(registry.resolveRecognition(model), isNull);
    });
  });

  group('catalog', () {
    test('preserves the upstream release-tag typo for WeSpeaker', () {
      // The k2-fsa tag really is "recongition"; fixing the spelling 404s.
      expect(
        SherpaFileModel.wespeakerResnet34.url,
        contains('speaker-recongition-models'),
      );
    });

    test('every recognition archive comes from the k2-fsa releases', () {
      for (final model in SherpaRecognitionModel.all) {
        expect(
          model.archiveUrl,
          startsWith('https://github.com/k2-fsa/sherpa-onnx/releases/'),
          reason: model.id,
        );
        expect(model.archiveUrl, endsWith('.tar.bz2'), reason: model.id);
      }
    });

    test('every entry records its exact size and a well-formed digest', () {
      final digest = RegExp(r'^[0-9a-f]{64}$');
      for (final model in SherpaRecognitionModel.all) {
        expect(model.archiveBytes, greaterThan(0), reason: model.id);
        if (model.archiveSha256 case final sha?) {
          expect(sha, matches(digest), reason: model.id);
        }
        // IDs match the upstream archive, so a wrong one is a broken URL.
        expect(model.archiveUrl, endsWith('/${model.id}.tar.bz2'));
        expect(model.unpackedDirName, model.id);
      }
      for (final model in <SherpaFileModel>[
        SherpaFileModel.sileroVad,
        SherpaFileModel.wespeakerResnet34,
      ]) {
        expect(model.sha256, matches(digest), reason: model.id);
      }
    });

    test('the batch default is checked by digest', () {
      expect(SherpaRecognitionModel.defaultModel.archiveSha256, isNotNull);
    });

    test('transducers declare a joiner and Whisper models do not', () {
      for (final model in SherpaRecognitionModel.all) {
        switch (model.kind) {
          case SherpaRecognitionModelKind.transducer:
          case SherpaRecognitionModelKind.streamingTransducer:
            expect(model.joinerFile, isNotNull, reason: model.id);
          case SherpaRecognitionModelKind.whisper:
            expect(model.joinerFile, isNull, reason: model.id);
        }
      }
    });
  });
}

/// Serves canned bodies and records which URLs were requested.
final class _FakeClient extends http.BaseClient {
  _FakeClient(
    this._bodies, {
    this.statusCode = 200,
    this.sendLength = true,
    this.failAfterFirstChunk = false,
    this.holdAfterFirstChunk = false,
    this.holdHeaders = false,
    this.ignoreClose = false,
    this.statusCodes = const {},
  });

  final Map<String, Uint8List> _bodies;
  final int statusCode;

  /// Whether the response declares its length.
  final bool sendLength;

  /// Whether the body breaks off with an error after its first chunk.
  final bool failAfterFirstChunk;

  /// Whether the body stalls after its first chunk until the client closes.
  final bool holdAfterFirstChunk;

  /// Whether the response never arrives, as on a connection that hangs.
  final bool holdHeaders;

  /// Whether a held body stays held after [close], as on a transport whose
  /// stream survives closing the client.
  final bool ignoreClose;

  /// Status codes that replace [statusCode] for particular URLs.
  final Map<String, int> statusCodes;

  final List<String> requested = <String>[];
  bool closed = false;
  final _hold = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final url = request.url.toString();
    requested.add(url);
    if (holdHeaders) await Completer<void>().future;
    final body = _bodies[url] ?? Uint8List(0);
    return http.StreamedResponse(
      _chunks(body),
      statusCodes[url] ?? statusCode,
      contentLength: sendLength ? body.length : null,
      request: request,
    );
  }

  Stream<List<int>> _chunks(Uint8List body) async* {
    final half = body.length ~/ 2;
    yield Uint8List.sublistView(body, 0, half);
    if (failAfterFirstChunk) {
      throw http.ClientException('Connection reset');
    }
    if (holdAfterFirstChunk) {
      await (ignoreClose ? Completer<void>().future : _hold.future);
      throw http.ClientException('Connection closed');
    }
    yield Uint8List.sublistView(body, half);
  }

  @override
  void close() {
    closed = true;
    if (!_hold.isCompleted) _hold.complete();
  }
}

/// Serves [body] in [chunkSize] chunks, sending each only while the reader
/// is not paused, and calls [beforeChunk] with the bytes sent so far before
/// each one.
final class _PacedClient extends http.BaseClient {
  _PacedClient(this.body, {required this.chunkSize, required this.beforeChunk});

  final Uint8List body;
  final int chunkSize;
  final void Function(int sent) beforeChunk;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    late final StreamController<List<int>> controller;
    Future<void> pump() async {
      var sent = 0;
      while (sent < body.length) {
        // Give the reader a turn to push back before the next chunk.
        await Future<void>.delayed(Duration.zero);
        if (controller.isPaused) continue;
        beforeChunk(sent);
        final end = min(sent + chunkSize, body.length);
        controller.add(Uint8List.sublistView(body, sent, end));
        sent = end;
      }
      await controller.close();
    }

    controller = StreamController<List<int>>(onListen: pump);
    return http.StreamedResponse(
      controller.stream,
      200,
      contentLength: body.length,
      request: request,
    );
  }
}
