#!/usr/bin/env python3
"""Package, optionally notarize, and sign a release. Does not publish anything.
Signing keys stay in Keychain. Production requires a Developer ID build and a
notarytool Keychain profile; an unsigned/unnotarized production release fails.
"""
import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parent.parent
os.chdir(ROOT)
parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--mode", choices=["development", "production"], default="development")
parser.add_argument("--notary-profile", help="Name of credentials stored by xcrun notarytool store-credentials")
args = parser.parse_args()
if not re.fullmatch(r"v\d+\.\d+\.\d+(?:-preview\.\d+)?", args.tag):
    raise SystemExit("Tag must be vX.Y.Z or vX.Y.Z-preview.N")
if args.mode == "development" and "-preview." not in args.tag:
    raise SystemExit("Development builds must use a preview tag.")
if args.mode == "production" and ("-preview." in args.tag or not args.notary_profile):
    raise SystemExit("Production requires a stable tag and --notary-profile.")
release = json.loads((ROOT / "config/release.json").read_text())
app = ROOT / "dist/ScreenTranslate.app"
with (app / "Contents/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
if info["ScreenTranslateReleaseMode"] != args.mode:
    raise SystemExit("App signing mode does not match the requested release mode.")
if info["CFBundleShortVersionString"] != release["version"] or info["CFBundleVersion"] != release["build"]:
    raise SystemExit("App version differs from release configuration. Rebuild first.")
if args.tag.removeprefix("v").split("-preview.")[0] != release["version"]:
    raise SystemExit("Tag and app version differ.")
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
architecture = subprocess.check_output(["lipo", "-archs", str(app / "Contents/MacOS/ScreenTranslate")], text=True).split()
if set(architecture) != {"arm64", "x86_64"}:
    raise SystemExit("Public release must include both arm64 and x86_64 slices.")
folder = ROOT / "dist/releases" / args.tag
folder.mkdir(parents=True, exist_ok=True)
archive = folder / f"ScreenTranslate-{release['version']}-universal.zip"
def archive_app():
    if archive.exists():
        archive.unlink()
    subprocess.run(["ditto", "-c", "-k", "--keepParent", str(app), str(archive)], check=True)
archive_app()
if args.mode == "production":
    subprocess.run(["codesign", "--verify", "-R", "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists", str(app)], check=True)
    result = subprocess.check_output(["xcrun", "notarytool", "submit", str(archive), "--keychain-profile", args.notary_profile,
                                      "--wait", "--output-format", "json"], text=True)
    if json.loads(result).get("status") != "Accepted":
        raise SystemExit("Apple notarization did not accept this build; release preparation stopped.")
    subprocess.run(["xcrun", "stapler", "staple", str(app)], check=True)
    subprocess.run(["xcrun", "stapler", "validate", str(app)], check=True)
    subprocess.run(["spctl", "--assess", "--type", "execute", str(app)], check=True)
    archive_app()

feed_name = "appcast.xml" if args.mode == "production" else "appcast-dev.xml"
feed = folder / feed_name
previous = ROOT / "docs" / feed_name
if previous.exists():
    # Preserve the URLs/signatures of older releases.
    shutil.copy2(previous, feed)
tools = ROOT / ".build/artifacts/sparkle/Sparkle/bin"
public_key = subprocess.check_output([str(tools / "generate_keys"), "--account", release["sparkleKeyAccount"], "-p"], text=True).strip()
if public_key != info["SUPublicEDKey"]:
    raise SystemExit("Signing key does not match the public key embedded in the app.")
subprocess.run([str(tools / "generate_appcast"), "--account", release["sparkleKeyAccount"],
                "--maximum-deltas", "0", "--maximum-versions", "3",
                "--download-url-prefix", f"https://github.com/{release['repository']}/releases/download/{args.tag}/",
                "--link", f"https://github.com/{release['repository']}/releases/tag/{args.tag}",
                "-o", str(feed), str(folder)], check=True)
subprocess.run([str(tools / "sign_update"), "--account", release["sparkleKeyAccount"], "--verify", str(feed)], check=True)
namespace = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
root = ET.parse(feed).getroot()
items = root.findall("./channel/item")
current = next((item for item in items if item.findtext("sparkle:version", namespaces=namespace) == release["build"]), None)
if current is None:
    raise SystemExit("Generated feed has no entry for the current build.")
enclosure = current.find("enclosure")
signature = enclosure.attrib["{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"]
subprocess.run([str(tools / "sign_update"), "--account", release["sparkleKeyAccount"], "--verify", str(archive), signature], check=True)
shutil.copy2(feed, previous)
(folder / "SHA256SUMS.txt").write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + "  " + archive.name + "\n")
print(f"Prepared and verified release: {folder}")
print("Upload the ZIP and SHA256SUMS.txt to a GitHub draft release, publish it, then publish the signed feed.")
