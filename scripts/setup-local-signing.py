#!/usr/bin/env python3
"""Create one app-specific code-signing identity in the login Keychain.
Private material exists only in a mode-0700 temporary directory during import.
No private key is printed, exported from Keychain, or placed in this repository.
"""
import os
import pathlib
import re
import subprocess
import tempfile

LABEL = "ScreenTranslate Local Development"
ROOT = pathlib.Path(__file__).resolve().parent.parent

def run(args, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise SystemExit(f"{args[0]} failed: {result.stderr.strip()}")
    return result.stdout

identities = run(["security", "find-identity", "-v", "-p", "codesigning"])
match = re.search(r'([A-F0-9]{40}) "' + re.escape(LABEL) + r'"', identities)
if not match:
    # Never silently replace an existing certificate: that would break app identity.
    existing = subprocess.run(["security", "find-certificate", "-c", LABEL], capture_output=True)
    if existing.returncode == 0:
        raise SystemExit("An existing ScreenTranslate certificate is not usable. Repair it in Keychain Access; do not regenerate it.")
    os.umask(0o077)
    keychain = pathlib.Path.home() / "Library/Keychains/login.keychain-db"
    with tempfile.TemporaryDirectory(prefix="screentranslate-signing-") as directory:
        directory = pathlib.Path(directory)
        config = directory / "certificate.cnf"
        config.write_text("""[req]
prompt = no
distinguished_name = dn
x509_extensions = extensions
[dn]
CN = ScreenTranslate Local Development
[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
""")
        private = directory / "private.pem"
        certificate = directory / "certificate.pem"
        run(["/usr/bin/openssl", "req", "-new", "-x509", "-newkey", "rsa:3072", "-nodes", "-days", "3650",
             "-config", str(config), "-keyout", str(private), "-out", str(certificate)])
        run(["security", "import", str(private), "-k", str(keychain), "-T", "/usr/bin/codesign", "-x"])
        run(["security", "import", str(certificate), "-k", str(keychain)])
        # Trust applies only to code signing, never SSL, mail, or a system root store.
        run(["security", "add-trusted-cert", "-r", "trustRoot", "-p", "codeSign", "-k", str(keychain), str(certificate)])
    identities = run(["security", "find-identity", "-v", "-p", "codesigning"])
    match = re.search(r'([A-F0-9]{40}) "' + re.escape(LABEL) + r'"', identities)
    if not match:
        raise SystemExit("Identity import completed but code signing is not available. Check Keychain Access.")
local = ROOT / ".local"
local.mkdir(mode=0o700, exist_ok=True)
(local / "signing-identity").write_text(match.group(1) + "\n")
print("App-specific signing identity is ready in the login Keychain.")
