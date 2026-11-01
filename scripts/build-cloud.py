#!/usr/bin/env python3
"""Build a Python 3.12 x86_64 Linux Lambda asset without Docker or private keys."""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apple-roots", required=True, type=Path, help="Directory with reviewed Apple root .cer files")
    parser.add_argument("--root-sha256", required=True, action="append", help="Reviewed DER SHA-256, one per root")
    parser.add_argument("--output", required=True, type=Path, help="New output directory")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Output must not exist; choose a fresh build directory")
    roots = sorted(args.apple_roots.glob("*.cer"))
    hashes = {hashlib.sha256(p.read_bytes()).hexdigest() for p in roots}
    if not roots or hashes != {h.lower() for h in args.root_sha256}:
        parser.error("Apple root certificate fingerprints do not match reviewed allowlist")
    root = Path(__file__).resolve().parents[1]
    args.output.mkdir(parents=True)
    subprocess.run([sys.executable, "-m", "pip", "install", "--require-hashes", "--only-binary=:all:",
        "--platform", "manylinux_2_34_x86_64", "--platform", "manylinux_2_28_x86_64",
        "--platform", "manylinux2014_x86_64", "--implementation", "cp", "--python-version", "3.12",
        "--target", str(args.output), "-r", str(root / "backend/billing/requirements.lock")], check=True)
    (args.output / "backend").mkdir()
    (args.output / "backend/__init__.py").write_text("")
    for module in ("billing", "cloud"):
        shutil.copytree(root / "backend" / module, args.output / "backend" / module,
                        ignore=shutil.ignore_patterns("test_*", "__pycache__", "requirements*", "*.md", "*.yaml"))
    (args.output / "apple-roots").mkdir()
    for certificate in roots:
        shutil.copyfile(certificate, args.output / "apple-roots" / certificate.name)
    print(f"Built Linux Lambda asset: {args.output.resolve()}")


if __name__ == "__main__":
    main()
