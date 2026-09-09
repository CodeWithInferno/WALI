#!/usr/bin/env python3
"""Check the actual Store artifact; unsigned output never proves sandbox behavior."""
import argparse
import json
import tempfile
import plistlib
import re
import subprocess
from pathlib import Path
from store_signing_policy import validate_binary_compatibility, validate_no_coverage_instrumentation, validate_signature


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def plist(path):
    return plistlib.loads(path.read_bytes())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=Path)
    parser.add_argument('--configuration', choices=['StoreDevelopment', 'AppStore'], default='StoreDevelopment')
    parser.add_argument('--signed', action='store_true')
    parser.add_argument('--team')
    args = parser.parse_args()
    require(not args.app.is_symlink(), 'App root must not be a symlink')
    require(not args.signed or re.fullmatch(r'[A-Z0-9]{10}', args.team or ''), 'Signed verification requires explicit --team')
    app = args.app.resolve(strict=True)
    require(not any(path.is_symlink() for path in app.rglob('*')), 'Store bundle cannot contain symlinks')
    root = Path(__file__).resolve().parent.parent
    part = 'store.development' if args.configuration == 'StoreDevelopment' else 'store'
    group = f'group.com.wali.{part}.shared'
    main_id = f'com.wali.{part}.WALI'
    agent_id = f'com.wali.{part}.WALIAgent'
    worker_id = f'com.wali.{part}.WALITranscoder'
    agent = app / 'Contents/Library/LoginItems/WALIAgent.app'
    worker = agent / 'Contents/XPCServices/WALITranscoder.xpc'
    wrappers = {app, agent, worker}
    actual = {app} | {p for p in app.rglob('*') if p.suffix in ('.app', '.xpc', '.framework') and p.is_dir()}
    require(actual == wrappers, 'Store must contain exactly WALI.app, WALIAgent.app, WALITranscoder.xpc; no helpers or dynamic frameworks')
    forbidden = re.compile(rb'WALILockScreen(?:Helper|Wire)|LockScreenHelperXPCProtocol|com\.apple\.wallpaper/Store|com\.apple\.wallpaper/[^\x00\n]*Index\.plist|com\.apple\.ScreenSaver|Privacy_AllFiles|/Library/Application Support/com\.apple\.idleassetsd|activateVerifiedRelease:reply:')
    infos = {}
    signed_teams = set()
    host_arch = run('/usr/bin/uname', '-m').decode().strip()
    for bundle, identifier in [(app, main_id), (agent, agent_id), (worker, worker_id)]:
        require(not bundle.is_symlink(), f'Bundle cannot be a symlink: {bundle.name}')
        info = plist(bundle / 'Contents/Info.plist')
        infos[bundle] = info
        require(info['CFBundleIdentifier'] == identifier, f'{bundle.name}: Store bundle identifier')
        require(info.get('WALIDistribution') == 'store', f'{bundle.name}: Store distribution metadata')
        require(not any('LockScreenHelper' in k for k in info), f'{bundle.name}: helper Info metadata')
        executable = bundle / 'Contents/MacOS' / info['CFBundleExecutable']
        require(executable.is_file() and not executable.is_symlink(), f'{bundle.name}: missing executable')
        require(forbidden.search(executable.read_bytes()) is None, f'{bundle.name}: helper/private-operation bytes remain in Mach-O')
        architectures = run('/usr/bin/lipo', '-archs', str(executable)).decode().split()
        minimum_versions = {}
        for architecture in architectures:
            build = run('/usr/bin/xcrun', 'vtool', '-arch', architecture, '-show-build', str(executable)).decode()
            platforms = re.findall(r'^\s*platform (\S+)$', build, re.MULTILINE)
            minimums = re.findall(r'^\s*minos (\S+)$', build, re.MULTILINE)
            require(platforms == ['MACOS'] and len(minimums) == 1, f'{bundle.name}: invalid per-slice macOS build metadata')
            minimum_versions[architecture] = minimums[0]
        validate_binary_compatibility(architectures, minimum_versions, configuration=args.configuration,
                                      host_arch=host_arch, info_version=info.get('LSMinimumSystemVersion'),
                                      per_arch_info=info.get('LSMinimumSystemVersionByArchitecture'))
        if args.configuration == 'AppStore':
            validate_no_coverage_instrumentation(run('/usr/bin/otool', '-arch', 'all', '-l', str(executable)).decode(),
                                                 run('/usr/bin/xcrun', 'nm', '-arch', 'all', '-j', str(executable)).decode())
        linked = run('/usr/bin/otool', '-L', str(executable)).decode()
        require('/PrivateFrameworks/' not in linked, f'{bundle.name}: private framework dependency')
        if args.signed:
            # Bind the trusted Apple code signature to the caller's selected team and ID.
            requirement = f'anchor apple generic and identifier "{identifier}" and certificate leaf[subject.OU] = "{args.team}"'
            run('/usr/bin/codesign', '--verify', '--strict', '--test-requirement', requirement, str(bundle))
            metadata = json.loads(run('/usr/bin/ruby', str(root / 'scripts/inspect-signature-metadata.rb'), str(bundle)))
            expected = plist(root / 'Config' / f'Store-{bundle.stem}.entitlements')
            expected = {k: [group if item == '$(WALI_APP_GROUP_IDENTIFIER)' else item for item in v] if isinstance(v, list) else v for k, v in expected.items()}
            profile_path = bundle / 'Contents/embedded.provisionprofile'
            profile = plistlib.loads(run('/usr/bin/security', 'cms', '-D', '-i', str(profile_path))) if profile_path.is_file() else None
            with tempfile.TemporaryDirectory(prefix='wali-store-cert-') as temporary:
                prefix = str(Path(temporary) / 'certificate-')
                run('/usr/bin/codesign', '-d', '--extract-certificates', prefix, str(bundle))
                leaf = Path(prefix + '0').read_bytes()
            validate_signature(metadata, configuration=args.configuration, identifier=identifier, team=args.team,
                               expected=expected, profile=profile, leaf_certificate=leaf)
            signed_teams.add(metadata['team_identifier'])
        print(f'Store bundle verified: {bundle.name}, {identifier}, {",".join(architectures)}, macOS 15.0')
    versions = {(info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')) for info in infos.values()}
    require(len(versions) == 1 and all(versions.pop()), 'Embedded versions must be present and equal')
    require(infos[app].get('WALIExpectedAgentBundleIdentifier') == agent_id, 'Foreground expected peer')
    require(infos[agent].get('WALIExpectedClientBundleIdentifier') == main_id, 'Agent expected peer')
    require(infos[worker].get('WALIExpectedClientBundleIdentifier') == agent_id, 'Worker expected peer')
    for bundle in (app, agent):
        require(infos[bundle].get('WALIControlServiceName') == group + '.agent-control', 'Group-prefixed Mach service')
        require(infos[bundle].get('WALIApplicationGroupIdentifier') == group, 'App group metadata')
    require(infos[agent].get('WALITranscoderServiceName') == worker_id, 'Agent private worker service')
    launch_name = infos[app]['WALIAgentLaunchAgentPlistName']
    require(launch_name == agent_id + '.plist', 'Selected launch plist identity')
    launch_dir = app / 'Contents/Library/LaunchAgents'
    require({p.name for p in launch_dir.iterdir()} == {launch_name}, 'Store bundle must contain only its selected launch plist')
    selected = plist(launch_dir / launch_name)
    require(selected['RunAtLoad'] is False and selected['KeepAlive'] == {'Crashed': True}, 'Launch policy must require consent and restart only crashes')
    require(selected['MachServices'] == {group + '.agent-control': True}, 'Launch Mach service')
    require(not any('LockScreen' in p.name for p in app.rglob('*')), 'Helper resources must be absent')
    require(len(signed_teams) == 1 if args.signed else True, 'All executable signatures must share one team')
    run('/usr/bin/ruby', str(root / 'scripts/verify-third-party-licenses.rb'), str(app))
    run('/usr/bin/xcrun', 'swift', str(root / 'scripts/verify-branding.swift'), str(app), '--store')
    print('Signed Store bundle policy verified; interactive sandbox journeys remain required.' if args.signed else 'Structural Store bundle verified. Signing, provisioning, sandbox access, service registration, and runtime journeys are unverified.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        raise SystemExit(f'Store bundle verification failed: {error}')
