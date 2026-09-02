import type { DatabaseGateway } from "./database.ts";
import { EdgeError } from "./errors.ts";

export async function enforceRateLimit(
  database: DatabaseGateway,
  actorID: string,
  operation: string,
  maximum: number,
  windowSeconds: number,
): Promise<void> {
  const result = await database.rpc<
    { allowed: boolean; retry_after_seconds: number }
  >(
    "wali_edge_take_rate_limit_v1",
    { actor_id: actorID, operation, maximum, window_seconds: windowSeconds },
  );
  if (!result.allowed) {
    throw new EdgeError("rate_limited", 429, true, result.retry_after_seconds);
  }
}
