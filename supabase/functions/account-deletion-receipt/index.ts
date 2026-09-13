import {
  capabilityHash,
  unavailable,
  validReceipt,
} from "../_shared/account-deletion.ts";
import {
  databaseEnvironment,
  type DatabaseGateway,
  PostgRESTDatabase,
} from "../_shared/database.ts";
import { EdgeError, success } from "../_shared/errors.ts";
import { safeFailure, UNKNOWN_REQUEST_ID } from "../_shared/runtime.ts";
import { readExactJSON, requireUUID } from "../_shared/validation.ts";

const API_VERSION = "account_deletion_receipt.v1";
export async function handleAccountDeletionReceipt(
  request: Request,
  dependencies: { database: DatabaseGateway },
): Promise<Response> {
  let requestID = UNKNOWN_REQUEST_ID;
  try {
    if (request.method !== "POST") throw new EdgeError("invalid_request", 405);
    const body = await readExactJSON(request, 1024, [
      "api_version",
      "request_id",
      "capability",
    ]);
    if (body.api_version !== API_VERSION) {
      throw new EdgeError("unsupported_api_version", 400);
    }
    requestID = requireUUID(body.request_id);
    const data = await dependencies.database.rpc<unknown>(
      "wali_edge_account_deletion_receipt_v1",
      {
        capability_hash: await capabilityHash(body.capability),
      },
    );
    if (data === null) throw new EdgeError("deletion_receipt_unavailable", 404);
    if (!validReceipt(data)) unavailable();
    return success(API_VERSION, requestID, data);
  } catch (error) {
    return safeFailure(API_VERSION, requestID, error);
  }
}
if (import.meta.main) {
  Deno.serve((request) =>
    handleAccountDeletionReceipt(request, {
      database: new PostgRESTDatabase(databaseEnvironment(), (input, init) =>
        fetch(input, { ...init, signal: AbortSignal.timeout(8_000) })),
    })
  );
}
