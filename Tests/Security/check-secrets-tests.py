#!/usr/bin/env python3
"""Exercise the real pinned scanner in disposable Git repositories."""
import json
import os
from pathlib import Path
import secrets
import shutil
import string
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SecretScanTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='wali-secret-scan-tests-')
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.repo = self.base / 'repo'
        self.repo.mkdir()
        self.command('git', 'init', '-q')
        self.command('git', 'config', 'user.name', 'WALI Scanner Fixture')
        self.command('git', 'config', 'user.email', 'scanner-fixture@example.invalid')
        (self.repo / 'scripts').mkdir()
        for name in ('scripts/check-secrets.sh', '.gitleaks.toml', '.gitleaksignore'):
            shutil.copy2(ROOT / name, self.repo / name)
        self.command('git', 'add', 'scripts', '.gitleaks.toml', '.gitleaksignore')
        self.command('git', 'commit', '-qm', 'add scanner fixture')

    def command(self, *args, cwd=None):
        return subprocess.run(args, cwd=cwd or self.repo, check=True, capture_output=True, text=True)

    def scan(self, repo=None, extra_env=None):
        return subprocess.run(['bash', 'scripts/check-secrets.sh'], cwd=repo or self.repo,
                              env=dict(os.environ, **(extra_env or {})), capture_output=True, text=True)

    def add_synthetic_token(self, inline_allow=False):
        token = 'ghp_' + ''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(36))
        # Use a formerly exempt file path: a new commit/finding must still fail.
        path = self.repo / 'Tests/WALILockScreenHelperTests/LockScreenHelperTests.swift'
        path.parent.mkdir(parents=True)
        path.write_text('github_token = "' + token + '"' + (' # gitleaks:allow' if inline_allow else '') + '\n')
        self.command('git', 'add', str(path.relative_to(self.repo)))
        self.command('git', 'commit', '-qm', 'add generated scanner fixture token')
        return token, path

    def test_clean_history_passes(self):
        result = self.scan()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.repo / '.build/security/gitleaks-history.json').read_text()), [])

    def test_deleted_synthetic_token_fails_and_report_is_redacted(self):
        token, path = self.add_synthetic_token()
        self.command('git', 'rm', str(path.relative_to(self.repo)))
        self.command('git', 'commit', '-qm', 'remove generated scanner fixture token')
        result = self.scan()
        self.assertEqual(result.returncode, 1)
        report = (self.repo / '.build/security/gitleaks-history.json').read_text()
        self.assertTrue(bool(json.loads(report)), 'history finding must remain after file deletion')
        self.assertTrue(token not in report + result.stdout + result.stderr, 'generated token must be fully redacted')

    def test_inline_allow_comment_cannot_bypass_scan(self):
        self.add_synthetic_token(inline_allow=True)
        self.assertEqual(self.scan().returncode, 1)

    def test_shallow_history_is_rejected(self):
        clone = self.base / 'shallow'
        self.command('git', 'clone', '-q', '--depth', '1', self.repo.as_uri(), str(clone))
        result = self.scan(repo=clone)
        self.assertEqual(result.returncode, 2)
        self.assertIn('complete fetched history', result.stderr)

    def test_existing_report_symlink_does_not_overwrite_target(self):
        target = self.base / 'unrelated.txt'
        target.write_text('preserve this file')
        report = self.repo / '.build/security/gitleaks-history.json'
        report.parent.mkdir(parents=True)
        report.symlink_to(target)
        self.assertEqual(self.scan().returncode, 0)
        self.assertEqual(target.read_text(), 'preserve this file')
        self.assertFalse(report.is_symlink())

    def test_wrong_scanner_version_is_rejected(self):
        binary = self.base / 'wrong-version'
        binary.write_text('#!/bin/sh\nprintf "0.0.0\\n"\n')
        binary.chmod(0o755)
        result = self.scan(extra_env={'GITLEAKS_BIN': str(binary)})
        self.assertEqual(result.returncode, 2)
        self.assertIn('reviewed Gitleaks 8.30.1', result.stderr)


if __name__ == '__main__':
    unittest.main()
