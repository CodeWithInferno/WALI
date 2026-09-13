#!/usr/bin/env python3
"""Verify media-image license/source packaging without executing media inputs."""
import argparse
import hashlib
from pathlib import Path, PurePosixPath
import re
import tarfile
import tempfile

IMAGE_ROOT = "/opt/wali/share/media-compliance"
CONTEXT_FILES = (
    "Containerfile", "THIRD_PARTY_NOTICES.md", "LICENSE", "SOURCE-LICENSES.sha256",
    "patches/ffmpeg-7.1.2-libkvazaar-10bit.patch",
    "policy/ffmpeg-policy.json", "bin/process-media", "bin/verify-media",
    "policy/still-image-policy.json", "bin/process-still", "bin/verify-still", "bin/still-image-contract.c",
)
ARCHIVE_MEMBERS = {
    "sources/ffmpeg-7.1.2.tar.xz": {
        "ffmpeg-7.1.2/COPYING.LGPLv2.1": "licenses/ffmpeg/COPYING.LGPLv2.1",
        "ffmpeg-7.1.2/LICENSE.md": "licenses/ffmpeg/LICENSE.md",
    },
    "sources/kvazaar-2.3.1.tar.xz": {
        "kvazaar-2.3.1/LICENSE": "licenses/kvazaar/LICENSE",
        "kvazaar-2.3.1/LICENSE.EXT.greatest": "licenses/kvazaar/LICENSE.EXT.greatest",
    },
}


def require(value, message):
    if not value:
        raise ValueError(message)


def digest(path):
    require(path.is_file() and not path.is_symlink(), "Missing regular provenance file: " + str(path))
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def parse_hashes(text, prefix=""):
    result = {}
    for line in text.splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9_./-]+)", line)
        require(match is not None, "Invalid SHA256 manifest line")
        value, name = match.groups()
        if prefix:
            require(name.startswith(prefix + "/"), "Unexpected image provenance path")
            name = name[len(prefix) + 1:]
        require(not name.startswith("/") and ".." not in PurePosixPath(name).parts, "Unsafe provenance path")
        require(name not in result, "Duplicate provenance path")
        result[name] = value
    require(result, "Empty provenance manifest")
    return result


def source_manifest(root):
    manifest = parse_hashes((root / "SOURCE-LICENSES.sha256").read_text())
    required = set(ARCHIVE_MEMBERS)
    for members in ARCHIVE_MEMBERS.values():
        required.update(members.values())
    required.update(("build-context/LICENSE", "build-context/patches/ffmpeg-7.1.2-libkvazaar-10bit.patch"))
    require(set(manifest) == required, "Source/license manifest has missing or unexpected assets")
    recipe = (root / "Containerfile").read_text()
    for component, archive in (("FFMPEG", "sources/ffmpeg-7.1.2.tar.xz"),
                               ("KVAZAAR", "sources/kvazaar-2.3.1.tar.xz")):
        match = re.search(r"^ARG " + component + r"_SHA256=([0-9a-f]{64})$", recipe, re.M)
        require(match is not None and match[1] == manifest[archive], "Archive digest differs from build pin")
    require(digest(root / "LICENSE") == manifest["build-context/LICENSE"], "Project license changed")
    require(digest(root.parent.parent / "LICENSE") == manifest["build-context/LICENSE"], "Sandbox license differs from project license")
    patch = "patches/ffmpeg-7.1.2-libkvazaar-10bit.patch"
    require(digest(root / patch) == manifest["build-context/" + patch], "Shipped patch differs from corresponding-source manifest")
    for token in ("sha256sum --check --strict SOURCE-LICENSES.sha256",
                  "COPY --from=build " + IMAGE_ROOT + " " + IMAGE_ROOT):
        require(token in recipe, "Image recipe does not verify/copy provenance bundle: " + token)
    return manifest


def expected_image_hashes(root):
    expected = source_manifest(root)
    for name in CONTEXT_FILES:
        expected["build-context/" + name] = digest(root / name)
    for name in ("THIRD_PARTY_NOTICES.md", "SOURCE-LICENSES.sha256"):
        expected[name] = digest(root / name)
    return expected


def verify_image_digests(text, expected):
    actual = parse_hashes(text, IMAGE_ROOT)
    require(actual.keys() == expected.keys(), "Image provenance asset set is incomplete or unexpected")
    for name, value in expected.items():
        require(actual[name] == value, "Image provenance bytes differ: " + name)


def verify_archives(directory, manifest):
    for image_path, members in ARCHIVE_MEMBERS.items():
        path = directory / Path(image_path).name
        require(digest(path) == manifest[image_path], "Official archive differs from pinned source: " + path.name)
        with tarfile.open(path, "r:xz") as archive:
            for member, destination in members.items():
                record = archive.getmember(member)
                require(record.isfile(), "Archive license is not a regular file: " + member)
                data = archive.extractfile(record).read()
                require(hashlib.sha256(data).hexdigest() == manifest[destination], "Full upstream license differs: " + member)


def rejection_tests(expected):
    count = 0
    def text(values):
        return "".join(value + "  " + IMAGE_ROOT + "/" + name + "\n" for name, value in values.items())
    good = text(expected)
    verify_image_digests(good, expected)
    first = next(iter(expected))
    cases = [
        "\n".join(good.splitlines()[1:]) + "\n",
        text(dict(expected, **{first: "0" * 64})),
        good + "0" * 64 + "  " + IMAGE_ROOT + "/unreviewed-file\n",
        good + good.splitlines()[0] + "\n",
        good.replace(IMAGE_ROOT + "/", IMAGE_ROOT + "/../", 1),
        "",
    ]
    for bad in cases:
        try:
            verify_image_digests(bad, expected)
        except ValueError:
            count += 1
        else:
            raise ValueError("Accepted invalid image provenance fixture")
    with tempfile.TemporaryDirectory(prefix="wali-media-license-test-") as temporary:
        directory = Path(temporary)
        data = directory / "license"
        data.write_bytes(b"fixture")
        link = directory / "linked-license"
        link.symlink_to(data)
        try:
            digest(link)
        except ValueError:
            count += 1
        else:
            raise ValueError("Accepted symlink provenance input")
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[2] / "Services/WALIMediaSandbox")
    parser.add_argument("--archive-directory", type=Path)
    parser.add_argument("--image-digests", type=Path)
    args = parser.parse_args()
    root = args.source_root.resolve()
    expected = expected_image_hashes(root)
    count = rejection_tests(expected)
    if args.archive_directory:
        verify_archives(args.archive_directory, source_manifest(root))
    if args.image_digests:
        verify_image_digests(args.image_digests.read_text(), expected)
    print("Media license/source checks passed (%s rejection fixtures; %s required image files%s%s)." %
          (count, len(expected), "; pinned upstream archives verified" if args.archive_directory else "",
           "; actual image bytes verified" if args.image_digests else ""))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, tarfile.TarError) as error:
        raise SystemExit("Media license/source verification failed: " + str(error))
