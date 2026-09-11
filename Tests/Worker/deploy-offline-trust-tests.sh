#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
python3 - "$ROOT" "$@" <<'PY'
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

REPO = Path(sys.argv[1])
DEPLOY = REPO / 'deploy/worker/deploy.sh'
HELPER = REPO / 'deploy/worker/image-verification.sh'
MEDIA = 'registry.example.invalid/media@sha256:' + 'a' * 64
VERIFIER = 'registry.example.invalid/verifier@sha256:' + 'b' * 64
CLASSIFIER = 'registry.example.invalid/classifier@sha256:' + 'c' * 64
MEDIA_TYPE = 'application/vnd.dev.sigstore.trustedroot+json;version=0.1'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

class OfflineTrustTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='wali-offline-trust-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.trust = self.root / 'root.json'
        self.receipt = self.root / 'receipt.json'
        self.key = self.root / 'publisher.pub'
        self.key.write_text('synthetic public test key\n')
        self.trust.write_text(json.dumps({'mediaType': MEDIA_TYPE}) + '\n')
        now = dt.datetime.now(dt.timezone.utc)
        stamp = lambda seconds: (now + dt.timedelta(seconds=seconds)).isoformat()
        self.document = {
            'status': 'authenticated-public-trust-exported',
            'verified_at': stamp(-60), 'freshness_valid_before': stamp(3600),
            'trusted_root': {'sha256': digest(self.trust), 'bytes': self.trust.stat().st_size, 'media_type': MEDIA_TYPE},
            'metadata': {role: {'expires': stamp(7200)} for role in ('root', 'timestamp', 'snapshot', 'targets')},
        }
        self.save_receipt()
        (self.root / 'worker').write_text('synthetic binary fixture\n')
        (self.root / 'media.spdx').write_text('a' * 64 + '\n')
        (self.root / 'verifier.spdx').write_text('b' * 64 + '\n')
        (self.root / 'classifier.spdx').write_text('c' * 64 + '\n')
        (self.root / 'environment').write_text(
            'WALI_DEPLOY_ENVIRONMENT=staging\nWALI_SUPABASE_PROJECT_REF=abcdefghijklmnopqrst\n'
            'WALI_DATABASE_URL=postgresql://fixture:fixture@db.abcdefghijklmnopqrst.supabase.co:5432/postgres\n'
            'WALI_STORAGE_URL=https://abcdefghijklmnopqrst.supabase.co\n'
            f'WALI_MEDIA_IMAGE={MEDIA}\nWALI_VERIFIER_IMAGE={VERIFIER}\nWALI_CLASSIFIER_IMAGE=\n')
        self.args = ['--dry-run', '--environment', 'staging', '--supabase-project-ref', 'abcdefghijklmnopqrst',
                     '--worker-binary', str(self.root / 'worker'), '--environment-file', str(self.root / 'environment'),
                     '--media-sbom', str(self.root / 'media.spdx'), '--verifier-sbom', str(self.root / 'verifier.spdx'),
                     '--cosign-key', str(self.key)]
        # Any accidental live operation in a dry run fails and leaves evidence.
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        for name in ('cosign', 'podman', 'runuser', 'systemctl', 'curl', 'wget'):
            p = bin_dir / name
            p.write_text('#!/bin/sh\nprintf attempted >> ' + shlex.quote(str(self.root / 'forbidden')) + '\nexit 99\n')
            p.chmod(0o700)
        self.env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'])
        self.env.pop('BASH_ENV', None)
        self.env.pop('ENV', None)

    def save_receipt(self):
        self.receipt.write_text(json.dumps(self.document) + '\n')
        self.pin = digest(self.receipt)

    def offline_args(self):
        return ['--offline-trust-root', str(self.trust), '--offline-trust-receipt', str(self.receipt),
                '--offline-trust-receipt-sha256', self.pin]

    def run_shell(self, code, success=True):
        prefix = 'set -Eeuo pipefail\n'
        result = subprocess.run(['bash', '-c', prefix + code], text=True, capture_output=True, env=self.env, timeout=20)
        self.assertFalse((self.root / 'forbidden').exists(), 'attempted a live command')
        if success:
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def deploy(self, extra=(), success=True):
        return self.run_shell(shlex.join(['bash', str(DEPLOY)] + self.args + list(extra)), success)

    def database_ca(self, snapshot=False):
        ca = self.root / 'database-ca.crt'
        # Synthetic public test CA; the throwaway key is never retained.
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-keyout', os.devnull, '-out', str(ca), '-days', '1',
                        '-subj', '/CN=WALI deployment test CA'],
                       check=True, capture_output=True, timeout=20)
        installed = '/etc/wali-worker/database-ca.crt'
        if snapshot:
            installed = str(self.root / 'host' / installed.lstrip('/'))
        with (self.root / 'environment').open('a') as env:
            env.write(f'PGSSLROOTCERT={installed}\n')
        return ca

    def test_database_ca_dry_run_and_configuration_refusals(self):
        ca = self.database_ca()
        args = ['--database-ca', str(ca)]
        result = self.deploy(args)
        self.assertIn('database CA', result.stdout)
        self.assertNotIn(str(ca), result.stdout)
        self.deploy([], False)
        self.deploy(args + args, False)
        self.deploy(args + ['--rollback'], False)
        self.deploy(['--database-ca', ''], False)
        env = self.root / 'environment'
        original = env.read_text()
        for setting in ('', 'PGSSLROOTCERT=\n', 'PGSSLROOTCERT=/tmp/ca.crt\n',
                        'PGSSLROOTCERT=/etc/wali-worker/database-ca.crt\n' * 2,
                        ' PGSSLROOTCERT=/etc/wali-worker/database-ca.crt\n'):
            with self.subTest(setting=setting):
                env.write_text(original[:original.index('PGSSLROOTCERT=')] + setting)
                self.deploy(args, False)

    def test_database_ca_invalid_public_files_refused(self):
        ca = self.database_ca()
        original = ca.read_bytes()
        invalid_certificate = b'-----BEGIN CERTIFICATE-----\nbm90LWRlcg==\n-----END CERTIFICATE-----\n'
        for value in (b'', b'not a certificate\n', original + b'-----BEGIN PRIVATE KEY-----\n',
                      b'x' * 65537, invalid_certificate, original + invalid_certificate,
                      original + b'-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----\n'):
            with self.subTest(value=value[:30]):
                ca.write_bytes(value)
                self.deploy(['--database-ca', str(ca)], False)
        ca.unlink(); ca.symlink_to(self.key)
        self.deploy(['--database-ca', str(ca)], False)

    def helper(self):
        return (f'source {shlex.quote(str(HELPER))}\n'
                'file_digest() { shasum -a 256 "$1" | cut -d\' \' -f1; }\n'
                "IMAGE_PATTERN='^[a-z0-9][a-z0-9./:_-]{0,191}@sha256:[a-f0-9]{64}$'\n")

    def validate(self, freshness='current'):
        return shlex.join(['validate_offline_trust', str(self.trust), str(self.receipt), self.pin, freshness])

    def test_default_and_valid_offline_dry_runs(self):
        self.assertNotIn('offline trust', self.deploy().stdout)
        result = self.deploy(self.offline_args())
        self.assertIn('offline trust', result.stdout)
        self.assertIn('does not verify image signatures', result.stdout)

    def test_partial_duplicate_and_rollback_options_refused(self):
        options = self.offline_args()
        for mask in range(1, 7):
            with self.subTest(mask=mask):
                self.deploy([arg for i in range(3) if mask & (1 << i) for arg in options[i*2:i*2+2]], False)
        self.deploy(options + options[:2], False)
        self.deploy(options + ['--rollback'], False)
        self.deploy(['--offline-trust-root', ''], False)

    def test_hash_type_length_and_freshness_refusals(self):
        baseline = json.loads(json.dumps(self.document))
        mutations = [
            lambda d: d.update(status='unverified'),
            lambda d: d['trusted_root'].update(sha256='d' * 64),
            lambda d: d['trusted_root'].update(bytes=1),
            lambda d: d['trusted_root'].update(media_type='other'),
            lambda d: d.update(verified_at='2099-01-01T00:00:00Z'),
            lambda d: d.update(verified_at='2026-02-30T00:00:00Z'),
            lambda d: d.update(freshness_valid_before='2000-01-01T00:00:00Z'),
            lambda d: d.update(freshness_valid_before='2099-01-01T00:00:00Z'),
            lambda d: d['metadata']['timestamp'].update(expires='2000-01-01T00:00:00Z'),
            lambda d: d['metadata'].pop('root'),
            lambda d: d.update(verified_at=1),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                self.document = json.loads(json.dumps(baseline)); mutate(self.document); self.save_receipt()
                self.deploy(self.offline_args(), False)
        self.document = baseline; self.save_receipt()
        self.pin = 'e' * 64
        self.deploy(self.offline_args(), False)
        self.pin = 'INVALID'
        self.deploy(self.offline_args(), False)

    def test_file_bounds_symlink_and_multiple_documents_refused(self):
        original = self.trust.read_bytes()
        self.trust.write_bytes(original + b'{}')
        self.document['trusted_root'].update(sha256=digest(self.trust), bytes=self.trust.stat().st_size)
        self.save_receipt(); self.deploy(self.offline_args(), False)
        self.trust.write_bytes(b'x' * 1048577)
        self.deploy(self.offline_args(), False)
        self.trust.unlink(); self.trust.symlink_to(self.key)
        self.deploy(self.offline_args(), False)
        self.trust.unlink(); self.trust.write_bytes(original)
        self.receipt.write_bytes(b' ' * 65537)
        self.pin = digest(self.receipt); self.deploy(self.offline_args(), False)
        self.save_receipt(); self.receipt.write_bytes(self.receipt.read_bytes() + b'{}')
        self.pin = digest(self.receipt); self.deploy(self.offline_args(), False)

    def test_exact_verifier_arguments_and_all_images_before_next_phase(self):
        log = self.root / 'cosign.args'
        stub = 'cosign() { printf "%s\\n" "$@" >> ' + shlex.quote(str(log)) + '; printf "END\\n" >> ' + shlex.quote(str(log)) + '; }\n'
        default = ['verify_worker_images', str(self.key), '', '', '', MEDIA, VERIFIER]
        self.run_shell(self.helper() + stub + shlex.join(default))
        self.assertEqual(log.read_text().splitlines(), ['verify','--key',str(self.key),MEDIA,'END','verify','--key',str(self.key),VERIFIER,'END'])
        log.unlink()
        args = ['verify_worker_images', str(self.key), str(self.trust), str(self.receipt), self.pin, MEDIA, VERIFIER, CLASSIFIER]
        self.run_shell(self.helper() + stub + shlex.join(args))
        expected = []
        for image in (MEDIA, VERIFIER, CLASSIFIER):
            expected += ['verify','--offline','--new-bundle-format=false','--trusted-root',str(self.trust),'--key',str(self.key),'--check-claims=true',image,'END']
        self.assertEqual(log.read_text().splitlines(), expected)
        log.unlink()
        failure = stub.replace('; }', f'; [[ "${{!#}}" != {shlex.quote(VERIFIER)} ]]; }}')
        sentinel = self.root / 'pull-or-activation'
        self.run_shell(self.helper() + failure + shlex.join(args) + '\ntouch ' + shlex.quote(str(sentinel)), False)
        self.assertFalse(sentinel.exists())
        self.assertNotIn(CLASSIFIER, log.read_text())

    def test_validation_repeated_after_cosign_and_expired_history_readable(self):
        args = ['verify_worker_images', str(self.key), str(self.trust), str(self.receipt), self.pin, MEDIA, VERIFIER]
        # Mutating pinned input during the external verifier cannot proceed.
        stub = 'cosign() { printf " " >> ' + shlex.quote(str(self.receipt)) + '; }\n'
        self.run_shell(self.helper() + stub + shlex.join(args), False)
        self.document.update(verified_at='2000-01-01T00:00:00Z', freshness_valid_before='2000-01-02T00:00:00Z')
        self.save_receipt()
        self.run_shell(self.helper() + self.validate('historical'))
        self.run_shell(self.helper() + self.validate(), False)

    def snapshot_harness(self):
        # Exercise the real capture/stage/install/manifest functions in a private
        # fixture tree. Only Linux root ownership and GNU install/mv conventions
        # are adapted; this is not evidence of host ownership or service recovery.
        code = (REPO / 'deploy/worker/releases.sh').read_text()
        paths = ('/opt/wali-worker', '/etc/wali-worker', '/etc/systemd/system', '/usr/local/sbin', '/usr/share/doc/wali-worker')
        for path in paths:
            self.assertIn(path, code)
            code = code.replace(path, str(self.root / 'host' / path.lstrip('/')))
        copy = self.root / 'releases-fixture.sh'; copy.write_text(code)
        base = self.root / 'host/opt/wali-worker'; (base / 'releases').mkdir(parents=True)
        prefix = self.helper() + f'FIXTURE={shlex.quote(str(self.root))}\nSCRIPT_ROOT={shlex.quote(str(REPO / "deploy/worker"))}\n'
        prefix += '''
inside() { case "$1" in "$FIXTURE"/*) ;; *) echo 'outside fixture' >&2; exit 99 ;; esac; }
stat() { [[ "$1" == -c && "$2" == %u ]]; inside "$3"; printf '0\\n'; }
chown() { inside "${!#}"; }
install() {
  local args=()
  while (($#)); do case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac; done
  inside "${args[${#args[@]}-1]}"
  command install "${args[@]}"
}
mv() {
  local args=()
  while (($#)); do case "$1" in -T) shift ;; -Tf) args+=(-f); shift ;; *) args+=("$1"); shift ;; esac; done
  inside "${args[${#args[@]}-1]}"
  [[ ! -L "${args[${#args[@]}-1]}" ]] || rm -- "${args[${#args[@]}-1]}"
  command mv "${args[@]}"
}
read_env_value() { sed -n "s/^$1=//p" "$2"; }
read_optional_env_value() { read_env_value "$@"; }
validate_file() { [[ -f "$1" && ! -L "$1" && -s "$1" ]]; }
validate_target_binding() { [[ "$1" == staging && "$2" == abcdefghijklmnopqrst ]]; }
'''
        prefix += f'source {shlex.quote(str(copy))}\n'
        prefix += '''
safe_tree() { inside "$1"; [[ -d "$1" && ! -L "$1" && -z "$(find "$1" -type l -print -quit)" ]]; }
worker_binary="$FIXTURE/worker"; environment_file="$FIXTURE/environment"; cosign_key="$FIXTURE/publisher.pub"
database_ca=
media_sbom="$FIXTURE/media.spdx"; verifier_sbom="$FIXTURE/verifier.spdx"; classifier_sbom="$FIXTURE/classifier.spdx"
offline_trust_root="$FIXTURE/root.json"; offline_trust_receipt="$FIXTURE/receipt.json"
'''
        prefix += shlex.join(['printf', '%s\n', self.pin]) + ' > "$FIXTURE/pin"\n'
        prefix += f'offline_trust_receipt_sha256={shlex.quote(self.pin)}\nmedia_image={shlex.quote(MEDIA)}\nverifier_image={shlex.quote(VERIFIER)}\nclassifier_image=\n'
        return prefix

    def test_database_ca_snapshot_capture_replacement_and_restore(self):
        self.database_ca(snapshot=True)
        self.run_shell(self.snapshot_harness() + '''
database_ca="$FIXTURE/database-ca.crt"
stage_release; original="$staged_release"; validate_release "$original"
grep -q 'payload/database-ca$' "$RELEASE_BASE/$original/manifest.sha256"
install_snapshot "$original"; set_release_link current "$original"
capture_baseline; [[ "$staged_release" == "$original" ]]
printf '\n' >> "$database_ca"
stage_release; replacement="$staged_release"; [[ "$replacement" != "$original" ]]
install_snapshot "$replacement"
cmp "$database_ca" "${release_paths[11]}"
rm "$database_ca"
chmod u+w "${release_paths[11]}"; printf damaged > "${release_paths[11]}"
install_snapshot "$original"
cmp "$RELEASE_BASE/$original/payload/database-ca" "${release_paths[11]}"
cmp "$RELEASE_BASE/$original/payload/environment" "${release_paths[0]}"
''')
        self.assertEqual((self.root / 'host/etc/wali-worker/database-ca.crt').stat().st_mode & 0o777, 0o444)

    def test_database_ca_legacy_snapshot_removes_newer_ca(self):
        self.database_ca(snapshot=True)
        self.run_shell(self.snapshot_harness() + '''
database_ca="$FIXTURE/database-ca.crt"
stage_release; original="$staged_release"; install_snapshot "$original"
sed '/^PGSSLROOTCERT=/d' "$environment_file" > "$FIXTURE/legacy.env"
environment_file="$FIXTURE/legacy.env"; database_ca=
stage_release; without_ca="$staged_release"
root=$(mktemp -d "$RELEASE_BASE/.legacy.XXXXXX")
cp -R "$RELEASE_BASE/$without_ca/." "$root/"; chmod -R u+w "$root"
rm "$root/manifest.sha256" "$root/payload/database-ca.absent"
finish_snapshot "$root"; legacy="$staged_release"
before=$(file_digest "$RELEASE_BASE/$legacy/manifest.sha256")
install_snapshot "$legacy"
[[ ! -e "${release_paths[11]}" ]]
[[ "$before" == "$(file_digest "$RELEASE_BASE/$legacy/manifest.sha256")" ]]
cmp "$environment_file" "${release_paths[0]}"
install_snapshot "$original"; install_snapshot "$without_ca"
[[ ! -e "${release_paths[11]}" ]]
''')

    def test_database_ca_partial_rehashed_snapshot_refuses_before_install(self):
        self.database_ca(snapshot=True)
        self.run_shell(self.snapshot_harness() + '''
database_ca="$FIXTURE/database-ca.crt"
stage_release; original="$staged_release"; install_snapshot "$original"
for malformed in missing ambiguous disabled; do
  root=$(mktemp -d "$RELEASE_BASE/.malformed.XXXXXX")
  cp -R "$RELEASE_BASE/$original/." "$root/"; chmod -R u+w "$root"
  case "$malformed" in
    missing) rm "$root/payload/database-ca" ;;
    ambiguous) touch "$root/payload/database-ca.absent" ;;
    disabled) sed '/^PGSSLROOTCERT=/d' "$root/payload/environment" > "$FIXTURE/disabled.env"; cp "$FIXTURE/disabled.env" "$root/payload/environment" ;;
  esac
  manifest "$root" > "$root/manifest.sha256"
  target="releases/$(file_digest "$root/manifest.sha256")"; mv -T "$root" "$RELEASE_BASE/$target"
  if (install_snapshot "$target") >/dev/null 2>&1; then exit 1; fi
  cmp "${release_paths[11]}" "$RELEASE_BASE/$original/payload/database-ca"
  cmp "${release_paths[0]}" "$RELEASE_BASE/$original/payload/environment"
done
rm "${release_paths[11]}"
if (capture_baseline) >/dev/null 2>&1; then exit 1; fi
''')

    def test_database_ca_installed_verifier_binding(self):
        self.database_ca(snapshot=True)
        prefix = self.snapshot_harness()
        # Source only the real verifier definitions, then invoke its CA check.
        # Linux ownership is simulated; file contents, modes and symlinks are real.
        verify = (REPO / 'deploy/worker/verify.sh').read_text().split('[[ "$(id -u)" == 0 ]]')[0]
        for path in ('/opt/wali-worker', '/etc/wali-worker'):
            verify = verify.replace(path, str(self.root / 'host' / path.lstrip('/')))
        copy = self.root / 'verify-fixture.sh'; copy.write_text(verify)
        prefix += 'database_ca="$FIXTURE/database-ca.crt"\nstage_release; original="$staged_release"\ninstall_snapshot "$original"; set_release_link current "$original"\n'
        prefix += f'source {shlex.quote(str(copy))}\n'
        prefix += '''
stat() {
  [[ "$1" == -c && "$2" == %U:%G:%a ]]; inside "$3"
  local mode
  mode=$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$3")
  printf 'root:root:%s\n' "$mode"
}
verify_database_ca
chmod u+w "${release_paths[11]}"
if (verify_database_ca) >/dev/null 2>&1; then exit 1; fi
printf damaged > "${release_paths[11]}"; chmod 0444 "${release_paths[11]}"
if (verify_database_ca) >/dev/null 2>&1; then exit 1; fi
rm "${release_paths[11]}"
if (verify_database_ca) >/dev/null 2>&1; then exit 1; fi
cp "$database_ca" "$FIXTURE/replacement.crt"
ln -s "$FIXTURE/replacement.crt" "${release_paths[11]}"
if (verify_database_ca) >/dev/null 2>&1; then exit 1; fi
rm "${release_paths[11]}"; cp "$database_ca" "${release_paths[11]}"; chmod 0444 "${release_paths[11]}"
verify_database_ca
printf ' PGSSLROOTCERT=/tmp/unmanaged.crt\n' >> "${release_paths[0]}"
if (verify_database_ca) >/dev/null 2>&1; then exit 1; fi
'''
        self.run_shell(prefix)

    def test_snapshot_capture_restore_and_default_identity(self):
        self.run_shell(self.snapshot_harness() + '''
stage_release; original="$staged_release"; validate_release "$original"
for key in cosign-trust-root cosign-trust-receipt cosign-trust-receipt-digest; do grep -q "payload/$key$" "$RELEASE_BASE/$original/manifest.sha256"; done
install_snapshot "$original"; set_release_link current "$original"
capture_baseline; [[ "$staged_release" == "$original" ]]
rm -- "$offline_trust_root" "$offline_trust_receipt"
chmod u+w "${release_paths[8]}"
printf damaged > "${release_paths[8]}"
install_snapshot "$original"
cmp "$RELEASE_BASE/$original/payload/cosign-trust-root" "${release_paths[8]}"
cmp "$RELEASE_BASE/$original/payload/cosign-trust-receipt" "${release_paths[9]}"
cmp "$RELEASE_BASE/$original/payload/cosign-trust-receipt-digest" "${release_paths[10]}"
offline_trust_root=; offline_trust_receipt=; offline_trust_receipt_sha256=
stage_release; default="$staged_release"; [[ "$default" != "$original" ]]
install_snapshot "$default"; set_release_link current "$default"
for index in 8 9 10; do [[ ! -e "${release_paths[$index]}" ]]; done
capture_baseline; [[ "$staged_release" == "$default" ]]
''')

    def test_legacy_snapshot_restores_absence_without_rewriting_history(self):
        self.run_shell(self.snapshot_harness() + '''
stage_release; original="$staged_release"; install_snapshot "$original"
root=$(mktemp -d "$RELEASE_BASE/.legacy.XXXXXX")
cp -R "$RELEASE_BASE/$original/." "$root/"
chmod -R u+w "$root"
rm "$root/manifest.sha256" "$root/payload/cosign-trust-root" "$root/payload/cosign-trust-receipt" "$root/payload/cosign-trust-receipt-digest"
finish_snapshot "$root"; legacy="$staged_release"
before=$(file_digest "$RELEASE_BASE/$legacy/manifest.sha256")
validate_release "$legacy"; install_snapshot "$legacy"
[[ "$before" == "$(file_digest "$RELEASE_BASE/$legacy/manifest.sha256")" ]]
for index in 8 9 10; do [[ ! -e "${release_paths[$index]}" ]]; done
''')

    def test_partial_rehashed_snapshots_and_capture_refuse_before_install(self):
        self.run_shell(self.snapshot_harness() + '''
stage_release; original="$staged_release"; install_snapshot "$original"
for mask in 1 2 3 4 5 6; do
  root=$(mktemp -d "$RELEASE_BASE/.malformed.XXXXXX")
  cp -R "$RELEASE_BASE/$original/." "$root/"; chmod -R u+w "$root"
  for index in 0 1 2; do
    keys=(cosign-trust-root cosign-trust-receipt cosign-trust-receipt-digest)
    if (( (mask & (1 << index)) == 0 )); then rm "$root/payload/${keys[$index]}"; fi
  done
  manifest "$root" > "$root/manifest.sha256"
  target="releases/$(file_digest "$root/manifest.sha256")"; mv -T "$root" "$RELEASE_BASE/$target"
  if (install_snapshot "$target") >/dev/null 2>&1; then exit 1; fi
  cmp "${release_paths[8]}" "$RELEASE_BASE/$original/payload/cosign-trust-root"
done
touch "$RELEASE_BASE/$original/payload/cosign-trust-root.absent"
if (validate_release "$original") >/dev/null 2>&1; then exit 1; fi
if snapshot_offline_trust "$RELEASE_BASE/$original/payload" >/dev/null 2>&1; then exit 1; fi
rm "${release_paths[9]}"
if (capture_baseline) >/dev/null 2>&1; then exit 1; fi
''')

    def test_expired_snapshot_cannot_enter_activation_or_rollback_verification(self):
        self.document.update(verified_at='2000-01-01T00:00:00Z', freshness_valid_before='2000-01-02T00:00:00Z')
        self.save_receipt()
        self.run_shell(self.snapshot_harness() + '''
stage_release; target="$staged_release"; validate_release "$target"
begin_transaction() { touch "$FIXTURE/activation"; exit 99; }
if (activate_release "$target" "$target") >/dev/null 2>&1; then exit 1; fi
[[ ! -e "$FIXTURE/activation" ]]
if verify_rollback_offline_images "$RELEASE_BASE/$target/payload" >/dev/null 2>&1; then exit 1; fi
''')

unittest.main(argv=[sys.argv[0]] + sys.argv[2:])
PY
