import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:audio_core/audio_core.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:speech_core/speech_core.dart';
import 'package:speech_sherpa/speech_sherpa.dart';

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
  Uint8List buildArchive(Map<String, String> files) {
    final archive = Archive();
    for (final entry in files.entries) {
      final bytes = utf8.encode(entry.value);
      archive.add(ArchiveFile.bytes(entry.key, bytes));
    }
    final tar = TarEncoder().encodeBytes(archive);
    return Uint8List.fromList(BZip2Encoder().encode(tar));
  }

  group('resolve', () {
    test('returns null until every required file exists', () {
      final registry = SherpaModelRegistry(root: root);
      const model = SherpaRecognitionModel.parakeetTdtV3;
      final dir = registry.recognitionDirectory(model)
        ..createSync(recursive: true);

      File('${dir.path}/${model.encoderFile}').writeAsStringSync('e');
      File('${dir.path}/${model.decoderFile}').writeAsStringSync('d');
      File('${dir.path}/${model.tokensFile}').writeAsStringSync('t');
      // The joiner is still missing, so a transducer is not usable yet.
      expect(registry.resolveRecognition(model), isNull);

      File('${dir.path}/${model.joinerFile}').writeAsStringSync('j');
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
    }) => SherpaRecognitionModel(
      id: 'test-transducer',
      displayName: 'Test transducer',
      kind: SherpaRecognitionModelKind.transducer,
      archiveUrl: 'https://example.test/test-transducer.tar.bz2',
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

    test('ignores archive entries that escape the destination', () async {
      final archive = buildArchive(<String, String>{
        '../escaped.onnx': 'nope',
        'test-transducer/encoder.onnx': 'e',
        'test-transducer/decoder.onnx': 'd',
        'test-transducer/joiner.onnx': 'j',
        'test-transducer/tokens.txt': 't',
      });
      final model = modelFor(archive);
      final registry = SherpaModelRegistry(
        root: root,
        httpClientFactory: () => _FakeClient({model.archiveUrl: archive}),
      );

      await registry.installRecognition(model);

      expect(File('${root.path}/escaped.onnx').existsSync(), isFalse);
      expect(File('${root.parent.path}/escaped.onnx').existsSync(), isFalse);
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
  });

  final Map<String, Uint8List> _bodies;
  final int statusCode;

  /// Whether the response declares its length.
  final bool sendLength;

  /// Whether the body breaks off with an error after its first chunk.
  final bool failAfterFirstChunk;

  /// Whether the body stalls after its first chunk until the client closes.
  final bool holdAfterFirstChunk;

  final List<String> requested = <String>[];
  bool closed = false;
  final _hold = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final url = request.url.toString();
    requested.add(url);
    final body = _bodies[url] ?? Uint8List(0);
    return http.StreamedResponse(
      _chunks(body),
      statusCode,
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
      await _hold.future;
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
