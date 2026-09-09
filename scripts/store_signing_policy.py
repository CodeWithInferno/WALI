"""Deterministic signing policy for Store artifacts. No credential or network access."""
import datetime
import fnmatch
import re


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_signature(metadata, *, configuration, identifier, team, expected, profile, leaf_certificate, now=None):
    require(re.fullmatch(r'[A-Z0-9]{10}', team or '') is not None, 'explicit expected team is required')
    require(configuration in ('StoreDevelopment', 'AppStore'), 'unknown Store signing configuration')
    require(metadata.get('sealed') and metadata.get('strict_valid'), 'strict sealed signature is required')
    require(metadata.get('signature') != 'adhoc', 'ad-hoc signature is not signed feasibility')
    require(metadata.get('team_identifier') == team, 'signature TeamIdentifier differs from expected team')
    require(metadata.get('runtime') is True, 'hardened runtime is required')
    authorities = metadata.get('authorities') or []
    prefixes = ('Apple Development:', 'Mac Developer:') if configuration == 'StoreDevelopment' else ('Apple Distribution:', '3rd Party Mac Developer Application:')
    require(bool(authorities) and authorities[0].startswith(prefixes), 'certificate class does not match Store configuration')
    entitlements = metadata.get('entitlements') or {}
    application_id = team + '.' + identifier
    require(entitlements.get('com.apple.developer.team-identifier') == team, 'signed team entitlement mismatch')
    require(entitlements.get('com.apple.application-identifier') == application_id, 'signed application identifier mismatch')
    for key, value in expected.items():
        require(entitlements.get(key) == value, f'signed entitlement mismatch: {key}')
    allowed = set(expected) | {'com.apple.application-identifier', 'com.apple.developer.team-identifier', 'keychain-access-groups', 'com.apple.security.get-task-allow'}
    require(set(entitlements) <= allowed, 'unexpected signed entitlement')
    if 'keychain-access-groups' in entitlements:
        require(entitlements['keychain-access-groups'] == [application_id], 'keychain groups must be exactly this Store application identifier')
    if configuration == 'AppStore':
        require(entitlements.get('com.apple.security.get-task-allow', False) is False, 'AppStore must not allow debugger attachment')
    if profile is None:
        require('com.apple.security.application-groups' not in expected, 'app-group provisioning profile is required')
        return
    require(profile.get('TeamIdentifier') == [team], 'profile team mismatch')
    require(profile.get('ApplicationIdentifierPrefix') == [team], 'profile application prefix mismatch')
    require(bool(set(profile.get('Platform', [])) & {'OSX', 'macOS'}), 'profile must authorize macOS')
    current = now or datetime.datetime.now(datetime.timezone.utc)
    expiry = profile.get('ExpirationDate')
    creation = profile.get('CreationDate')
    require(isinstance(expiry, datetime.datetime), 'profile expiration is required')
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=datetime.timezone.utc)
    require(expiry > current, 'profile expired')
    require(isinstance(creation, datetime.datetime), 'profile creation date is required')
    if creation.tzinfo is None:
        creation = creation.replace(tzinfo=datetime.timezone.utc)
    require(creation <= current, 'profile is not yet valid')
    require(leaf_certificate in profile.get('DeveloperCertificates', []), 'signing certificate is not authorized by profile')
    grants = profile.get('Entitlements') or {}
    require(grants.get('com.apple.application-identifier') == application_id, 'profile must authorize the exact Store application ID')
    require(grants.get('com.apple.developer.team-identifier') == team, 'profile team entitlement mismatch')
    restricted = {'com.apple.security.application-groups', 'com.apple.developer.applesignin', 'keychain-access-groups'}
    for key, value in entitlements.items():
        if key not in restricted and key not in grants:
            continue  # Public sandbox/file capabilities do not require profile grants.
        grant = grants.get(key)
        if isinstance(value, list):
            require(isinstance(grant, list) and all(any(isinstance(g, str) and fnmatch.fnmatchcase(item, g) for g in grant) for item in value), f'profile does not authorize entitlement: {key}')
        else:
            require(grant == value, f'profile does not authorize entitlement: {key}')
    if configuration == 'StoreDevelopment':
        require(bool(profile.get('ProvisionedDevices')) and not profile.get('ProvisionsAllDevices', False), 'StoreDevelopment requires a development device profile')
    else:
        require(not profile.get('ProvisionedDevices') and not profile.get('ProvisionsAllDevices', False), 'AppStore requires a Store distribution profile')
        require(grants.get('com.apple.security.get-task-allow', False) is False, 'distribution profile allows debugger attachment')


def validate_binary_compatibility(architectures, minimum_versions, *, configuration, host_arch, info_version, per_arch_info=None):
    architectures = set(architectures)
    require(architectures and architectures <= {'arm64', 'x86_64'}, 'unsupported Mach-O architecture')
    if configuration == 'AppStore':
        require(architectures == {'arm64', 'x86_64'}, 'AppStore must be universal arm64 and x86_64')
    else:
        require(host_arch in architectures, 'StoreDevelopment must contain the host architecture')
    require(set(minimum_versions) == architectures, 'every Mach-O slice must have a minimum OS')
    def is_macos_15(value):
        return isinstance(value, str) and re.fullmatch(r'15\.0(?:\.0)?', value) is not None
    require(is_macos_15(info_version), 'Info minimum macOS must match 15.0 policy')
    require(all(is_macos_15(value) for value in minimum_versions.values()), 'Mach-O minimum macOS must match 15.0 policy')
    if per_arch_info is not None:
        require(isinstance(per_arch_info, dict) and set(per_arch_info) <= architectures and all(is_macos_15(v) for v in per_arch_info.values()), 'per-architecture Info minimum macOS mismatch')


def validate_no_coverage_instrumentation(load_commands, symbols):
    """Inspect sections too, so symbol stripping cannot hide instrumentation."""
    sections = re.findall(r'^\s*sectname (\S+)$', load_commands, re.MULTILINE)
    require(not any(name.startswith(('__llvm_prf_', '__llvm_cov')) for name in sections),
            'Store release must not contain LLVM coverage sections')
    require('__llvm_profile_' not in symbols, 'Store release must not contain LLVM profile runtime')
