#!/usr/bin/env python3
"""Check the release boundary and update security flags before publication."""
import argparse
import pathlib
import plistlib
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("--allow-unsigned", action="store_true")
args = parser.parse_args()
app = root / "dist/ScreenTranslate.app"
with (app / "Contents/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
assert info.get("CFBundleIconFile") == "AppIcon", "App icon not configured"
assert (app / "Contents/Resources/AppIcon.icns").read_bytes()[:4] == b"icns", "App icon missing or invalid"
for name in ["SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"]:
    assert info.get(name) is True, f"Required policy missing: {name}"
for name in ["SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUEnableSystemProfiling", "SUShowReleaseNotes"]:
    assert info.get(name) is False, f"Unexpected policy: {name}"
assert info["SUSignedFeedFailureExpirationInterval"] == 0
assert info["SUPublicEDKey"] == (root / "config/sparkle-public-key.txt").read_text().strip()
assert info["SUFeedURL"].startswith("https://raw.githubusercontent.com/dowoonlee/ScreenTranslate/main/docs/appcast")
if not args.allow_unsigned:
    assert info["ScreenTranslateReleaseMode"] != "unsigned", "Unsigned builds must never be released."
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
for path in app.rglob("*"):
    if path.is_symlink():
        assert path.resolve().is_relative_to(app.resolve()), "Bundle symlink leaves bundle"
    assert path.suffix.lower() not in {".p12", ".pfx", ".pem", ".key", ".db", ".sqlite", ".log"}, "Private artifact in bundle"
    assert path.name not in {".env", ".local", "capture.png"}, "Private artifact in bundle"
expected = {"MacOS", "Frameworks", "Resources", "Info.plist", "_CodeSignature"}
assert {p.name for p in (app / "Contents").iterdir()} <= expected
print("Bundle policy and code signatures verified.")
