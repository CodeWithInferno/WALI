#!/usr/bin/env python3
"""Manage only WALI's private, snapshot-bound subordinate-ID helpers (ADR 0024)."""
import grp
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

SOURCE_DIRECTORY = Path("/usr/bin")
MANAGED_DIRECTORY = Path("/usr/libexec/wali-worker/idmap")
SYSTEM_PATH_DIRECTORIES = tuple(map(Path, ("/usr/sbin", "/usr/bin", "/sbin", "/bin")))
NAMESPACE_PATH = "/usr/libexec/wali-worker/idmap:/usr/sbin:/usr/bin:/sbin:/bin"
HELPERS = (("newuidmap", "cap_setuid=ep"), ("newgidmap", "cap_setgid=ep"))
MAXIMUM_BINARY_BYTES = 4 * 1024 * 1024


class UnsafeHelpers(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise UnsafeHelpers(message)


def metadata(path):
    return path.lstat()


def change_owner(path, uid, gid):
    os.chown(path, uid, gid, follow_symlinks=False)


def worker_gid():
    return grp.getgrnam("wali-worker").gr_gid


def run(arguments):
    return subprocess.run(arguments, check=True, capture_output=True, text=True, timeout=10,
                          env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C"}).stdout


def capabilities(path):
    output = run(["/usr/sbin/getcap", "-n", str(path)]).strip()
    if not output:
        return ""
    prefix = str(path) + " "
    require(output.startswith(prefix) and "\n" not in output, "invalid file capability response")
    return output[len(prefix):]


def trusted_parents(path):
    for directory in reversed((path, *path.parents)):
        if not directory.exists() and not directory.is_symlink():
            continue
        info = metadata(directory)
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022,
                "private helper path has an unsafe parent directory")


def trusted_system_path():
    # /bin and /sbin may be root-owned usr-merge symlinks. Their targets and all
    # target parents must still be protected root-owned directories.
    for directory in SYSTEM_PATH_DIRECTORIES:
        info = metadata(directory)
        require(info.st_uid == 0, "system PATH directory is not root-owned")
        resolved = directory.resolve(strict=True)
        trusted_parents(resolved)


def read_file(path, maximum, owner=0, group=0, mode=None, capability=""):
    info = metadata(path)
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == owner
            and info.st_gid == group and 0 < info.st_size <= maximum,
            "helper file type, ownership, link count or size is invalid")
    if mode is not None:
        require(stat.S_IMODE(info.st_mode) == mode, "helper file mode is invalid")
    require(capabilities(path) == capability, "helper file capabilities differ from the exact policy")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        opened = os.fstat(descriptor)
        require((opened.st_dev, opened.st_ino, opened.st_size) == (info.st_dev, info.st_ino, info.st_size),
                "helper file changed while opening")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            data = stream.read(maximum + 1)
        require(len(data) == info.st_size, "helper file changed while reading")
        return data
    finally:
        os.close(descriptor)


def write_snapshot_file(path, data):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o400)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    path.chmod(0o400)


def strict_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate helper manifest field")
        result[key] = value
    return result


def namespace_binding(payload, present):
    unit = payload / "namespace-unit"
    if not unit.exists():
        require(not present, "private helpers require their namespace unit")
        return
    text = read_file(unit, 65536, mode=0o400).decode("utf-8")
    lines = text.splitlines()
    scoped = "Environment=PATH=" + NAMESPACE_PATH
    require((lines.count(scoped) == 1) if present else (NAMESPACE_PATH not in text),
            "namespace PATH and private helper snapshot disagree")


def validate_snapshot(payload):
    trusted_parents(payload)
    directory = payload / "idmap-helpers"
    absent = payload / "idmap-helpers.absent"
    if not directory.exists() and not directory.is_symlink():
        if absent.exists() or absent.is_symlink():
            info = metadata(absent)
            require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and info.st_gid == 0
                    and info.st_size == 0 and not info.st_mode & 0o022 and capabilities(absent) == "",
                    "invalid helper absence marker")
        namespace_binding(payload, False)
        return None
    require(not absent.exists() and not absent.is_symlink(), "ambiguous private helper snapshot")
    trusted_parents(directory)
    require({item.name for item in directory.iterdir()} == {"manifest.json", "newuidmap", "newgidmap"},
            "incomplete or unexpected private helper payload")
    manifest_bytes = read_file(directory / "manifest.json", 16384, mode=0o400)
    document = json.loads(manifest_bytes, object_pairs_hook=strict_object)
    require(type(document) is dict and set(document) == {"version", "helpers"}
            and type(document["version"]) is int and document["version"] == 1
            and type(document["helpers"]) is list and len(document["helpers"]) == 2,
            "unsupported private helper manifest")
    fields = {"name", "source_path", "source_package", "source_version", "sha256", "byte_count",
              "installed_path", "owner", "group", "mode", "capabilities"}
    for record, (name, capability) in zip(document["helpers"], HELPERS):
        require(type(record) is dict and set(record) == fields, "invalid helper manifest fields")
        require(record["name"] == name and record["source_path"] == str(SOURCE_DIRECTORY / name)
                and record["installed_path"] == str(MANAGED_DIRECTORY / name)
                and record["owner"] == "root" and record["group"] == "wali-worker"
                and record["mode"] == "0550" and record["capabilities"] == capability,
                "helper manifest changes a fixed authority boundary")
        require(type(record["source_package"]) is str
                and re.fullmatch(r"uidmap(?::[a-z0-9]+)?", record["source_package"])
                and type(record["source_version"]) is str
                and re.fullmatch(r"[A-Za-z0-9.+:~_-]{1,128}", record["source_version"]),
                "invalid helper source package provenance")
        data = read_file(directory / name, MAXIMUM_BINARY_BYTES, mode=0o400)
        require(data.startswith(b"\x7fELF") and type(record["byte_count"]) is int
                and record["byte_count"] == len(data) and record["sha256"] == hashlib.sha256(data).hexdigest(),
                "private helper bytes differ from their manifest")
    namespace_binding(payload, True)
    read_file(payload / "idmap-support", 262144, mode=0o400)
    return document["helpers"]


def stage(payload):
    trusted_parents(payload)
    trusted_system_path()
    trusted_parents(MANAGED_DIRECTORY.parent)
    directory = payload / "idmap-helpers"
    directory.mkdir(mode=0o700)
    records = []
    for name, capability in HELPERS:
        source = SOURCE_DIRECTORY / name
        info = metadata(source)
        require(stat.S_IMODE(info.st_mode) in (0o755, 0o4755), "unexpected host helper permissions")
        data = read_file(source, MAXIMUM_BINARY_BYTES)
        require(data.startswith(b"\x7fELF"), "host helper is not an ELF executable")
        package_line = run(["/usr/bin/dpkg-query", "-S", str(source)]).strip()
        require(package_line.endswith(": " + str(source)) and "\n" not in package_line,
                "host helper is not owned by the expected package")
        package = package_line[:-(len(str(source)) + 2)]
        require(re.fullmatch(r"uidmap(?::[a-z0-9]+)?", package), "host helper is not from uidmap")
        provenance = run(["/usr/bin/dpkg-query", "-W", "-f=${binary:Package}\n${Version}\n", package]).splitlines()
        require(len(provenance) == 2 and provenance[0] == package, "host helper package provenance changed")
        records.append(dict(name=name, source_path=str(source), source_package=package,
                            source_version=provenance[1], sha256=hashlib.sha256(data).hexdigest(), byte_count=len(data),
                            installed_path=str(MANAGED_DIRECTORY / name), owner="root", group="wali-worker",
                            mode="0550", capabilities=capability))
        write_snapshot_file(directory / name, data)
    write_snapshot_file(directory / "manifest.json",
                        (json.dumps(dict(version=1, helpers=records), sort_keys=True, separators=(",", ":")) + "\n").encode())
    validate_snapshot(payload)


def validate_install(payload):
    records = validate_snapshot(payload)
    trusted_parents(MANAGED_DIRECTORY.parent)
    if MANAGED_DIRECTORY.exists() or MANAGED_DIRECTORY.is_symlink():
        info = metadata(MANAGED_DIRECTORY)
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022,
                "installed helper directory is unsafe")
        require({item.name for item in MANAGED_DIRECTORY.iterdir()} <= {name for name, _ in HELPERS},
                "private helper directory contains unmanaged files")
        for path in MANAGED_DIRECTORY.iterdir():
            info = metadata(path)
            require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and info.st_nlink == 1
                    and not info.st_mode & 0o022, "installed helper cannot be safely replaced")
    return records


def verify_installed(payload):
    records = validate_snapshot(payload)
    trusted_system_path()
    trusted_parents(MANAGED_DIRECTORY.parent)
    if records is None:
        require(not MANAGED_DIRECTORY.exists() and not MANAGED_DIRECTORY.is_symlink(),
                "unexpected private helpers for a legacy snapshot")
        return
    info = metadata(MANAGED_DIRECTORY.parent)
    require((info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) == (0, 0, 0o755),
            "private helper parent must be root:root 0755")
    info = metadata(MANAGED_DIRECTORY)
    gid = worker_gid()
    require(stat.S_ISDIR(info.st_mode) and (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) == (0, gid, 0o750),
            "private helper directory must be root:wali-worker 0750")
    require({item.name for item in MANAGED_DIRECTORY.iterdir()} == {name for name, _ in HELPERS},
            "installed private helper set is incomplete")
    for record in records:
        data = read_file(MANAGED_DIRECTORY / record["name"], MAXIMUM_BINARY_BYTES,
                         group=gid, mode=0o550, capability=record["capabilities"])
        require(hashlib.sha256(data).hexdigest() == record["sha256"] and len(data) == record["byte_count"],
                "installed helper bytes differ from the selected snapshot")


def capture(payload, reference):
    trusted_parents(payload)
    if reference is None:
        require(not MANAGED_DIRECTORY.exists() and not MANAGED_DIRECTORY.is_symlink(),
                "installed helpers have no previous snapshot provenance")
        write_snapshot_file(payload / "idmap-helpers.absent", b"")
        return
    verify_installed(reference)
    records = validate_snapshot(reference)
    if records is None:
        write_snapshot_file(payload / "idmap-helpers.absent", b"")
    else:
        directory = payload / "idmap-helpers"
        directory.mkdir(mode=0o700)
        for name in ("manifest.json", "newuidmap", "newgidmap"):
            # The installed set has just been verified against this exact immutable snapshot.
            write_snapshot_file(directory / name, read_file(reference / "idmap-helpers" / name,
                                                             MAXIMUM_BINARY_BYTES, mode=0o400))
    validate_snapshot(payload)


def install(payload):
    records = validate_install(payload)
    if records is None:
        if MANAGED_DIRECTORY.exists():
            for path in MANAGED_DIRECTORY.iterdir(): path.unlink()
            MANAGED_DIRECTORY.rmdir()
        return
    parent = MANAGED_DIRECTORY.parent
    parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    info = metadata(parent)
    require((info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) == (0, 0, 0o755),
            "private helper parent must be root:root 0755")
    temporary = Path(tempfile.mkdtemp(prefix=".idmap-install-", dir=parent))
    try:
        for record in records:
            path = temporary / record["name"]
            data = read_file(payload / "idmap-helpers" / record["name"], MAXIMUM_BINARY_BYTES, mode=0o400)
            write_snapshot_file(path, data)
            change_owner(path, 0, worker_gid())
            path.chmod(0o550)
            run(["/usr/sbin/setcap", record["capabilities"], str(path)])
            read_file(path, MAXIMUM_BINARY_BYTES, group=worker_gid(), mode=0o550, capability=record["capabilities"])
        # Both services are stopped by the outer release transaction. A failure
        # restores their prior snapshot; no partial directory is activated.
        validate_install(payload)
        if MANAGED_DIRECTORY.exists():
            for path in MANAGED_DIRECTORY.iterdir(): path.unlink()
            MANAGED_DIRECTORY.rmdir()
        os.replace(temporary, MANAGED_DIRECTORY)
        change_owner(MANAGED_DIRECTORY, 0, worker_gid())
        MANAGED_DIRECTORY.chmod(0o750)
        verify_installed(payload)
    finally:
        if temporary.exists():
            for path in temporary.iterdir(): path.unlink()
            temporary.rmdir()


def main():
    require(os.geteuid() == 0, "private helper management must run as root")
    require(len(sys.argv) in (3, 4), "invalid private helper management arguments")
    action, payload = sys.argv[1], Path(sys.argv[2])
    actions = {"stage": stage, "validate-snapshot": validate_snapshot, "validate-install": validate_install,
               "install": install, "verify-installed": verify_installed}
    if action == "capture":
        require(len(sys.argv) == 4, "capture requires the previous snapshot or an empty reference")
        capture(payload, Path(sys.argv[3]) if sys.argv[3] else None)
    else:
        require(action in actions and len(sys.argv) == 3, "invalid private helper management action")
        actions[action](payload)


if __name__ == "__main__":
    try:
        main()
    except (UnsafeHelpers, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print("worker private ID helpers: " + str(error), file=sys.stderr)
        sys.exit(65)
