#!/usr/bin/env python3
"""Check Git's publication allowlist; never print detected secret values."""
import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
failures = []
private_suffixes = {".p12", ".pfx", ".pem", ".key", ".cer", ".log", ".png", ".jpg", ".jpeg", ".sqlite", ".db"}
patterns = [
    ("private-key", re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
    ("provider-key", re.compile(rb"\bsk-(?:ant-)?[A-Za-z0-9_-]{35,}")),
    ("github-token", re.compile(rb"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})")),
    ("personal-workspace", re.compile(rb"\bwrkspc_[A-Za-z0-9]{16,}")),
    ("local-home-path", re.compile(rb"/(?:Users|home)/[A-Za-z0-9._-]+/")),
]
for name in filter(None, paths):
    path = pathlib.Path(name)
    if any(part in {".local", ".build", "dist", "__pycache__"} for part in path.parts) or path.suffix in private_suffixes or path.name.startswith(".env"):
        failures.append((name, "non-source-file"))
        continue
    data = (root / path).read_bytes()
    for label, pattern in patterns:
        if pattern.search(data):
            failures.append((name, label))
if failures:
    for name, label in failures:
        print(f"Blocked: {name} ({label}; contents redacted)")
    raise SystemExit(1)
print(f"Public file audit passed ({len(list(filter(None, paths)))} files).")
