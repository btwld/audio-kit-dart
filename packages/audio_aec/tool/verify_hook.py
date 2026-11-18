#!/usr/bin/env python3
"""Verify the native release through a standalone Dart consumer."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile


PACKAGE = Path(__file__).resolve().parents[1]


def main():
    filename = {"Darwin": "libaec_ffi.dylib", "Linux": "libaec_ffi.so",
                "Windows": "aec_ffi.dll"}[platform.system()]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, default=PACKAGE / ".native" / filename)
    library = parser.parse_args().library.resolve()
    digest = hashlib.sha256(library.read_bytes()).hexdigest()
    other_digest = ("0" if digest[0] != "0" else "1") + digest[1:]
    dart = shutil.which("dart")
    if dart is None:
        parser.error("Dart SDK is required")
    env = os.environ.copy()
    env.pop("AUDIO_AEC_LIBRARY", None)

    with tempfile.TemporaryDirectory() as tmp:
        consumer = Path(tmp)
        shutil.copytree(PACKAGE / "example/test", consumer / "test")
        manifest = (PACKAGE / "example/pubspec.yaml").read_text(encoding="utf8")
        manifest = manifest.split("\nhooks:\n")[0].rstrip()
        manifest = manifest.replace("path: ../", "path: " + json.dumps(PACKAGE.as_posix()))
        for pin, expected in [(digest, "present"), (other_digest, "absent")]:
            defines = ("\n\nhooks:\n  user_defines:\n    audio_aec:\n"
                       f"      prebuilt_url: {json.dumps(library.as_uri())}\n"
                       f"      prebuilt_sha256: {json.dumps(pin)}\n")
            (consumer / "pubspec.yaml").write_text(manifest + defines, encoding="utf8")
            env["AUDIO_AEC_EXPECT_ASSET"] = expected
            subprocess.run([dart, "pub", "get"], cwd=consumer, env=env, check=True)
            subprocess.run([dart, "test", "--reporter=expanded"], cwd=consumer, env=env, check=True)


if __name__ == "__main__":
    main()
