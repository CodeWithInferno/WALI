#!/usr/bin/env python3
"""Exercise the real pinned scanner in disposable Git repositories."""
import hashlib
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

    def add_production_checksum(self, relative_path='Fixtures/Release/production-config-v1.json', checksum=None):
        fixture = json.loads((ROOT / 'Fixtures/Release/production-config-v1.json').read_text())
        settings = fixture['settings']
        synthetic_key = 'sb_publishable_' + 'x' * 32
        self.assertEqual(settings['WALI_SUPABASE_PUBLISHABLE_KEY'], synthetic_key)
        known_checksum = hashlib.sha256(synthetic_key.encode()).hexdigest()
        self.assertEqual(settings['WALI_SUPABASE_PUBLISHABLE_KEY_SHA256'], known_checksum)
        path = self.repo / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({'WALI_SUPABASE_PUBLISHABLE_KEY_SHA256': checksum or known_checksum}, indent=4) + '\n')
        self.command('git', 'add', relative_path)
        self.command('git', 'commit', '-qm', 'add public checksum scanner fixture')

    def test_known_synthetic_checksum_passes_only_in_release_fixture(self):
        self.add_production_checksum()
        result = self.scan()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_known_checksum_in_another_file_is_still_scanned(self):
        self.add_production_checksum(relative_path='Config/unreviewed.json')
        self.assertEqual(self.scan().returncode, 1)

    def test_changed_checksum_in_release_fixture_is_still_scanned(self):
        self.add_production_checksum(checksum=hashlib.sha256(b'an unreviewed scanner fixture').hexdigest())
        self.assertEqual(self.scan().returncode, 1)

    def test_token_in_release_fixture_is_still_scanned_and_redacted(self):
        self.add_production_checksum()
        token = 'ghp_' + ''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(36))
        path = self.repo / 'Fixtures/Release/production-config-v1.json'
        with path.open('a') as output:
            output.write('github_token = "' + token + '"\n')
        self.command('git', 'add', str(path.relative_to(self.repo)))
        self.command('git', 'commit', '-qm', 'add generated release scanner fixture token')
        result = self.scan()
        self.assertEqual(result.returncode, 1)
        report = (self.repo / '.build/security/gitleaks-history.json').read_text()
        self.assertTrue(any(finding['RuleID'] == 'github-pat' for finding in json.loads(report)))
        self.assertNotIn(token, report + result.stdout + result.stderr)

    def add_reviewed_production_manifest(self, relative_path='Config/Marketplace.production.json', overrides=None):
        manifest = json.loads((ROOT / 'Config/Marketplace.production.json').read_text())
        settings = manifest['settings']
        public_key = settings['WALI_SUPABASE_PUBLISHABLE_KEY']
        self.assertTrue(public_key.startswith('sb_publishable_'), 'fixture must use a public publishable key')
        self.assertEqual(settings['WALI_SUPABASE_PUBLISHABLE_KEY_SHA256'],
                         hashlib.sha256(public_key.encode()).hexdigest())
        settings.update(overrides or {})
        path = self.repo / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(manifest, indent=2) + '\n')
        self.command('git', 'add', relative_path)
        self.command('git', 'commit', '-qm', 'add reviewed public production scanner fixture')
        return path

    def assert_generic_findings(self, relative_path, count):
        result = self.scan()
        self.assertEqual(result.returncode, 1, result.stderr)
        report = json.loads((self.repo / '.build/security/gitleaks-history.json').read_text())
        findings = [finding for finding in report
                    if finding['RuleID'] == 'generic-api-key' and finding['File'] == relative_path]
        self.assertEqual(len(findings), count)

    def test_reviewed_production_public_fields_pass(self):
        self.add_reviewed_production_manifest()
        result = self.scan()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.repo / '.build/security/gitleaks-history.json').read_text()), [])

    def test_changed_production_publishable_key_is_still_scanned(self):
        changed_key = 'sb_publishable_' + secrets.token_urlsafe(24)
        self.add_reviewed_production_manifest(overrides={'WALI_SUPABASE_PUBLISHABLE_KEY': changed_key})
        self.assert_generic_findings('Config/Marketplace.production.json', 1)

    def test_changed_production_publishable_checksum_is_still_scanned(self):
        changed_checksum = hashlib.sha256(b'an unreviewed production checksum').hexdigest()
        self.add_reviewed_production_manifest(overrides={'WALI_SUPABASE_PUBLISHABLE_KEY_SHA256': changed_checksum})
        self.assert_generic_findings('Config/Marketplace.production.json', 1)

    def test_reviewed_production_public_fields_in_another_file_are_still_scanned(self):
        self.add_reviewed_production_manifest(relative_path='Config/Marketplace.unreviewed.json')
        self.assert_generic_findings('Config/Marketplace.unreviewed.json', 2)

    def test_reviewed_production_values_under_other_fields_are_still_scanned(self):
        path = self.add_reviewed_production_manifest()
        text = path.read_text().replace('WALI_SUPABASE_PUBLISHABLE_KEY"', 'UNREVIEWED_API_KEY"')
        text = text.replace('WALI_SUPABASE_PUBLISHABLE_KEY_SHA256"', 'OTHER_API_KEY"')
        path.write_text(text)
        self.command('git', 'add', str(path.relative_to(self.repo)))
        self.command('git', 'commit', '-qm', 'move public values to unreviewed field names')
        self.assert_generic_findings('Config/Marketplace.production.json', 2)

    def test_production_exceptions_require_complete_reviewed_lines(self):
        path = self.add_reviewed_production_manifest()
        lines = path.read_text().splitlines()
        fields = ('"WALI_SUPABASE_PUBLISHABLE_KEY":', '"WALI_SUPABASE_PUBLISHABLE_KEY_SHA256":')
        lines = [line + ' # extra unreviewed content' if any(field in line for field in fields)
                 else line for line in lines]
        path.write_text('\n'.join(lines) + '\n')
        self.command('git', 'add', str(path.relative_to(self.repo)))
        self.command('git', 'commit', '-qm', 'append unreviewed content to public field line')
        self.assert_generic_findings('Config/Marketplace.production.json', 2)

    def test_provider_token_in_production_manifest_is_still_scanned_and_redacted(self):
        path = self.add_reviewed_production_manifest()
        token = 'ghp_' + ''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(36))
        with path.open('a') as output:
            output.write('github_token = "' + token + '"\n')
        self.command('git', 'add', str(path.relative_to(self.repo)))
        self.command('git', 'commit', '-qm', 'append generated provider scanner fixture token')
        result = self.scan()
        self.assertEqual(result.returncode, 1, result.stderr)
        report = (self.repo / '.build/security/gitleaks-history.json').read_text()
        self.assertTrue(any(finding['RuleID'] == 'github-pat' for finding in json.loads(report)))
        self.assertTrue(token not in report + result.stdout + result.stderr,
                        'generated provider token must be fully redacted')

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
