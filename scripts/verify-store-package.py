#!/usr/bin/env python3
"""Inspect a signed Store export in a temporary directory; never install it."""
import argparse
import json
import os
import plistlib
from pathlib import Path
import re
import subprocess
import tempfile


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_installer_signature(output, team):
    require(re.fullmatch(r'[A-Z0-9]{10}', team or ''), 'expected package team is required')
    require(re.search(r'Status: signed by (a certificate trusted by macOS|a developer certificate issued by Apple for distribution)', output), 'package signature must be trusted by macOS')
    leaf = re.search(r'^\s*1\. (.+)$', output, re.MULTILINE)
    require(leaf and leaf[1].startswith('3rd Party Mac Developer Installer:') and leaf[1].endswith(f'({team})'), 'package installer certificate class/team mismatch')


def payload_identity(info):
    fields = {'bundle_id': info.get('CFBundleIdentifier'), 'version': info.get('CFBundleShortVersionString'), 'build': info.get('CFBundleVersion')}
    require(all(isinstance(value, str) and value and value == value.strip() and len(value) <= 128 for value in fields.values()), 'payload identity/version/build must be nonempty bounded strings')
    require(fields['bundle_id'] == 'com.wali.store.WALI', 'payload must use the AppStore bundle identifier')
    require(re.fullmatch(r'\d+(?:\.\d+){0,2}', fields['version']) and re.fullmatch(r'\d+(?:\.\d+){0,2}', fields['build']), 'payload version/build must use numeric dotted components')
    return fields


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('package', type=Path)
    parser.add_argument('--team', required=True)
    parser.add_argument('--receipt', type=Path, required=True)
    args = parser.parse_args()
    require(args.package.is_file() and not args.package.is_symlink(), 'Store package must be a regular file')
    result = subprocess.run(['/usr/sbin/pkgutil', '--check-signature', str(args.package)], check=True, capture_output=True, text=True)
    validate_installer_signature(result.stdout, args.team)
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix='wali-store-package-') as directory:
        destination = Path(directory) / 'expanded'
        subprocess.run(['/usr/sbin/pkgutil', '--expand-full', str(args.package), str(destination)], check=True, capture_output=True)
        require(not any(p.is_symlink() for p in destination.rglob('*')), 'Store package contains symlinks')
        require(not any(p.name == 'Scripts' for p in destination.rglob('*')), 'Store package must not contain installer scripts')
        apps = list(destination.rglob('WALI.app'))
        require(len(apps) == 1, 'Store package must contain one WALI.app payload')
        app = apps[0]
        payloads = [p for p in destination.rglob('Payload') if p.is_dir()]
        require(bool(payloads), 'Store package has no expanded payload')
        for payload in payloads:
            require(all(p == app or app in p.parents or p in app.parents for p in payload.rglob('*')), 'Store package contains files outside WALI.app')
        subprocess.run(['python3', str(root / 'scripts/verify-store-bundle.py'), str(app), '--configuration', 'AppStore', '--signed', '--team', args.team], check=True)
        identity = payload_identity(plistlib.loads((app / 'Contents/Info.plist').read_bytes()))
        ruby = 'require ARGV.shift; puts WALIReleaseSupport.bundle_digest(ARGV.fetch(0))'
        digest = subprocess.run(['/usr/bin/ruby', '-e', ruby, str(root / 'fastlane/release_support.rb'), str(app)], check=True, capture_output=True, text=True).stdout.strip()
        require(re.fullmatch(r'[0-9a-f]{64}', digest), 'payload digest is invalid')
        require(args.receipt.parent.is_dir() and not args.receipt.parent.is_symlink(), 'receipt directory must exist and cannot be a symlink')
        with tempfile.NamedTemporaryFile(mode='w', prefix='.store-payload-', dir=args.receipt.parent, delete=False) as receipt:
            staged_receipt = Path(receipt.name)
            receipt.write(json.dumps({'app_sha256': digest, 'team_id': args.team, 'configuration': 'AppStore', 'verified_payload': 'exported_pkg', **identity}, indent=2) + '\n')
            receipt.flush()
            os.fsync(receipt.fileno())
        try:
            os.replace(staged_receipt, args.receipt)
        finally:
            staged_receipt.unlink(missing_ok=True)
    print('Verified the actual signed Store PKG payload and installer certificate.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'Store package verification failed: {error}')
