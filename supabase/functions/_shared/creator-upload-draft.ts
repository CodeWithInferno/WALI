import { EdgeError } from "./errors.ts";
import {
  isObject,
  optionalPlainText,
  requireEnum,
  requireExactKeys,
  requireHTTPSURL,
  requirePlainText,
  requireUUID,
} from "./validation.ts";

export function creatorUploadDraft(value: unknown): Record<string, unknown> {
  if (!isObject(value)) throw new EdgeError("invalid_request", 400);
  requireExactKeys(value, [
    "title",
    "description",
    "primary_category_id",
    "suggested_tag_ids",
    "content_warning",
    "rights_basis",
    "rights_holder",
    "license_id",
    "source_url",
    "attribution_text",
    "proof_object_ids",
    "attests_rights",
    "creator_terms_version",
  ]);
  const basis = requireEnum(
    value.rights_basis,
    ["original", "licensed", "public_domain"] as const,
  );
  if (
    value.attests_rights !== true || !Array.isArray(value.proof_object_ids) ||
    value.proof_object_ids.length !== 0 ||
    !Array.isArray(value.suggested_tag_ids) ||
    value.suggested_tag_ids.length > 20
  ) throw new EdgeError("invalid_request", 400);
  const tags = value.suggested_tag_ids.map(requireUUID);
  if (
    new Set(tags).size !== tags.length ||
    (basis !== "original" && value.source_url === null)
  ) throw new EdgeError("invalid_request", 400);
  return {
    title: requirePlainText(value.title, 1, 120),
    description: requirePlainText(value.description, 1, 2000),
    primary_category_id: requireUUID(value.primary_category_id),
    suggested_tag_ids: tags,
    content_warning: optionalPlainText(value.content_warning, 500),
    rights_basis: basis,
    rights_holder: requirePlainText(value.rights_holder, 1, 160),
    license_id: requireUUID(value.license_id),
    source_url: value.source_url === null
      ? null
      : requireHTTPSURL(value.source_url),
    attribution_text: optionalPlainText(value.attribution_text, 500),
    proof_object_ids: [],
    attests_rights: true,
    creator_terms_version: requirePlainText(
      value.creator_terms_version,
      10,
      32,
    ),
  };
}
