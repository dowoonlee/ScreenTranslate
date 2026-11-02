#!/usr/bin/env python3
"""Build an app bundle without ever copying preferences, credentials, or captures."""
import argparse
import base64
import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
os.chdir(ROOT)
parser = argparse.ArgumentParser()
parser.add_argument("--mode", choices=["development", "production", "unsigned"], default="development")
parser.add_argument("--identity", help="Code signing identity name or SHA-1 fingerprint (public metadata)")
parser.add_argument("--arch", choices=["universal", "arm64", "x86_64"], default="universal")
args = parser.parse_args()
release = json.loads((ROOT / "config/release.json").read_text())
assert re.fullmatch(r"\d+\.\d+\.\d+", release["version"]), "Use a numeric semantic version"
assert re.fullmatch(r"[1-9]\d*", release["build"]), "Build must be a positive increasing integer"
public_key = (ROOT / "config/sparkle-public-key.txt").read_text().strip()
assert len(base64.b64decode(public_key, validate=True)) == 32, "Invalid public update key"
identity = args.identity
if args.mode == "unsigned":
    identity = "-"
elif not identity:
    if args.mode == "production":
        raise SystemExit("Production builds require --identity 'Developer ID Application: …'.")
    saved = ROOT / ".local/signing-identity"
    if not saved.exists():
        raise SystemExit("Run scripts/setup-local-signing.py first. Ad-hoc signing is never an implicit fallback.")
    identity = saved.read_text().strip()

# Detect the selected identity before modifying dist.
if args.mode != "unsigned":
    identities = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
    matches = [line for line in identities.splitlines() if identity in line]
    if len(matches) != 1:
        raise SystemExit("Signing identity is unavailable or ambiguous.")
    if args.mode == "production" and '"Developer ID Application:' not in matches[0]:
        raise SystemExit("Production requires an Apple-issued Developer ID Application identity.")

architectures = ["arm64", "x86_64"] if args.arch == "universal" else [args.arch]
binaries = []
for architecture in architectures:
    base = ["swift", "build", "-c", "release", "--arch", architecture]
    subprocess.run(base, check=True)
    directory = pathlib.Path(subprocess.check_output(base + ["--show-bin-path"], text=True).strip())
    # Recent SwiftPM uses a shared Xcode build directory for both architectures.
    # Save each completed slice before building the next one.
    slice_path = ROOT / ".build/release-slices" / architecture / "ScreenTranslate"
    slice_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(directory / "ScreenTranslate", slice_path)
    binaries.append(slice_path)

app = ROOT / "dist/ScreenTranslate.app"
if app.exists():
    shutil.rmtree(app)
(app / "Contents/MacOS").mkdir(parents=True)
(app / "Contents/Frameworks").mkdir()
(app / "Contents/Resources").mkdir()
executable = app / "Contents/MacOS/ScreenTranslate"
if len(binaries) == 2:
    subprocess.run(["lipo", "-create", *map(str, binaries), "-output", str(executable)], check=True)
else:
    shutil.copy2(binaries[0], executable)
subprocess.run(["strip", "-S", str(executable)], check=True)
framework_source = ROOT / ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
framework = app / "Contents/Frameworks/Sparkle.framework"
shutil.copytree(framework_source, framework, symlinks=True)
shutil.copy2(ROOT / ".build/artifacts/sparkle/Sparkle/LICENSE", app / "Contents/Resources/Sparkle-LICENSE.txt")

info = {
    "CFBundleExecutable": "ScreenTranslate", "CFBundleIdentifier": "dev.screentranslate.app",
    "CFBundleName": "ScreenTranslate", "CFBundleDisplayName": "ScreenTranslate", "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": release["version"], "CFBundleVersion": release["build"],
    "LSMinimumSystemVersion": "13.0", "LSUIElement": True, "NSHighResolutionCapable": True,
    "NSScreenCaptureUsageDescription": "선택한 화면 영역을 캡처하여 한국어로 번역합니다.",
    "SUFeedURL": release["feedURL"] if args.mode == "production" else release["developmentFeedURL"],
    "SUPublicEDKey": public_key,
    "SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": False, "SUAllowsAutomaticUpdates": False,
    "SUEnableSystemProfiling": False, "SUShowReleaseNotes": False,
    "SUVerifyUpdateBeforeExtraction": True, "SURequireSignedFeed": True,
    "SUSignedFeedFailureExpirationInterval": 0,
    "ScreenTranslateReleaseMode": args.mode,
}
with (app / "Contents/Info.plist").open("wb") as stream:
    plistlib.dump(info, stream)

# Sign inside-out, preserving the bundled helper entitlements supplied by Sparkle.
# --deep is for verification only; never use it as a substitute for nested signing.
base = ["codesign", "--force", "--sign", identity]
if args.mode == "production":
    base += ["--options", "runtime", "--timestamp"]
else:
    base += ["--timestamp=none"]
version = framework / "Versions/B"
for target in [version / "Autoupdate", version / "Updater.app", version / "XPCServices/Downloader.xpc",
               version / "XPCServices/Installer.xpc", framework]:
    if target.exists():
        subprocess.run(base + ["--preserve-metadata=entitlements", str(target)], check=True)
subprocess.run(base + [str(app)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
if args.mode == "production":
    subprocess.run(["codesign", "--verify", "-R",
                    "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists", str(app)], check=True)
print(f"Built {release['version']} ({release['build']}) / {args.mode} / {args.arch}: {app}")
