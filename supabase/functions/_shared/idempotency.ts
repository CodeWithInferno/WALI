export async function requestDigest(value: unknown): Promise<string> {
  const canonical = canonicalJSON(value);
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(canonical),
  );
  return [...new Uint8Array(digest)].map((byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

export function canonicalJSON(value: unknown): string {
  if (
    value === null || typeof value === "boolean" || typeof value === "string"
  ) return JSON.stringify(value);
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value) || value < 0) {
      throw new TypeError("integer required");
    }
    return String(value);
  }
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
  if (typeof value === "object") {
    const object = value as Record<string, unknown>;
    return `{${
      Object.keys(object).sort().map((key) =>
        `${JSON.stringify(key)}:${canonicalJSON(object[key])}`
      ).join(",")
    }}`;
  }
  throw new TypeError("unsupported canonical value");
}
