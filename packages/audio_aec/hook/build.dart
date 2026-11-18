// Bundles the native AEC3 library for the requested target. The consuming
// workspace can select a local file, a custom download or a native source
// build through hooks.user_defines.audio_aec. Supported targets otherwise
// use the pinned public release. If no asset is available, the runtime can
// still load an explicitly supplied library.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';

import 'prebuilt_manifest.dart';

void main(List<String> args) async {
  await build(args, (BuildInput input, BuildOutputBuilder output) async {
    // `buildCodeAssets` is false for e.g. a pure `dart analyze`, or a Flutter
    // build whose native-assets support is switched off. Doing the work anyway
    // would download a few megabytes nobody asked for.
    if (!input.config.buildCodeAssets) {
      return;
    }

    final CodeConfig code = input.config.code;
    final String os = code.targetOS.name;
    final String arch = code.targetArchitecture.name;
    final String target = '$os-$arch';

    final File? library = await _resolveLibrary(input, output, os, arch);
    if (library == null) {
      _diagnose(target);
      return;
    }

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        // Must match the @DefaultAsset on lib/src/native_asset_bindings.dart.
        name: 'src/native_asset_bindings.dart',
        // Bundled: the SDK copies this file next to the consumer's output and
        // owns its install name from here on. It is NOT DynamicLoadingSystem —
        // there is no system-wide libaec_ffi to find.
        linkMode: DynamicLoadingBundled(),
        file: library.uri,
      ),
    );
    stderr.writeln(
      'audio_aec: registered ${library.path} as a code asset for $target.',
    );
  });
}

/// Runs the strategies in precedence order; `null` means none produced a file.
Future<File?> _resolveLibrary(
  BuildInput input,
  BuildOutputBuilder output,
  String os,
  String arch,
) async {
  // 1. An explicit local file. This is the vendor-your-own-binary escape hatch,
  //    and it is what the prototype harness in tool/ uses. Trusted verbatim:
  //    the consumer named a path on their own disk, so a hash check would only
  //    protect them from themselves.
  final Uri? local = input.userDefines.path('prebuilt');
  if (local != null) {
    final File file = File.fromUri(local);
    // Declared even when missing, so creating it later re-runs the hook.
    output.dependencies.add(local);
    if (file.existsSync()) {
      return file;
    }
    stderr.writeln(
      'audio_aec: hooks.user_defines.audio_aec.prebuilt points at '
      '${file.path}, which does not exist.',
    );
    return null;
  }

  // An explicit source build takes precedence over the package's release pins.
  // An explicit download URL or digest still takes precedence over compilation.
  if (input.userDefines['from_source'] == true &&
      input.userDefines['prebuilt_url'] == null &&
      input.userDefines['prebuilt_url_base'] == null &&
      input.userDefines['prebuilt_sha256'] == null) {
    if ((os != 'macos' && os != 'linux') ||
        os != OS.current.name ||
        arch != Architecture.current.name) {
      stderr.writeln(
        'audio_aec: from_source requires a matching macOS or Linux host for $os-$arch.',
      );
      return null;
    }
    return _buildFromSource(input, os);
  }

  final _Download? download = _plan(input, os, arch);
  return download == null ? null : _fetch(input, download, os);
}

/// What to fetch and what it must hash to; `null` when no URL is configured.
_Download? _plan(BuildInput input, String os, String arch) {
  final Object? explicitUrl = input.userDefines['prebuilt_url'];
  final Object? base = input.userDefines['prebuilt_url_base'];
  final Object? pin = input.userDefines['prebuilt_sha256'];
  final bool allowUnpinned = input.userDefines['allow_unpinned'] == true;

  // `pin` is stringified rather than type-tested because YAML types an unquoted
  // all-digit hash as an *integer*, and silently treating that as "no pin
  // supplied" would downgrade a consumer's verification to none — the one
  // failure mode this code exists to prevent.
  final String? expected = pin?.toString().trim() ?? pinnedSha256['$os-$arch'];
  final String? resolvedBase = base is String
      ? base
      : (expected != null ? defaultUrlBase : null);

  final Uri? url = switch (explicitUrl) {
    final String value => Uri.parse(value),
    _ =>
      resolvedBase == null
          ? null
          : Uri.parse(
              '${resolvedBase.endsWith('/') ? resolvedBase : '$resolvedBase/'}'
              '${prebuiltArtifactName(os: os, arch: arch)}',
            ),
  };
  if (url == null) {
    return null;
  }

  if (expected == null && !allowUnpinned) {
    stderr.writeln(
      'audio_aec: refusing to fetch $url — no sha256 pin for $os-$arch. '
      'Whoever controls that URL would control code running in this build. '
      'Set hooks.user_defines.audio_aec.prebuilt_sha256, or allow_unpinned: '
      'true to accept the risk.',
    );
    return null;
  }
  return _Download(url, expected);
}

/// Downloads (or copies, for `file:`) and verifies. `null` on any failure.
///
/// Failures here are reported and swallowed rather than raised: a package whose
/// build breaks because a release server had a bad minute is worse than one
/// that falls back to `AUDIO_AEC_LIBRARY`.
Future<File?> _fetch(BuildInput input, _Download plan, String os) async {
  // A universal desktop build can run separate hooks for arm64 and x64.
  // Keep each downloaded library with the target and user-defines that selected it.
  final Uri cacheUri = input.outputDirectory.resolve(installedLibraryName(os));
  final File cached = File.fromUri(cacheUri);
  if (cached.existsSync() &&
      (plan.sha256 == null || _hash(cached) == plan.sha256)) {
    return cached;
  }

  List<int> bytes;
  try {
    if (plan.url.scheme == 'file') {
      bytes = await File.fromUri(plan.url).readAsBytes();
    } else {
      final HttpClient client = HttpClient();
      try {
        final HttpClientRequest request = await client.getUrl(plan.url);
        final HttpClientResponse response = await request.close();
        if (response.statusCode != 200) {
          stderr.writeln(
            'audio_aec: ${plan.url} returned HTTP ${response.statusCode}.',
          );
          return null;
        }
        bytes = await response.fold<List<int>>(
          <int>[],
          (List<int> acc, List<int> chunk) => acc..addAll(chunk),
        );
      } finally {
        client.close();
      }
    }
  } on Object catch (error) {
    stderr.writeln('audio_aec: fetching ${plan.url} failed: $error');
    return null;
  }

  final String actual = sha256.convert(bytes).toString();
  if (plan.sha256 != null && actual != plan.sha256) {
    stderr.writeln(
      'audio_aec: sha256 mismatch for ${plan.url}\n'
      '  expected ${plan.sha256}\n'
      '  actual   $actual\n'
      'Refusing to register it. Nothing was installed.',
    );
    return null;
  }

  await cached.parent.create(recursive: true);
  await cached.writeAsBytes(bytes, flush: true);
  // The download arrives without the executable bit on some filesystems, and a
  // dylib that cannot be read back is a confusing failure later.
  if (!Platform.isWindows) {
    await Process.run('chmod', <String>['755', cached.path]);
  }
  stderr.writeln('audio_aec: fetched ${plan.url} (sha256 $actual).');
  return cached;
}

/// Runs `tool/build_native.sh`, which needs meson, ninja and a C++ toolchain.
Future<File?> _buildFromSource(BuildInput input, String os) async {
  final File script = File.fromUri(
    input.packageRoot.resolve('tool/build_native.sh'),
  );
  if (!script.existsSync()) {
    stderr.writeln('audio_aec: ${script.path} is missing.');
    return null;
  }
  final Uri dest = input.outputDirectory.resolve('from_source/');
  final ProcessResult result;
  try {
    result = await Process.run('bash', <String>[
      script.path,
      dest.toFilePath(),
    ]);
  } on ProcessException catch (error) {
    stderr.writeln('audio_aec: could not start the native build: $error');
    return null;
  }
  if (result.exitCode != 0) {
    stderr.writeln(
      'audio_aec: tool/build_native.sh failed (exit ${result.exitCode}):\n'
      '${result.stderr}',
    );
    return null;
  }
  final File built = File.fromUri(dest.resolve(installedLibraryName(os)));
  return built.existsSync() ? built : null;
}

String _hash(File file) => sha256.convert(file.readAsBytesSync()).toString();

/// Explains how to supply a library when the hook cannot register one.
void _diagnose(String target) {
  stderr.writeln(
    'audio_aec: no native library for $target — registering no code asset.\n'
    '  This is not a build failure. AecProcessor.create() still resolves an\n'
    '  explicit libraryPath or \$AUDIO_AEC_LIBRARY at runtime, and throws\n'
    '  AecUnavailable listing every path tried if neither is set.\n'
    '  To have this hook supply one, add to your workspace pubspec.yaml:\n'
    '    hooks:\n'
    '      user_defines:\n'
    '        audio_aec:\n'
    '          prebuilt: path/to/${installedLibraryName(target.split('-').first)}\n'
    '  See package:audio_aec doc/DISTRIBUTION.md for the other strategies.',
  );
}

/// A planned fetch: where from, and what it must hash to (`null` = unpinned).
final class _Download {
  const _Download(this.url, this.sha256);

  final Uri url;
  final String? sha256;
}
