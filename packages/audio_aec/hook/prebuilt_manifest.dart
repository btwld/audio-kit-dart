// The prebuilt-artifact naming scheme and its sha256 pins.
//
// Kept separate from `build.dart` so the release process has exactly one file
// to touch: cut a release, upload the per-platform artifacts, drop their
// hashes into [pinnedSha256]. Nothing else in the package changes.

/// Artifact file name for a target, e.g. `aec_ffi-macos-arm64.dylib`.
///
/// The triple is in the name rather than in the path so that a GitHub release —
/// a flat bag of files under one tag — can host every platform at once. [os]
/// and [arch] are the lowercase `OS`/`Architecture` names `package:code_assets`
/// already uses (`macos`, `linux`, `windows`; `arm64`, `x64`), so the hook does
/// not carry a translation table that could drift from theirs.
String prebuiltArtifactName({required String os, required String arch}) =>
    'aec_ffi-$os-$arch.${_extension(os)}';

/// File name the *loader* expects on disk, which is not the artifact name.
///
/// The downloaded artifact is renamed to this before it is registered, so a
/// library resolved through a build hook and one resolved through
/// `AUDIO_AEC_LIBRARY` have the same name on disk. That matters when someone is
/// reading `otool -L` output or a crash log and trying to tell the two apart.
String installedLibraryName(String os) =>
    os == 'windows' ? 'aec_ffi.dll' : 'libaec_ffi.${_extension(os)}';

String _extension(String os) => switch (os) {
  'macos' || 'ios' => 'dylib',
  'windows' => 'dll',
  _ => 'so',
};

/// Default base URL for released artifacts.
///
/// Overridable with the `prebuilt_url_base` user-define. The version is the
/// native ABI release in [artifactVersion], rather than `latest`, because a
/// build hook that silently picks up a new binary is not reproducible.
const String defaultUrlBase =
    'https://github.com/btwld/audio-kit-dart/releases/download/'
    'audio_aec-native-v$artifactVersion';

/// Release tag component of [defaultUrlBase].
///
/// This tracks the *ABI*, not the package version: it changes when
/// `native/aec_ffi.cc` or the pinned webrtc-audio-processing revision changes,
/// not when Dart-side code does. Bumping the package version does not invalidate
/// a binary whose ABI is unchanged.
const String artifactVersion = '0.1.0';

/// SHA-256 digests of the published artifacts, keyed by target OS and CPU.
/// Generated from the verified native release using
/// `tool/prebuilt_release.py render-pins`.
const Map<String, String> pinnedSha256 = <String, String>{
  'linux-x64':
      'b81a46de161389f8e4c8cbc0c91b15d2f18fe7d0c59f4b1916356f36e0cf117b',
  'macos-arm64':
      'ae6a21a6b90a6a853cf73455f6d802a00aeb60972a3e904384e4954dcdac1511',
  'macos-x64':
      'f7f2ca2f314e8db64e5da5127705b3ed410b184361fbfd0e6e0278bafe34f31d',
  'windows-x64':
      '6524a691991f028c4ba35f4ab44adf8b3a18795c54f07e8681ef41e11cae433e',
};
