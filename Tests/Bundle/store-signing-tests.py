#!/usr/bin/env python3
import copy
import datetime
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('store_signing_policy', ROOT / 'scripts/store_signing_policy.py')
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)
package_spec = importlib.util.spec_from_file_location('verify_store_package', ROOT / 'scripts/verify-store-package.py')
package_policy = importlib.util.module_from_spec(package_spec)
package_spec.loader.exec_module(package_policy)


class StoreSigningTests(unittest.TestCase):
    def setUp(self):
        self.team = 'TESTTEAM01'
        self.identifier = 'com.wali.store.WALI'
        self.now = datetime.datetime(2026, 9, 9, tzinfo=datetime.timezone.utc)
        self.expected = {'com.apple.security.app-sandbox': True, 'com.apple.security.application-groups': ['group.com.wali.store.shared'], 'com.apple.developer.applesignin': ['Default']}
        entitlements = self.expected | {'com.apple.application-identifier': self.team + '.' + self.identifier, 'com.apple.developer.team-identifier': self.team, 'keychain-access-groups': [self.team + '.' + self.identifier]}
        self.metadata = {'sealed': True, 'strict_valid': True, 'signature': 'cms', 'runtime': True, 'team_identifier': self.team, 'authorities': ['Apple Distribution: Fixture (TESTTEAM01)'], 'entitlements': entitlements}
        self.profile = {'TeamIdentifier': [self.team], 'ApplicationIdentifierPrefix': [self.team], 'Platform': ['OSX'], 'CreationDate': self.now - datetime.timedelta(days=1), 'ExpirationDate': self.now + datetime.timedelta(days=1), 'DeveloperCertificates': [b'fixture-leaf'], 'Entitlements': copy.deepcopy(entitlements)}

    def validate(self, configuration='AppStore'):
        policy.validate_signature(self.metadata, configuration=configuration, identifier=self.identifier, team=self.team, expected=self.expected, profile=self.profile, leaf_certificate=b'fixture-leaf', now=self.now)

    def test_installer_signing_class_and_team(self):
        valid = 'Status: signed by a certificate trusted by macOS\nCertificate Chain:\n 1. 3rd Party Mac Developer Installer: Fixture (TESTTEAM01)\n 2. Apple Worldwide Developer Relations Certification Authority\n'
        package_policy.validate_installer_signature(valid, self.team)
        for malformed in [valid.replace('TESTTEAM01', 'OTHERTEAM1'), valid.replace('3rd Party Mac Developer Installer:', 'Developer ID Installer:'), valid.replace('signed by a certificate trusted by macOS', 'no signature')]:
            with self.assertRaises(ValueError):
                package_policy.validate_installer_signature(malformed, self.team)

    def test_release_rejects_coverage_sections_and_runtime(self):
        policy.validate_no_coverage_instrumentation('  sectname __text\n  sectname __swift5_types\n', '_main\n')
        for section in ('__llvm_prf_cnts', '__llvm_prf_data', '__llvm_prf_names', '__llvm_covmap', '__llvm_covfun'):
            with self.subTest(section=section), self.assertRaisesRegex(ValueError, 'coverage sections'):
                policy.validate_no_coverage_instrumentation(f'  sectname {section}\n', '_main\n')
        with self.assertRaisesRegex(ValueError, 'profile runtime'):
            policy.validate_no_coverage_instrumentation('  sectname __text\n', '___llvm_profile_write_file\n')

    def test_universal_binary_policy(self):
        policy.validate_binary_compatibility(['arm64', 'x86_64'], {'arm64': '15.0', 'x86_64': '15.0'}, configuration='AppStore', host_arch='arm64', info_version='15.0')
        with self.assertRaisesRegex(ValueError, 'universal'):
            policy.validate_binary_compatibility(['arm64'], {'arm64': '15.0'}, configuration='AppStore', host_arch='arm64', info_version='15.0')

    def test_minimum_os_must_match_each_slice_and_info(self):
        for minimums, info in [({'arm64': '15.0', 'x86_64': '14.0'}, '15.0'), ({'arm64': '15.0', 'x86_64': '16.0'}, '15.0'), ({'arm64': '15.0', 'x86_64': '15.0'}, '14.0')]:
            with self.assertRaisesRegex(ValueError, 'minimum macOS'):
                policy.validate_binary_compatibility(['arm64', 'x86_64'], minimums, configuration='AppStore', host_arch='arm64', info_version=info)

    def test_development_requires_host_slice(self):
        policy.validate_binary_compatibility(['arm64'], {'arm64': '15.0'}, configuration='StoreDevelopment', host_arch='arm64', info_version='15.0')
        with self.assertRaisesRegex(ValueError, 'host architecture'):
            policy.validate_binary_compatibility(['x86_64'], {'x86_64': '15.0'}, configuration='StoreDevelopment', host_arch='arm64', info_version='15.0')

    def test_payload_identity_comes_from_strict_exported_info(self):
        info = {'CFBundleIdentifier': 'com.wali.store.WALI', 'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '1'}
        self.assertEqual(package_policy.payload_identity(info), {'bundle_id': 'com.wali.store.WALI', 'version': '0.1.0', 'build': '1'})
        for field, value in [('CFBundleIdentifier', 'com.wali.WALI'), ('CFBundleShortVersionString', ''), ('CFBundleVersion', 1), ('CFBundleVersion', ' 1'), ('CFBundleShortVersionString', 'beta')]:
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                package_policy.payload_identity(info | {field: value})

    def test_valid_store(self):
        self.validate()

    def test_valid_development(self):
        self.metadata['authorities'] = ['Apple Development: Fixture (TESTTEAM01)']
        self.profile['ProvisionedDevices'] = ['fixture-device']
        self.validate('StoreDevelopment')

    def test_signature_mutations(self):
        for key, value, message in [('sealed', False, 'sealed'), ('strict_valid', False, 'sealed'), ('signature', 'adhoc', 'ad-hoc'), ('runtime', False, 'hardened'), ('team_identifier', 'OTHERTEAM1', 'TeamIdentifier'), ('authorities', ['Developer ID Application: Fixture'], 'certificate class')]:
            with self.subTest(key=key):
                old = self.metadata[key]
                self.metadata[key] = value
                with self.assertRaisesRegex(ValueError, message):
                    self.validate()
                self.metadata[key] = old

    def test_profile_mutations(self):
        mutations = [('TeamIdentifier', ['OTHERTEAM1'], 'profile team'), ('ApplicationIdentifierPrefix', ['OTHERTEAM1'], 'prefix'), ('Platform', ['iOS'], 'macOS'), ('ExpirationDate', self.now, 'expired'), ('CreationDate', self.now + datetime.timedelta(days=1), 'not yet valid'), ('DeveloperCertificates', [b'other-leaf'], 'certificate'), ('ProvisionedDevices', ['device'], 'Store distribution'), ('ProvisionsAllDevices', True, 'Store distribution')]
        for key, value, message in mutations:
            with self.subTest(key=key):
                original = copy.deepcopy(self.profile)
                self.profile[key] = value
                with self.assertRaisesRegex(ValueError, message):
                    self.validate()
                self.profile = original

    def test_missing_profile(self):
        self.profile = None
        with self.assertRaisesRegex(ValueError, 'profile is required'):
            self.validate()

    def test_arbitrary_keychain_group(self):
        self.metadata['entitlements']['keychain-access-groups'] = ['TESTTEAM01.*']
        with self.assertRaisesRegex(ValueError, 'keychain groups'):
            self.validate()

    def test_profile_missing_capability(self):
        self.profile['Entitlements'].pop('com.apple.developer.applesignin')
        with self.assertRaisesRegex(ValueError, 'does not authorize'):
            self.validate()

    def test_profile_wildcard_application(self):
        self.profile['Entitlements']['com.apple.application-identifier'] = 'TESTTEAM01.*'
        with self.assertRaisesRegex(ValueError, 'exact Store application ID'):
            self.validate()

    def test_debugger_rejected_for_store(self):
        self.metadata['entitlements']['com.apple.security.get-task-allow'] = True
        with self.assertRaisesRegex(ValueError, 'debugger'):
            self.validate()

    def test_forbidden_entitlement(self):
        self.metadata['entitlements']['com.apple.security.temporary-exception.files.home-relative-path.read-write'] = ['/']
        with self.assertRaisesRegex(ValueError, 'unexpected signed'):
            self.validate()

    def test_worker_without_profile_has_no_broad_capabilities(self):
        self.expected = {'com.apple.security.app-sandbox': True}
        self.metadata['entitlements'] = self.expected | {'com.apple.application-identifier': self.team + '.' + self.identifier, 'com.apple.developer.team-identifier': self.team}
        self.profile = None
        self.validate()


if __name__ == '__main__':
    unittest.main()
