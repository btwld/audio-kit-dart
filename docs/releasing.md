# Releasing Audio Kit

Audio Kit is a pub workspace, with independently versioned public packages. All package manifests use hosted constraints; workspace
resolution selects the matching local members during development.

## First publication

Pub.dev requires the first version of every new package to be published
manually. Run the full validation from a clean, pushed commit:

```sh
./tool/verify.sh
./tool/publish_dry_run.sh
```

Publish in dependency order and wait for each package to become visible on
pub.dev before publishing a dependent package:

1. `audio_core`, `audio_flutter_platform_interface`
2. `audio_kit_graph`, `audio_processing`, `speech_core`,
   `audio_flutter_darwin`, `audio_flutter_linux`, `audio_flutter_windows`
3. `audio_aec`, `speech_sherpa`, `audio_flutter`, `voice_core`,
   `speech_deepgram`, `speech_openai_tts`, `speech_fluidaudio`, `speech_mlx`
4. `voice_flutter`

The private `sherpa_onnx_macos` override and example applications use
`publish_to: none`. Only publish packages listed in `tool/publish_dry_run.sh`.

All hosted dependencies, including the adapter engines and any newly added
workspace dependencies, must exist on pub.dev at compatible versions.

Publish one package with:

```sh
cd packages/audio_core
flutter pub publish
```

The CLI opens a browser for the one-time pub.dev authorization when no local
credential exists.

## Enable trusted publishing

After a first publication, open the package’s Admin tab and transfer it to
[concepta.dev](https://pub.dev/publishers/concepta.dev). To enable automated releases:

1. Open `https://pub.dev/packages/<package>/admin`.
2. Enable GitHub Actions publishing.
3. Set repository to `btwld/audio-kit-dart`.
4. Set tag pattern to `<package>-v{{version}}`.
5. Require the GitHub environment `pub.dev`.

The repository has a package-specific workflow for every publishable workspace
member: 17 `publish-<package>.yml` files, one per directory under `packages/`,
each triggered only by a `<package>-v*` tag. (`packages/audio_flutter/example`
is a workspace member too, but it is `publish_to: none` and has no workflow.)
Adding a package means adding its workflow in the same change. Only the publish
job receives `id-token: write`; no pub token is stored.

## Later releases

Update the package pubspec and package changelog, merge the tested change, and
push a matching tag:

```sh
git tag audio_core-v0.1.1
git push origin audio_core-v0.1.1
```

The reusable preflight checks that the tag equals the pubspec version, performs
a publish dry-run, and copies the package outside the workspace to prove that
all hosted dependencies resolve independently. The official Dart publishing
workflow then exchanges GitHub's short-lived OIDC identity for pub.dev access.
