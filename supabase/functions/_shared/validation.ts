import { EdgeError } from "./errors.ts";

export type JSONObject = Record<string, unknown>;

export async function readExactJSON(
  request: Request,
  maximumBytes: number,
  exactKeys: readonly string[],
): Promise<JSONObject> {
  return requireExactKeys(
    await readBoundedJSON(request, maximumBytes),
    exactKeys,
  );
}

export async function readBoundedJSON(
  request: Request,
  maximumBytes: number,
): Promise<JSONObject> {
  if (request.method !== "POST") throw new EdgeError("invalid_request", 405);
  const contentType = request.headers.get("content-type")?.split(";", 1)[0]
    .trim().toLowerCase();
  if (contentType !== "application/json") {
    throw new EdgeError("invalid_request", 415);
  }
  const declaredLength = request.headers.get("content-length");
  if (
    declaredLength !== null &&
    (!/^\d+$/.test(declaredLength) || Number(declaredLength) > maximumBytes)
  ) {
    throw new EdgeError("invalid_request", 413);
  }
  if (!request.body) throw new EdgeError("invalid_request", 413);
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let byteCount = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      byteCount += value.byteLength;
      if (byteCount > maximumBytes) {
        await reader.cancel("request body exceeds endpoint limit").catch(
          () => {},
        );
        throw new EdgeError("invalid_request", 413);
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  if (byteCount === 0) {
    throw new EdgeError("invalid_request", 413);
  }
  const bytes = new Uint8Array(byteCount);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    scanJSON(text, 8);
  } catch {
    throw new EdgeError("invalid_request", 400);
  }
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    throw new EdgeError("invalid_request", 400);
  }
  if (!isObject(value)) throw new EdgeError("invalid_request", 400);
  return value;
}

export function requireExactKeys(
  value: JSONObject,
  exactKeys: readonly string[],
): JSONObject {
  const actual = Object.keys(value).sort();
  const expected = [...exactKeys].sort();
  if (
    actual.length !== expected.length ||
    actual.some((key, index) => key !== expected[index])
  ) {
    throw new EdgeError("invalid_request", 400);
  }
  return value;
}

export function requireEnvelope(
  body: JSONObject,
  apiVersion: string,
): { requestID: string; idempotencyKey: string } {
  if (body.api_version !== apiVersion) {
    throw new EdgeError("unsupported_api_version", 400);
  }
  const requestID = requireUUID(body.request_id);
  const idempotencyKey = requireIdempotencyKey(body.idempotency_key);
  return { requestID, idempotencyKey };
}

export function requireUUID(value: unknown): string {
  if (
    typeof value !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
      .test(value)
  ) {
    throw new EdgeError("invalid_request", 400);
  }
  return value;
}

export function requireIdempotencyKey(value: unknown): string {
  if (
    typeof value !== "string" || value.length < 16 || value.length > 64 ||
    !/^[A-Za-z0-9_-]+$/.test(value)
  ) {
    throw new EdgeError("invalid_request", 400);
  }
  return value;
}

export function requireRevision(value: unknown): number {
  if (!Number.isSafeInteger(value) || (value as number) < 0) {
    throw new EdgeError("invalid_request", 400);
  }
  return value as number;
}

export function requireInteger(
  value: unknown,
  minimum: number,
  maximum: number,
): number {
  if (
    !Number.isInteger(value) || (value as number) < minimum ||
    (value as number) > maximum
  ) {
    throw new EdgeError("invalid_request", 400);
  }
  return value as number;
}

export function requireEnum<const T extends string>(
  value: unknown,
  values: readonly T[],
): T {
  if (typeof value !== "string" || !values.includes(value as T)) {
    throw new EdgeError("invalid_request", 400);
  }
  return value as T;
}

export function requirePlainText(
  value: unknown,
  minimum: number,
  maximum: number,
): string {
  if (
    typeof value !== "string" || value !== value.normalize("NFC") ||
    value.length < minimum || value.length > maximum ||
    hasControlCharacter(value)
  ) {
    throw new EdgeError("invalid_request", 400);
  }
  return value;
}

export function optionalPlainText(
  value: unknown,
  maximum: number,
): string | null {
  if (value === null || value === undefined) return null;
  return requirePlainText(value, 1, maximum);
}

export function requireHTTPSURL(value: unknown): string {
  if (typeof value !== "string" || value.length > 2048) {
    throw new EdgeError("invalid_request", 400);
  }
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new EdgeError("invalid_request", 400);
  }
  if (url.protocol !== "https:" || url.username || url.password || url.hash) {
    throw new EdgeError("invalid_request", 400);
  }
  return url.href;
}

export function requireDigest(value: unknown): string {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/.test(value)) {
    throw new EdgeError("invalid_request", 400);
  }
  return value;
}

export function isObject(value: unknown): value is JSONObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

class JSONScanner {
  private index = 0;
  constructor(
    private readonly source: string,
    private readonly maximumDepth: number,
  ) {}

  scan(): void {
    this.value(0);
    this.whitespace();
    if (this.index !== this.source.length) throw new Error("trailing JSON");
  }

  private value(depth: number): void {
    if (depth > this.maximumDepth) throw new Error("nested JSON");
    this.whitespace();
    const token = this.source[this.index];
    if (token === "{") return this.object(depth + 1);
    if (token === "[") return this.array(depth + 1);
    if (token === '"') {
      this.string();
      return;
    }
    if (token === "t") return this.literal("true");
    if (token === "f") return this.literal("false");
    if (token === "n") return this.literal("null");
    if (token === "-" || /[0-9]/.test(token ?? "")) return this.number();
    throw new Error("invalid JSON value");
  }

  private object(depth: number): void {
    this.index++;
    const keys = new Set<string>();
    this.whitespace();
    if (this.source[this.index] === "}") {
      this.index++;
      return;
    }
    while (true) {
      this.whitespace();
      const key = this.string();
      if (keys.has(key)) throw new Error("duplicate JSON key");
      keys.add(key);
      this.whitespace();
      if (this.source[this.index++] !== ":") throw new Error("missing colon");
      this.value(depth);
      this.whitespace();
      const delimiter = this.source[this.index++];
      if (delimiter === "}") return;
      if (delimiter !== ",") throw new Error("invalid object");
    }
  }

  private array(depth: number): void {
    this.index++;
    this.whitespace();
    if (this.source[this.index] === "]") {
      this.index++;
      return;
    }
    while (true) {
      this.value(depth);
      this.whitespace();
      const delimiter = this.source[this.index++];
      if (delimiter === "]") return;
      if (delimiter !== ",") throw new Error("invalid array");
    }
  }

  private string(): string {
    const start = this.index;
    if (this.source[this.index++] !== '"') throw new Error("string expected");
    while (this.index < this.source.length) {
      const character = this.source[this.index++];
      if (character === '"') {
        return JSON.parse(this.source.slice(start, this.index));
      }
      if (character === "\\") {
        const escape = this.source[this.index++];
        if (escape === "u") {
          const hex = this.source.slice(this.index, this.index + 4);
          if (!/^[0-9a-fA-F]{4}$/.test(hex)) throw new Error("invalid escape");
          this.index += 4;
        } else if (!'"\\/bfnrt'.includes(escape ?? "")) {
          throw new Error("invalid escape");
        }
      } else if ((character?.charCodeAt(0) ?? 0) < 0x20) {
        throw new Error("control in string");
      }
    }
    throw new Error("unterminated string");
  }

  private number(): void {
    const rest = this.source.slice(this.index);
    const match = rest.match(/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/);
    if (!match) throw new Error("invalid number");
    this.index += match[0].length;
  }

  private literal(value: string): void {
    if (!this.source.startsWith(value, this.index)) {
      throw new Error("invalid literal");
    }
    this.index += value.length;
  }

  private whitespace(): void {
    while (/[\t\n\r ]/.test(this.source[this.index] ?? "")) this.index++;
  }
}

function scanJSON(source: string, maximumDepth: number): void {
  new JSONScanner(source, maximumDepth).scan();
}

function hasControlCharacter(value: string): boolean {
  return [...value].some((character) => {
    const code = character.codePointAt(0) ?? 0;
    return code <= 0x1f || (code >= 0x7f && code <= 0x9f);
  });
}
