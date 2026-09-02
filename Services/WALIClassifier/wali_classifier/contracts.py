from __future__ import annotations

import hashlib
import json
import math
import re
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Any


SHA256 = re.compile(r"^[a-f0-9]{64}$")
IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
EXPECTED_TAXONOMY_REVISION = "wali-taxonomy-v1"
MAX_REQUEST_BYTES = 64 * 1024
MAX_MANIFEST_BYTES = 64 * 1024
MAX_TAXONOMY_BYTES = 128 * 1024
UNSAFE_MODEL_SUFFIXES = {".bin", ".pkl", ".pickle", ".pt", ".pth", ".joblib"}


class ContractError(ValueError):
    def __init__(self, safe_code: str) -> None:
        super().__init__(safe_code)
        self.safe_code = safe_code


@dataclass(frozen=True)
class Frame:
    ordinal: int
    digest: str
    byte_count: int
    width: int
    height: int


@dataclass(frozen=True)
class Request:
    schema_version: int
    attempt_id: str
    submission_id: str
    generation: int
    title: str
    description: str
    taxonomy_revision: str
    frames: tuple[Frame, ...]

    @property
    def frame_set_digest(self) -> str:
        joined = "".join(frame.digest for frame in self.frames).encode("ascii")
        return hashlib.sha256(joined).hexdigest()


@dataclass(frozen=True)
class TaxonomyItem:
    identifier: str
    label: str
    prompt: str


@dataclass(frozen=True)
class Taxonomy:
    schema_version: int
    revision: str
    embedding_dimension: int
    category_threshold: float
    tag_threshold: float
    categories: tuple[TaxonomyItem, ...]
    tags: tuple[TaxonomyItem, ...]


@dataclass(frozen=True)
class ModelFile:
    digest: str
    byte_count: int


@dataclass(frozen=True)
class ModelManifest:
    schema_version: int
    model_id: str
    upstream_revision: str
    license: str
    artifact_set_digest: str
    embedding_dimension: int
    files: dict[str, ModelFile]


def _reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ContractError("invalid_request")
        result[key] = value
    return result


def _load_json(path: Path, maximum: int, safe_code: str) -> Any:
    try:
        if path.is_symlink() or not path.is_file() or path.stat().st_size > maximum:
            raise ContractError(safe_code)
        raw = path.read_bytes()
        return json.loads(raw, object_pairs_hook=_reject_duplicates)
    except ContractError:
        raise
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, TypeError, ValueError) as error:
        raise ContractError(safe_code) from error


def _require_exact_keys(value: dict[str, Any], expected: set[str], safe_code: str) -> None:
    if set(value) != expected:
        raise ContractError(safe_code)


def _bounded_text(value: Any, minimum: int, maximum: int) -> str:
    if not isinstance(value, str):
        raise ContractError("invalid_request")
    normalized = unicodedata.normalize("NFC", value).strip()
    if len(normalized) < minimum or len(normalized) > maximum:
        raise ContractError("text_too_large")
    if any(unicodedata.category(character) in {"Cc", "Cs"} for character in normalized):
        raise ContractError("invalid_request")
    return normalized


def load_request(path: Path) -> Request:
    value = _load_json(path, MAX_REQUEST_BYTES, "invalid_request")
    if not isinstance(value, dict):
        raise ContractError("invalid_request")
    _require_exact_keys(
        value,
        {"schema_version", "attempt_id", "submission_id", "generation", "title", "description", "taxonomy_revision", "frames"},
        "invalid_request",
    )
    if value["schema_version"] != 1 or isinstance(value["generation"], bool) or not isinstance(value["generation"], int) or not 1 <= value["generation"] <= 2**31 - 1:
        raise ContractError("invalid_request")
    if not isinstance(value["attempt_id"], str) or not IDENTIFIER.fullmatch(value["attempt_id"]):
        raise ContractError("invalid_request")
    if not isinstance(value["submission_id"], str) or not IDENTIFIER.fullmatch(value["submission_id"]):
        raise ContractError("invalid_request")
    if value["taxonomy_revision"] != EXPECTED_TAXONOMY_REVISION:
        raise ContractError("taxonomy_mismatch")
    if not isinstance(value["frames"], list) or len(value["frames"]) != 7:
        raise ContractError("invalid_frame_set")
    frames: list[Frame] = []
    for index, raw_frame in enumerate(value["frames"], start=1):
        if not isinstance(raw_frame, dict):
            raise ContractError("invalid_frame_set")
        _require_exact_keys(raw_frame, {"ordinal", "digest", "byte_count", "width", "height"}, "invalid_frame_set")
        if raw_frame["ordinal"] != index or isinstance(raw_frame["ordinal"], bool):
            raise ContractError("invalid_frame_set")
        if not isinstance(raw_frame["digest"], str) or not SHA256.fullmatch(raw_frame["digest"]):
            raise ContractError("invalid_frame_set")
        for field in ("byte_count", "width", "height"):
            if isinstance(raw_frame[field], bool) or not isinstance(raw_frame[field], int):
                raise ContractError("invalid_frame_set")
        if not 1 <= raw_frame["byte_count"] <= 16 * 1024 * 1024 or not 1 <= raw_frame["width"] <= 1024 or not 1 <= raw_frame["height"] <= 1024:
            raise ContractError("invalid_frame_set")
        frames.append(Frame(**raw_frame))
    return Request(
        schema_version=1,
        attempt_id=value["attempt_id"],
        submission_id=value["submission_id"],
        generation=value["generation"],
        title=_bounded_text(value["title"], 1, 120),
        description=_bounded_text(value["description"], 0, 2000),
        taxonomy_revision=value["taxonomy_revision"],
        frames=tuple(frames),
    )


def _taxonomy_item(value: Any) -> TaxonomyItem:
    if not isinstance(value, dict):
        raise ContractError("invalid_taxonomy")
    _require_exact_keys(value, {"id", "label", "prompt"}, "invalid_taxonomy")
    identifier = value["id"]
    if not isinstance(identifier, str) or not re.fullmatch(r"[a-z][a-z0-9_]{1,47}", identifier):
        raise ContractError("invalid_taxonomy")
    return TaxonomyItem(identifier, _bounded_text(value["label"], 1, 64), _bounded_text(value["prompt"], 1, 160))


def load_taxonomy(path: Path) -> Taxonomy:
    value = _load_json(path, MAX_TAXONOMY_BYTES, "invalid_taxonomy")
    if not isinstance(value, dict):
        raise ContractError("invalid_taxonomy")
    _require_exact_keys(value, {"schema_version", "revision", "embedding_dimension", "thresholds", "categories", "tags"}, "invalid_taxonomy")
    if value["schema_version"] != 1 or value["revision"] != EXPECTED_TAXONOMY_REVISION or value["embedding_dimension"] != 768:
        raise ContractError("invalid_taxonomy")
    thresholds = value["thresholds"]
    if not isinstance(thresholds, dict):
        raise ContractError("invalid_taxonomy")
    _require_exact_keys(thresholds, {"category", "tag"}, "invalid_taxonomy")
    category_threshold = float(thresholds["category"])
    tag_threshold = float(thresholds["tag"])
    if not 0.25 <= category_threshold <= 0.95 or not 0.25 <= tag_threshold <= 0.95:
        raise ContractError("invalid_taxonomy")
    categories = tuple(_taxonomy_item(item) for item in value["categories"])
    tags = tuple(_taxonomy_item(item) for item in value["tags"])
    identifiers = [item.identifier for item in (*categories, *tags)]
    if not 2 <= len(categories) <= 64 or not 2 <= len(tags) <= 256 or len(set(identifiers)) != len(identifiers):
        raise ContractError("invalid_taxonomy")
    return Taxonomy(1, value["revision"], 768, category_threshold, tag_threshold, categories, tags)


def load_model_manifest(path: Path) -> ModelManifest:
    value = _load_json(path, MAX_MANIFEST_BYTES, "invalid_model_manifest")
    if not isinstance(value, dict):
        raise ContractError("invalid_model_manifest")
    _require_exact_keys(value, {"schema_version", "model_id", "upstream_revision", "license", "artifact_set_digest", "embedding_dimension", "files"}, "invalid_model_manifest")
    if value["schema_version"] != 1 or value["model_id"] != "google/siglip-base-patch16-224" or value["license"] != "Apache-2.0" or value["embedding_dimension"] != 768:
        raise ContractError("invalid_model_manifest")
    if not re.fullmatch(r"[a-f0-9]{40}", value["upstream_revision"] or "") or not SHA256.fullmatch(value["artifact_set_digest"] or ""):
        raise ContractError("invalid_model_manifest")
    if not isinstance(value["files"], dict) or not value["files"]:
        raise ContractError("invalid_model_manifest")
    files: dict[str, ModelFile] = {}
    for name, spec in value["files"].items():
        if not isinstance(name, str) or Path(name).name != name or Path(name).suffix in UNSAFE_MODEL_SUFFIXES:
            raise ContractError("unsafe_model_file")
        if not isinstance(spec, dict):
            raise ContractError("invalid_model_manifest")
        _require_exact_keys(spec, {"sha256", "byte_count"}, "invalid_model_manifest")
        if not isinstance(spec["sha256"], str) or not SHA256.fullmatch(spec["sha256"]):
            raise ContractError("invalid_model_manifest")
        if isinstance(spec["byte_count"], bool) or not isinstance(spec["byte_count"], int) or not 1 <= spec["byte_count"] <= 2 * 1024 * 1024 * 1024:
            raise ContractError("invalid_model_manifest")
        files[name] = ModelFile(spec["sha256"], spec["byte_count"])
    if "model.safetensors" not in files or any(name.endswith(".bin") for name in files):
        raise ContractError("unsafe_model_file")
    canonical = json.dumps(value["files"], sort_keys=True, separators=(",", ":")).encode("utf-8")
    if hashlib.sha256(canonical).hexdigest() != value["artifact_set_digest"]:
        raise ContractError("invalid_model_manifest")
    return ModelManifest(1, value["model_id"], value["upstream_revision"], value["license"], value["artifact_set_digest"], 768, files)


def verify_model_directory(root: Path, manifest: ModelManifest) -> None:
    try:
        present = list(root.iterdir()) if root.is_dir() and not root.is_symlink() else []
    except OSError as error:
        raise ContractError("model_unavailable") from error
    if any(path.is_symlink() for path in present):
        raise ContractError("unsafe_model_file")
    if any(path.is_file() and path.suffix.lower() in UNSAFE_MODEL_SUFFIXES for path in present):
        raise ContractError("unsafe_model_file")
    present_names = {path.name for path in present}
    expected_names = set(manifest.files)
    if present_names - expected_names:
        raise ContractError("model_digest_mismatch")
    for name, spec in manifest.files.items():
        candidate = root / name
        if candidate.is_symlink() or not candidate.is_file():
            raise ContractError("model_unavailable")
        if candidate.stat().st_size != spec.byte_count:
            raise ContractError("model_digest_mismatch")
        digest = hashlib.sha256()
        with candidate.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
        if digest.hexdigest() != spec.digest:
            raise ContractError("model_digest_mismatch")


def normalized(values: list[float]) -> list[float]:
    if not values or any(not math.isfinite(value) for value in values):
        raise ContractError("invalid_embedding")
    length = math.sqrt(sum(value * value for value in values))
    if length <= 0:
        raise ContractError("invalid_embedding")
    return [value / length for value in values]
