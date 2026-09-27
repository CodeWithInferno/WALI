#!/usr/bin/env python3
"""Hostless release fixtures; no Linux capabilities, services or user identities are changed."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
NAMESPACE_PATH = "/usr/libexec/wali-worker/idmap:/usr/sbin:/usr/bin:/sbin:/bin"


class ReleaseIntegrationTests(unittest.TestCase):
    def test_namespace_uses_private_helpers_without_widening_authority(self):
        unit = (REPO / "deploy/worker/wali-podman-namespace.service").read_text()
        self.assertIn("Environment=PATH=" + NAMESPACE_PATH + "\n", unit)
        self.assertIn("ExecStart=/usr/bin/podman unshare /bin/true\n", unit)
        self.assertIn("CapabilityBoundingSet=CAP_SETUID CAP_SETGID\n", unit)
        self.assertIn("AmbientCapabilities=\nNoNewPrivileges=no\n", unit)
        worker = (REPO / "deploy/worker/wali-media-worker.service").read_text()
        self.assertNotIn("Environment=PATH=", worker)
        self.assertIn("NoNewPrivileges=yes\n", worker)
        self.assertIn("CapabilityBoundingSet=\n", worker)

    def test_warm_deploy_refuses_helper_changes_before_service_operations(self):
        for name in ("idmap-support", "idmap-helpers/manifest.json", "idmap-helpers/newuidmap", "idmap-helpers/newgidmap"):
            with self.subTest(file=name), tempfile.TemporaryDirectory(prefix="wali-idmap-warm-") as temporary:
                root = Path(temporary)
                for release in ("target", "baseline"):
                    payload = root / release / "payload"
                    (payload / "idmap-helpers").mkdir(parents=True)
                    for part in ("namespace-unit", "storage", "idmap-support", "idmap-helpers/manifest.json", "idmap-helpers/newuidmap", "idmap-helpers/newgidmap"):
                        (payload / part).write_text("same")
                (root / "target/payload" / name).write_text("different")
                source = (REPO / "deploy/worker/releases.sh").read_text().replace("/opt/wali-worker", str(root))
                fixture = root / "releases.sh"
                fixture.write_text(source)
                script = f"""set -Eeuo pipefail
source {shlex.quote(str(fixture))}
systemctl() {{ touch {shlex.quote(str(root / 'service-command'))}; return 99; }}
warm_namespace_mode=true
validate_warm_release target baseline
"""
                result = subprocess.run(["bash", "-c", script], text=True, capture_output=True)
                self.assertEqual(result.returncode, 65, result.stderr)
                self.assertIn("cannot change private ID helpers", result.stderr)
                self.assertFalse((root / "service-command").exists())

    def test_failed_start_restores_helper_snapshot_and_clears_transaction(self):
        with tempfile.TemporaryDirectory(prefix="wali-idmap-rollback-") as temporary:
            root = Path(temporary)
            base = root / "release-root"
            original, replacement = "releases/" + "a" * 64, "releases/" + "b" * 64
            for release, value in ((original, "old"), (replacement, "new")):
                payload = base / release / "payload"
                payload.mkdir(parents=True)
                (payload / "namespace-unit").write_text(value)
                (payload / "idmap.fixture").write_text(value)
                (base / release / "wali-media-worker").write_text("fixture")
            base.joinpath("current").symlink_to(original)
            (root / "installed-helper").write_text("old")
            (root / "namespace-unit").write_text("old")
            verifier = root / "verifier"
            verifier.write_text("#!/bin/sh\nexit 0\n")
            verifier.chmod(0o700)
            source = (REPO / "deploy/worker/releases.sh").read_text()
            source = source.replace("/opt/wali-worker", str(base)).replace("/usr/share/doc/wali-worker/sbom", str(root / "sbom"))
            source = source.replace("/usr/local/sbin/wali-worker-verify", str(verifier)).replace("/etc/wali-worker", str(root / "etc"))
            fixture = root / "releases.sh"
            fixture.write_text(source)
            script = f"""set -Eeuo pipefail
FIXTURE={shlex.quote(str(root))}
source {shlex.quote(str(fixture))}
release_keys=(namespace-unit)
release_paths=("$FIXTURE/namespace-unit")
release_modes=(0644)
validate_release() {{ [[ -d "$RELEASE_BASE/$1/payload" ]]; }}
validate_file() {{ [[ -f "$1" ]]; }}
safe_tree() {{ [[ -d "$1" ]]; }}
snapshot_offline_trust() {{ :; }}
install() {{
 local args=()
 while (($#)); do case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac; done
 command install "${{args[@]}}"
}}
mv() {{
 local args=()
 while (($#)); do case "$1" in -T) shift ;; -Tf) args+=(-f); shift ;; *) args+=("$1"); shift ;; esac; done
 [[ ! -L "${{args[${{#args[@]}}-1]}}" ]] || rm -- "${{args[${{#args[@]}}-1]}}"
 command mv "${{args[@]}}"
}}
sync() {{ :; }}
idmap_helpers() {{
 case "$1" in
  validate-install) : ;;
  install) cp "$2/idmap.fixture" "$FIXTURE/installed-helper" ;;
  verify-installed) cmp -s "$2/idmap.fixture" "$FIXTURE/installed-helper" ;;
  *) return 99 ;;
 esac
}}
systemctl() {{
 case "$1" in
  is-enabled) printf 'enabled\n' ;;
  start) [[ "$(cat "$FIXTURE/installed-helper")" != new ]] ;;
  cat|is-active|stop|enable|disable|daemon-reload) : ;;
  *) return 99 ;;
 esac
}}
activate_release {replacement} {original}
"""
            result = subprocess.run(["bash", "-c", script], text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("restoring the complete prior WALI deployment", result.stderr)
            self.assertNotIn("recovery failed", result.stderr)
            self.assertEqual((root / "installed-helper").read_text(), "old")
            self.assertEqual((root / "namespace-unit").read_text(), "old")
            self.assertEqual(os.readlink(base / "current"), original)
            self.assertFalse((base / ".transaction").exists())

    def test_complete_snapshot_binds_the_managed_helper_payload(self):
        with tempfile.TemporaryDirectory(prefix="wali-idmap-release-") as temporary:
            root = Path(temporary)
            base = root / "releases-root"
            (base / "releases").mkdir(parents=True)
            source = (REPO / "deploy/worker/releases.sh").read_text()
            source = source.replace("/opt/wali-worker", str(base))
            fixture = root / "releases.sh"
            fixture.write_text(source)
            for name in ("worker", "environment", "cosign", "media", "verifier"):
                (root / name).write_text("fixture\n")
            script = f"""set -Eeuo pipefail
SCRIPT_ROOT={shlex.quote(str(REPO / 'deploy/worker'))}
FIXTURE={shlex.quote(str(root))}
source {shlex.quote(str(fixture))}
file_digest() {{ shasum -a 256 "$1" | cut -d' ' -f1; }}
snapshot_offline_trust() {{ :; }}
validate_database_ca() {{ :; }}
idmap_helpers() {{
  case "$1" in
    stage)
      mkdir -p "$2/idmap-helpers"
      printf fixture > "$2/idmap-helpers/newuidmap"
      printf fixture > "$2/idmap-helpers/newgidmap"
      printf '{{"version":1}}' > "$2/idmap-helpers/manifest.json" ;;
    validate-snapshot) : ;;
    *) return 98 ;;
  esac
}}
mv() {{
  local args=()
  while (($#)); do case "$1" in -T) shift ;; *) args+=("$1"); shift ;; esac; done
  command mv "${{args[@]}}"
}}
worker_binary="$FIXTURE/worker"; environment_file="$FIXTURE/environment"; cosign_key="$FIXTURE/cosign"
media_sbom="$FIXTURE/media"; verifier_sbom="$FIXTURE/verifier"
media_image="fixture@sha256:aaa"; verifier_image="fixture@sha256:bbb"; classifier_image=
database_ca=; offline_trust_root=
stage_release
printf '%s' "$staged_release" > "$FIXTURE/result"
"""
            result = subprocess.run(["bash", "-c", script], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            snapshot = base / (root / "result").read_text()
            manifest = (snapshot / "manifest.sha256").read_text()
            self.assertIn("./payload/idmap-helpers/manifest.json", manifest)
            self.assertIn("./payload/idmap-helpers/newuidmap", manifest)
            self.assertIn("./payload/idmap-helpers/newgidmap", manifest)
            for helper in ("newuidmap", "newgidmap"):
                self.assertEqual((snapshot / "payload/idmap-helpers" / helper).stat().st_mode & 0o7777, 0o400)


class HelperFixtures(unittest.TestCase):
    def setUp(self):
        support = REPO / "deploy/worker/idmap-helpers.py"
        self.assertTrue(support.exists(), "Private helper management is not implemented")
        spec = importlib.util.spec_from_file_location("idmap_support", support)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.temporary = tempfile.TemporaryDirectory(prefix="wali-idmap-files-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "usr/bin"
        self.parent = self.root / "usr/libexec/wali-worker"
        self.installed = self.parent / "idmap"
        self.source.mkdir(parents=True)
        self.mode = {}
        for name in ("newuidmap", "newgidmap"):
            (self.source / name).write_bytes(b"\x7fELFsynthetic-host-package-" + name.encode())
            # Model the OS package's setuid bit without creating privileged files.
            (self.source / name).chmod(0o755)
            self.mode[(self.source / name).stat().st_ino] = 0o104755
        self.owner = {}
        self.caps = {}
        self.commands = []
        self.counter = 0
        self.version = "1:4.13-fixture"
        self.patch("SOURCE_DIRECTORY", self.source)
        self.patch("MANAGED_DIRECTORY", self.installed)
        self.patch("SUPPORT_PATH", self.parent / "idmap-helpers.py")
        self.patch("SYSTEM_PATH_DIRECTORIES", (self.source,))
        self.patch("worker_gid", lambda: 2000)
        self.patch("metadata", self.metadata)
        self.patch("run", self.run_command)
        self.patch("change_owner", self.change_owner)

    def patch(self, name, value):
        patcher = mock.patch.object(self.module, name, value)
        patcher.start()
        self.addCleanup(patcher.stop)

    def metadata(self, path):
        path = Path(path)
        observed = path.lstat()
        fields = list(observed)
        fields[0] = self.mode.get(observed.st_ino, observed.st_mode)
        fields[4], fields[5] = self.owner.get(observed.st_ino, (0, 0))
        # Model a dedicated Linux root; real fixture file bytes/modes/symlinks are tested below.
        if path != self.root and self.root not in path.parents:
            fields[0] = 0o40755
        return os.stat_result(fields)

    def change_owner(self, path, uid, gid):
        self.owner[Path(path).lstat().st_ino] = (uid, gid)

    def run_command(self, arguments):
        self.commands.append(arguments)
        command = Path(arguments[0]).name
        if command == "getcap":
            path = Path(arguments[-1])
            cap = self.caps.get(path.lstat().st_ino, "")
            return f"{path} {cap}\n" if cap else ""
        if command == "setcap":
            path = Path(arguments[-1])
            info = self.metadata(path)
            self.assertEqual((info.st_uid, info.st_gid, info.st_mode & 0o7777), (0, 2000, 0o550))
            self.caps[path.lstat().st_ino] = arguments[1]
            return ""
        if command == "dpkg-query":
            if arguments[1] == "-S":
                return f"uidmap: {arguments[-1]}\n"
            return f"uidmap\n{self.version}\n"
        self.fail(f"Unexpected host command in fixture: {arguments[0]}")

    def payload(self, private=True):
        self.counter += 1
        payload = self.root / f"payload-{self.counter}"
        payload.mkdir(mode=0o700)
        (payload / "namespace-unit").write_text("Environment=PATH=" + NAMESPACE_PATH + "\n" if private else "legacy unit\n")
        (payload / "namespace-unit").chmod(0o400)
        if private:
            (payload / "idmap-support").write_text("synthetic helper support\n")
            (payload / "idmap-support").chmod(0o400)
        return payload

    def stage(self):
        payload = self.payload()
        self.module.stage(payload)
        return payload

    def install(self, payload):
        # The outer release transaction installs/removes the support file first.
        support = self.module.SUPPORT_PATH
        self.parent.mkdir(parents=True, exist_ok=True)
        if (payload / "idmap-support").exists():
            if support.exists(): support.chmod(0o600)
            support.write_bytes((payload / "idmap-support").read_bytes())
            support.chmod(0o555)
        elif support.exists(): support.unlink()
        self.module.install(payload)

    def test_stage_binds_host_bytes_package_and_exact_privileges(self):
        payload = self.stage()
        records = self.module.validate_snapshot(payload)
        self.assertEqual(len(records), 2)
        for record, capability in zip(records, ("cap_setuid=ep", "cap_setgid=ep")):
            source = self.source / record["name"]
            captured = payload / "idmap-helpers" / record["name"]
            self.assertEqual(record["sha256"], hashlib.sha256(source.read_bytes()).hexdigest())
            self.assertEqual(record["source_package"], "uidmap")
            self.assertEqual(record["source_version"], self.version)
            self.assertEqual(record["capabilities"], capability)
            self.assertEqual(record["mode"], "0550")
            self.assertEqual(captured.stat().st_mode & 0o7777, 0o400)
            self.assertEqual(self.caps.get(captured.stat().st_ino, ""), "")
            self.assertEqual(source.stat().st_mode & 0o7777, 0o755)

    def test_install_and_capture_preserve_exact_snapshot_without_source_recapture(self):
        payload = self.stage()
        self.install(payload)
        self.module.verify_installed(payload)
        for name in ("newuidmap", "newgidmap"):
            self.assertEqual((self.installed / name).stat().st_mode & 0o7777, 0o550)
        self.version = "1:4.14-fixture"
        (self.source / "newuidmap").write_bytes(b"\x7fELFupdated-package")
        captured = self.payload()
        self.module.capture(captured, payload)
        self.assertEqual((captured / "idmap-helpers/manifest.json").read_bytes(),
                         (payload / "idmap-helpers/manifest.json").read_bytes())
        self.module.validate_snapshot(captured)

    def test_installed_tampering_is_rejected(self):
        for change in ("bytes", "owner", "group", "mode", "setuid", "capability", "missing", "symlink"):
            with self.subTest(change=change):
                payload = self.stage()
                self.install(payload)
                target = self.installed / "newuidmap"
                inode = target.lstat().st_ino
                if change == "bytes":
                    target.chmod(0o750); target.write_bytes(b"tampered"); target.chmod(0o550)
                elif change == "owner": self.owner[inode] = (2000, 2000)
                elif change == "group": self.owner[inode] = (0, 0)
                elif change == "mode": target.chmod(0o750)
                elif change == "setuid": self.mode[inode] = 0o104550
                elif change == "capability": self.caps[inode] = "cap_setuid,cap_dac_override=ep"
                elif change == "missing": target.unlink()
                elif change == "symlink": target.unlink(); target.symlink_to(self.source / "newuidmap")
                with self.assertRaises((self.module.UnsafeHelpers, OSError)): self.module.verify_installed(payload)
                # Restore only this test-owned fixture; production refuses unsafe trees.
                for child in self.installed.iterdir(): child.unlink()
                self.installed.rmdir()
                self.owner.clear(); self.caps.clear(); self.mode.pop(inode, None)

    def test_rehashed_snapshot_cannot_change_mode_capability_or_paths(self):
        for field, value in (("capabilities", "cap_sys_admin=ep"), ("mode", "4755"),
                             ("owner", "wali-worker"), ("installed_path", "/usr/bin/newuidmap"),
                             ("source_package", "unrelated")):
            with self.subTest(field=field):
                payload = self.stage()
                path = payload / "idmap-helpers/manifest.json"
                document = json.loads(path.read_text())
                document["helpers"][0][field] = value
                path.chmod(0o600); path.write_text(json.dumps(document)); path.chmod(0o400)
                with self.assertRaises((self.module.UnsafeHelpers, OSError)): self.module.validate_snapshot(payload)

    def test_snapshot_tampering_missing_files_and_capabilities_are_rejected(self):
        for change in ("bytes", "missing", "extra", "capability", "mode"):
            with self.subTest(change=change):
                payload = self.stage()
                path = payload / "idmap-helpers/newuidmap"
                if change == "bytes": path.chmod(0o600); path.write_bytes(b"tampered"); path.chmod(0o400)
                elif change == "missing": path.unlink()
                elif change == "extra": (path.parent / "extra").touch()
                elif change == "capability": self.caps[path.stat().st_ino] = "cap_setuid=ep"
                elif change == "mode": path.chmod(0o550)
                with self.assertRaises((self.module.UnsafeHelpers, OSError)): self.module.validate_snapshot(payload)

    def test_legacy_and_explicit_absence_restore_only_the_managed_directory(self):
        legacy = self.payload(private=False)
        self.module.capture(legacy, None)
        self.assertTrue((legacy / "idmap-helpers.absent").is_file())
        payload = self.stage()
        self.install(payload)
        sentinel = self.parent / "unrelated"
        sentinel.write_text("preserve")
        self.install(legacy)
        self.assertFalse(self.installed.exists())
        self.assertEqual(sentinel.read_text(), "preserve")
        self.install(payload)
        (legacy / "idmap-helpers.absent").unlink()
        self.install(legacy)
        self.assertFalse(self.installed.exists())
        self.assertEqual((self.source / "newuidmap").stat().st_mode & 0o7777, 0o755)

    def test_private_path_without_snapshot_and_ambiguous_absence_fail(self):
        payload = self.stage()
        self.install(payload)
        with self.assertRaises(self.module.UnsafeHelpers): self.module.capture(self.payload(private=False), None)
        (payload / "idmap-helpers.absent").touch()
        with self.assertRaises((self.module.UnsafeHelpers, OSError)): self.module.validate_snapshot(payload)

    def test_namespace_path_override_is_rejected(self):
        for extra in ("Environment=PATH=/tmp", 'Environment="PATH=/tmp"', 'Environment=OTHER=1 PATH=/tmp'):
            with self.subTest(extra=extra):
                payload = self.stage()
                unit = payload / "namespace-unit"
                unit.chmod(0o600)
                unit.write_text(unit.read_text() + extra + "\n")
                unit.chmod(0o400)
                with self.assertRaises(self.module.UnsafeHelpers): self.module.validate_snapshot(payload)

    def test_setcap_failure_preserves_the_previous_installed_pair(self):
        original = self.stage()
        self.install(original)
        original_bytes = {name: (self.installed / name).read_bytes() for name, _ in self.module.HELPERS}
        (self.source / "newuidmap").write_bytes(b"\x7fELFnext-package")
        replacement = self.stage()
        old_run = self.module.run
        def fail_second_capability(arguments):
            if Path(arguments[0]).name == "setcap" and Path(arguments[-1]).name == "newgidmap":
                raise subprocess.CalledProcessError(1, arguments)
            return old_run(arguments)
        with mock.patch.object(self.module, "run", fail_second_capability):
            with self.assertRaises(subprocess.CalledProcessError): self.install(replacement)
        self.module.verify_installed(original)
        self.assertEqual(original_bytes, {name: (self.installed / name).read_bytes() for name, _ in self.module.HELPERS})
        self.assertEqual(list(self.parent.glob(".idmap-install-*")), [])

    def test_previous_snapshot_restores_bytes_and_capabilities_after_failed_activation(self):
        original = self.stage()
        self.install(original)
        baseline = self.payload()
        self.module.capture(baseline, original)
        (self.source / "newuidmap").write_bytes(b"\x7fELFnext-package")
        replacement = self.stage()
        self.install(replacement)
        self.assertNotEqual((self.installed / "newuidmap").read_bytes(),
                            (baseline / "idmap-helpers/newuidmap").read_bytes())
        # The release transaction chooses its captured baseline on failed activation.
        self.install(baseline)
        self.module.verify_installed(baseline)
        self.assertEqual((self.installed / "newuidmap").read_bytes(),
                         (original / "idmap-helpers/newuidmap").read_bytes())

    def test_support_tampering_missing_and_legacy_ambiguity_fail(self):
        payload = self.stage()
        self.install(payload)
        (payload / "idmap-support.absent").touch()
        with self.assertRaises(self.module.UnsafeHelpers): self.module.validate_snapshot(payload)
        (payload / "idmap-support.absent").unlink()
        support = self.module.SUPPORT_PATH
        support.chmod(0o755)
        with self.assertRaises(self.module.UnsafeHelpers): self.module.verify_installed(payload)
        support.chmod(0o555)
        support.unlink()
        with self.assertRaises((self.module.UnsafeHelpers, OSError)): self.module.verify_installed(payload)
        (payload / "idmap-support").unlink()
        with self.assertRaises((self.module.UnsafeHelpers, OSError)): self.module.validate_snapshot(payload)
        legacy = self.payload(private=False)
        (legacy / "idmap-support").write_text("unexpected support")
        with self.assertRaises(self.module.UnsafeHelpers): self.module.validate_snapshot(legacy)

    def test_absent_rollback_refuses_symlinks_and_unmanaged_files(self):
        legacy = self.payload(private=False)
        self.parent.mkdir(parents=True)
        self.installed.symlink_to(self.source)
        with self.assertRaises(self.module.UnsafeHelpers): self.install(legacy)
        self.installed.unlink()
        payload = self.stage()
        self.install(payload)
        (self.installed / "unmanaged").touch()
        with self.assertRaises(self.module.UnsafeHelpers): self.install(legacy)
        self.assertTrue((self.installed / "unmanaged").exists())


if __name__ == "__main__":
    unittest.main()
