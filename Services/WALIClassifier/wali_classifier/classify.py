from __future__ import annotations

import hashlib
import json
import os
import sys
from pathlib import Path
from typing import Any

from .contracts import (
    ContractError,
    ModelManifest,
    Request,
    Taxonomy,
    load_model_manifest,
    load_request,
    load_taxonomy,
    normalized,
    verify_model_directory,
)


INPUT_ROOT = Path("/work/input")
OUTPUT_ROOT = Path("/work/output")
MODEL_ROOT = Path("/opt/wali/model")
MANIFEST_PATH = Path("/opt/wali/model-manifest.json")
TAXONOMY_PATH = Path("/opt/wali/taxonomy-v1.json")


def ensure_offline_environment() -> None:
    for key in ("HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_HUB_DISABLE_TELEMETRY", "DO_NOT_TRACK"):
        os.environ[key] = "1"
    os.environ["TOKENIZERS_PARALLELISM"] = "false"


def _score(left: list[float], right: list[float]) -> float:
    if len(left) != len(right):
        raise ContractError("invalid_embedding")
    return sum(a * b for a, b in zip(normalized(left), normalized(right), strict=True))


def deterministic_result(
    visual: list[float],
    text: list[float],
    label_vectors: dict[str, list[float]],
    taxonomy: Taxonomy,
    *,
    threshold: float | None = None,
) -> dict[str, Any]:
    visual_embedding = normalized(visual)
    text_embedding = normalized(text)
    combined_embedding = normalized([(a + b) / 2 for a, b in zip(visual_embedding, text_embedding, strict=True)])

    def suggestions(items, configured_threshold: float) -> list[dict[str, Any]]:
        active_threshold = threshold if threshold is not None else configured_threshold
        scored = [
            {"id": item.identifier, "confidence": round(_score(combined_embedding, label_vectors[item.identifier]), 8)}
            for item in items
        ]
        return sorted(
            (entry for entry in scored if entry["confidence"] >= active_threshold),
            key=lambda entry: (-entry["confidence"], entry["id"]),
        )

    return {
        "visual_embedding": [round(value, 8) for value in visual_embedding],
        "text_embedding": [round(value, 8) for value in text_embedding],
        "combined_embedding": [round(value, 8) for value in combined_embedding],
        "categories": suggestions(taxonomy.categories, taxonomy.category_threshold),
        "tags": suggestions(taxonomy.tags, taxonomy.tag_threshold),
    }


def _load_frames(request: Request):
    try:
        from PIL import Image
    except ImportError as error:
        raise ContractError("inference_dependencies_unavailable") from error
    images = []
    for frame in request.frames:
        candidate = INPUT_ROOT / "frames" / f"frame-{frame.ordinal:03d}.jpg"
        if candidate.is_symlink() or not candidate.is_file() or candidate.stat().st_size != frame.byte_count:
            raise ContractError("invalid_frame_set")
        if hashlib.sha256(candidate.read_bytes()).hexdigest() != frame.digest:
            raise ContractError("invalid_frame_set")
        try:
            with Image.open(candidate) as source:
                source.load()
                if source.width != frame.width or source.height != frame.height or source.width > 1024 or source.height > 1024:
                    raise ContractError("invalid_frame_set")
                images.append(source.convert("RGB"))
        except ContractError:
            raise
        except Exception as error:
            raise ContractError("invalid_frame_set") from error
    return images


def _infer(request: Request, taxonomy: Taxonomy, manifest: ModelManifest) -> dict[str, Any]:
    verify_model_directory(MODEL_ROOT, manifest)
    images = _load_frames(request)
    try:
        import torch
        from transformers import AutoModel, AutoProcessor
    except ImportError as error:
        raise ContractError("inference_dependencies_unavailable") from error

    torch.manual_seed(0)
    torch.use_deterministic_algorithms(True)
    torch.set_num_threads(1)
    processor = AutoProcessor.from_pretrained(MODEL_ROOT, local_files_only=True, trust_remote_code=False)
    model = AutoModel.from_pretrained(
        MODEL_ROOT,
        local_files_only=True,
        trust_remote_code=False,
        use_safetensors=True,
    ).eval()
    prompts = [f"{request.title}. {request.description}"] + [
        item.prompt for item in (*taxonomy.categories, *taxonomy.tags)
    ]
    with torch.inference_mode():
        image_inputs = processor(images=images, return_tensors="pt")
        visual_tensor = model.get_image_features(**image_inputs).mean(dim=0)
        text_inputs = processor(text=prompts, padding="max_length", truncation=True, return_tensors="pt")
        text_tensors = model.get_text_features(**text_inputs)
    visual = visual_tensor.detach().cpu().float().tolist()
    text = text_tensors[0].detach().cpu().float().tolist()
    items = (*taxonomy.categories, *taxonomy.tags)
    label_vectors = {
        item.identifier: text_tensors[index + 1].detach().cpu().float().tolist()
        for index, item in enumerate(items)
    }
    if len(visual) != manifest.embedding_dimension or len(text) != manifest.embedding_dimension:
        raise ContractError("invalid_embedding")
    return deterministic_result(visual, text, label_vectors, taxonomy)


def classify() -> dict[str, Any]:
    ensure_offline_environment()
    request = load_request(INPUT_ROOT / "classification-request.json")
    taxonomy = load_taxonomy(TAXONOMY_PATH)
    if request.taxonomy_revision != taxonomy.revision:
        raise ContractError("taxonomy_mismatch")
    manifest = load_model_manifest(MANIFEST_PATH)
    result = _infer(request, taxonomy, manifest)
    return {
        "schema_version": 1,
        "attempt_id": request.attempt_id,
        "submission_id": request.submission_id,
        "generation": request.generation,
        "available": True,
        "safe_code": "ok",
        "model_id": manifest.model_id,
        "model_revision": manifest.upstream_revision,
        "model_digest": manifest.artifact_set_digest,
        "taxonomy_revision": taxonomy.revision,
        "input_frame_set_digest": request.frame_set_digest,
        **result,
    }


def _write_atomic(name: str, value: dict[str, Any]) -> None:
    OUTPUT_ROOT.mkdir(mode=0o700, parents=False, exist_ok=True)
    temporary = OUTPUT_ROOT / f".{name}.tmp"
    final = OUTPUT_ROOT / name
    with temporary.open("x", encoding="utf-8") as handle:
        json.dump(value, handle, sort_keys=True, separators=(",", ":"), allow_nan=False)
        handle.write("\n")
    temporary.replace(final)


def main() -> int:
    if len(sys.argv) != 1:
        _write_atomic("failure.json", {"schema_version": 1, "safe_code": "invalid_contract"})
        return 64
    try:
        _write_atomic("classification-claim.json", classify())
        return 0
    except ContractError as error:
        _write_atomic("failure.json", {"schema_version": 1, "safe_code": error.safe_code})
        return 64
    except Exception:
        _write_atomic("failure.json", {"schema_version": 1, "safe_code": "inference_failed"})
        return 70


if __name__ == "__main__":
    raise SystemExit(main())
