# Native AEC3 runtime

The Dart package and the native runtime have independent versions. The
[0.1.0 native release](https://github.com/btwld/audio-kit-dart/releases/tag/audio_aec-native-v0.1.0)
contains four libraries built from the WebRTC revision in
[`native_release.env`](../tool/native_release.env). Each release includes
`audio_aec-prebuilt-manifest.json` with SHA-256 digests and sizes, plus
`audio_aec-NOTICE.txt` for redistribution with the runtime.

| Target | Release asset |
|---|---|
| macOS 12+ on Apple Silicon | `aec_ffi-macos-arm64.dylib` |
| macOS 12+ on Intel | `aec_ffi-macos-x64.dylib` |
| Linux x64 with glibc 2.34+ and libstdc++ providing `GLIBCXX_3.4.29` | `aec_ffi-linux-x64.so` |
| Windows x64 | `aec_ffi-windows-x64.dll` |

## Build hook

The default hook selects the **build target**, verifies the download against
the package’s [built-in pins](../hook/prebuilt_manifest.dart), and registers a
bundled code asset. Each target has a separate cache entry. On unsupported
targets, or when the download fails, the hook emits a diagnostic. The runtime
can still resolve a library by an explicit path or `AUDIO_AEC_LIBRARY`.

For a standalone executable, use `dart build cli`. With Dart 3.12,
`dart compile exe` rejects dependencies that use build hooks. The CLI bundle
includes the native asset alongside the executable.

Configure overrides in `hooks.user_defines.audio_aec` in the consuming
workspace’s root `pubspec.yaml`.

| Setting | Effect |
|---|---|
| `prebuilt` | Use a local library. Paths are relative to the root pubspec. |
| `prebuilt_url` | Fetch a specific HTTPS or file URL. |
| `prebuilt_url_base` | Append the target-specific release filename to this base URL. |
| `prebuilt_sha256` | Override the expected digest for a custom binary. Quote the 64 hex digits. |
| `from_source: true` | Build on a matching macOS or Linux host. An explicit local binary or download takes precedence. |
| `allow_unpinned: true` | Permit a custom URL without an expected digest. Known targets still use their package pins unless you supply a different digest. |

A digest mismatch registers no code asset. Use `probeAecRuntime()` to check
availability before enabling echo cancellation.

## Build and verify a local runtime

Run these commands from the repository root with Git, Meson, Ninja, Python 3,
a C++ compiler (C++20 on MSVC), and the Dart SDK available.

```sh
packages/audio_aec/tool/build_native.sh
python3 packages/audio_aec/tool/verify_hook.py
```

On Windows, invoke `build_native_windows.sh` from Git Bash with the x64 Visual
Studio developer environment loaded and use `python` for the verification
script. The build defaults to the package-local `.native/` directory. The
verification script creates a temporary Dart consumer using hosted dependencies,
checks that the correct digest supplies a working engine, and repeats with an
incorrect digest to verify that the hook rejects it.

## macOS application distribution

The release dylibs are ad-hoc signed. Their install names have room for the
Dart SDK to rewrite them when bundling. Flutter packages its code asset inside
the application, which must sign its embedded frameworks along with the app.

The development and native release checks exercise loading and processing.
Developer ID signing, notarization, and Gatekeeper assessment of a final
Flutter application are separate distribution checks. Validate the signed and
stapled release app with `spctl -a -vvv MyApp.app` before distributing it.

## Release process

1. Dispatch `release-audio-aec-prebuilt.yml` with `publish_release` disabled.
   Each target runner builds its own binary, tests registration through the
   Dart hook, resolves all six C symbols, and creates and destroys engines at
   16 kHz and 48 kHz.
2. Download the combined `audio-aec-prebuilt-release` artifact, verify its
   manifest, and publish those exact four binaries, the manifest, and the
   notice under a new native release tag. Keep existing release assets intact.
3. Download the public release, verify it again, and render the hook pins
   from those bytes. From the `audio_aec` package directory:

   ```sh
   python3 tool/prebuilt_release.py verify --manifest release/audio_aec-prebuilt-manifest.json --directory release
   python3 tool/prebuilt_release.py render-pins --manifest release/audio_aec-prebuilt-manifest.json --directory release
   ```

4. Verify the default download in a fresh consumer and run
   `dart pub publish --dry-run` for the Dart package. Follow the
   [Audio Kit release guide](https://github.com/btwld/audio-kit-dart/blob/main/docs/releasing.md)
   for the first publication and publisher transfer.
