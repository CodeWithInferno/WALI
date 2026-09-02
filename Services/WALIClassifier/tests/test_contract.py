from __future__ import annotations

import hashlib
import json
from pathlib import Path

import pytest

from wali_classifier.classify import deterministic_result, ensure_offline_environment
from wali_classifier.contracts import (
    ContractError,
    load_model_manifest,
    load_request,
    load_taxonomy,
    verify_model_directory,
)


ROOT = Path(__file__).resolve().parents[1]


def frame(ordinal: int) -> dict[str, object]:
    return {
        "ordinal": ordinal,
        "digest": f"{ordinal:064x}",
        "byte_count": 100 + ordinal,
        "width": 384,
        "height": 224,
    }


def valid_request() -> dict[str, object]:
    return {
        "schema_version": 1,
        "attempt_id": "11111111-1111-4111-8111-111111111111",
        "submission_id": "22222222-2222-4222-8222-222222222222",
        "generation": 3,
        "title": "Northern Lights",
        "description": "A calm aurora above a dark mountain lake.",
        "taxonomy_revision": "wali-taxonomy-v1",
        "frames": [frame(index) for index in range(1, 8)],
    }


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, separators=(",", ":")), encoding="utf-8")


def test_request_accepts_exact_seven_frames_and_normalized_text(tmp_path: Path) -> None:
    request_path = tmp_path / "request.json"
    write_json(request_path, valid_request())
    request = load_request(request_path)
    assert request.title == "Northern Lights"
    assert [item.ordinal for item in request.frames] == list(range(1, 8))


@pytest.mark.parametrize(
    ("mutation", "safe_code"),
    [
        (lambda value: value.update({"url": "https://attacker.invalid"}), "invalid_request"),
        (lambda value: value.update({"title": "x" * 121}), "text_too_large"),
        (lambda value: value.update({"frames": value["frames"][:6]}), "invalid_frame_set"),
        (lambda value: value.update({"taxonomy_revision": "unknown"}), "taxonomy_mismatch"),
    ],
)
def test_request_rejects_unknown_oversized_and_mismatched_inputs(tmp_path: Path, mutation, safe_code: str) -> None:
    value = valid_request()
    mutation(value)
    request_path = tmp_path / "request.json"
    write_json(request_path, value)
    with pytest.raises(ContractError) as error:
        load_request(request_path)
    assert error.value.safe_code == safe_code


def test_request_rejects_path_like_identifiers(tmp_path: Path) -> None:
    value = valid_request()
    value["attempt_id"] = "../../work/output"
    request_path = tmp_path / "request.json"
    write_json(request_path, value)
    with pytest.raises(ContractError) as error:
        load_request(request_path)
    assert error.value.safe_code == "invalid_request"


def test_json_duplicate_keys_are_rejected(tmp_path: Path) -> None:
    request_path = tmp_path / "request.json"
    request_path.write_text('{"schema_version":1,"schema_version":1}', encoding="utf-8")
    with pytest.raises(ContractError) as error:
        load_request(request_path)
    assert error.value.safe_code == "invalid_request"


def test_taxonomy_and_model_manifest_are_pinned_and_safe() -> None:
    taxonomy = load_taxonomy(ROOT / "taxonomy-v1.json")
    manifest = load_model_manifest(ROOT / "model-manifest.json")
    assert taxonomy.revision == "wali-taxonomy-v1"
    assert manifest.model_id == "google/siglip-base-patch16-224"
    assert manifest.upstream_revision == "7fd15f0689c79d79e38b1c2e2e2370a7bf2761ed"
    assert manifest.files["model.safetensors"].digest == "2c63cb7d1f2e95ba501893cbb8faeb4ea9a3af295498d35097126228659c2af8"
    assert "pytorch_model.bin" not in manifest.files


def test_missing_model_and_unsafe_weight_file_fail_closed(tmp_path: Path) -> None:
    manifest = load_model_manifest(ROOT / "model-manifest.json")
    with pytest.raises(ContractError) as missing:
        verify_model_directory(tmp_path, manifest)
    assert missing.value.safe_code == "model_unavailable"

    (tmp_path / "pytorch_model.bin").write_bytes(b"pickle is forbidden")
    with pytest.raises(ContractError) as unsafe:
        verify_model_directory(tmp_path, manifest)
    assert unsafe.value.safe_code == "unsafe_model_file"


def test_model_directory_rejects_unmanifested_files_and_symlinks(tmp_path: Path) -> None:
    manifest = load_model_manifest(ROOT / "model-manifest.json")
    (tmp_path / "surprise.json").write_text("{}", encoding="utf-8")
    with pytest.raises(ContractError) as extra:
        verify_model_directory(tmp_path, manifest)
    assert extra.value.safe_code == "model_digest_mismatch"

    (tmp_path / "surprise.json").unlink()
    (tmp_path / "unexpected").symlink_to(ROOT / "taxonomy-v1.json")
    with pytest.raises(ContractError) as linked:
        verify_model_directory(tmp_path, manifest)
    assert linked.value.safe_code == "unsafe_model_file"


def test_deterministic_result_is_normalized_stable_and_conservative() -> None:
    taxonomy = load_taxonomy(ROOT / "taxonomy-v1.json")
    visual = [1.0, 0.0, 0.0, 0.0]
    text = [0.0, 1.0, 0.0, 0.0]
    label_vectors = {
        item.identifier: [1.0, 0.0, 0.0, 0.0]
        for item in (*taxonomy.categories, *taxonomy.tags)
    }
    first = deterministic_result(visual, text, label_vectors, taxonomy, threshold=0.8)
    second = deterministic_result(visual, text, label_vectors, taxonomy, threshold=0.8)
    assert first == second
    assert sum(value * value for value in first["combined_embedding"]) == pytest.approx(1.0)
    assert first["categories"] == []
    assert first["tags"] == []


def test_offline_environment_is_mandatory(monkeypatch: pytest.MonkeyPatch) -> None:
    for key in ("HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_HUB_DISABLE_TELEMETRY", "DO_NOT_TRACK"):
        monkeypatch.delenv(key, raising=False)
    ensure_offline_environment()
    assert all(
        __import__("os").environ[key] == "1"
        for key in ("HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_HUB_DISABLE_TELEMETRY", "DO_NOT_TRACK")
    )


def test_frame_set_digest_is_content_addressed() -> None:
    value = valid_request()
    expected = hashlib.sha256("".join(item["digest"] for item in value["frames"]).encode()).hexdigest()
    assert len(expected) == 64
