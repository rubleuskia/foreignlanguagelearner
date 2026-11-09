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
    parser.add_argument("--mode", choices=["subscription", "operator"], default="subscription")
    parser.add_argument("--apple-roots", type=Path, help="Directory with reviewed Apple root .cer files")
    parser.add_argument("--root-sha256", action="append", help="Reviewed DER SHA-256, one per root")
    parser.add_argument("--output", required=True, type=Path, help="New output directory")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Output must not exist; choose a fresh build directory")
    if args.mode == 'subscription' and (not args.apple_roots or not args.root_sha256):
        parser.error('Subscription mode requires reviewed Apple roots and fingerprints')
    roots = sorted(args.apple_roots.glob("*.cer")) if args.mode == 'subscription' else []
    hashes = {hashlib.sha256(p.read_bytes()).hexdigest() for p in roots}
    if args.mode == 'subscription' and (not roots or hashes != {h.lower() for h in args.root_sha256}):
        parser.error("Apple root certificate fingerprints do not match reviewed allowlist")
    root = Path(__file__).resolve().parents[1]
    args.output.mkdir(parents=True)
    subprocess.run([sys.executable, "-m", "pip", "install", "--require-hashes", "--only-binary=:all:",
        "--platform", "manylinux_2_34_x86_64", "--platform", "manylinux_2_28_x86_64",
        "--platform", "manylinux2014_x86_64", "--implementation", "cp", "--python-version", "3.12",
        "--target", str(args.output), "-r", str(root / ('backend/private_cloud/requirements.lock' if args.mode == 'operator' else 'backend/billing/requirements.lock'))], check=True)
    (args.output / "backend").mkdir()
    (args.output / "backend/__init__.py").write_text("")
    modules = ("private_cloud", "cloud", "translation", "alignment") if args.mode == 'operator' else ("billing", "cloud", "translation", "alignment", "paid_alignment")
    for module in modules:
        if args.mode == 'operator' and module in ('cloud', 'translation'):
            destination = args.output / 'backend' / module
            destination.mkdir()
            files = ('__init__.py', 'errors.py', 'dynamo.py') if module == 'cloud' else ('__init__.py', 'contract.py', 'provider.py')
            for name in files:
                shutil.copyfile(root / 'backend' / module / name, destination / name)
        else:
            shutil.copytree(root / "backend" / module, args.output / "backend" / module,
                            ignore=shutil.ignore_patterns("test_*", "__pycache__", "requirements*", "*.md", "*.yaml"))
    (args.output / "apple-roots").mkdir()
    for certificate in roots:
        shutil.copyfile(certificate, args.output / "apple-roots" / certificate.name)
    print(f"Built Linux Lambda asset: {args.output.resolve()}")


if __name__ == "__main__":
    main()
