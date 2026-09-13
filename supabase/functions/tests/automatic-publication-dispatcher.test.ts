import {
  type AutomaticPublicationDependencies,
  handleAutomaticPublication,
} from "../automatic-publication/index.ts";
import { EdgeError } from "../_shared/errors.ts";
import type { DatabaseGateway } from "../_shared/database.ts";
const ID = "70000000-0000-4000-8000-000000000001";
const TOKEN = "a".repeat(64);
const receipt = {
  wallpaper_id: ID,
  release_id: ID,
  edition: 1,
  manifest_digest: "b".repeat(64),
  key_id: "catalog-test",
  wallpaper_revision: 3,
  published_at: "2026-09-12T12:00:00Z",
};
const signature = {
  manifest_body: "body",
  metadata_body: "metadata",
  manifest_digest: "b".repeat(64),
  metadata_digest: "c".repeat(64),
  manifest_signature: "signature",
  signing_key_id: "catalog-test",
};
function assert(value: unknown, message = "assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
function equal(a: unknown, b: unknown) {
  assert(
    JSON.stringify(a) === JSON.stringify(b),
    `${JSON.stringify(a)} != ${JSON.stringify(b)}`,
  );
}
class Database implements DatabaseGateway {
  calls: Array<{ name: string; parameters: Record<string, unknown> }> = [];
  claimed = false;
  constructor(
    readonly prepared: unknown = {},
    readonly finalized: unknown = receipt,
  ) {}
  rpc<T>(name: string, parameters: Record<string, unknown>): Promise<T> {
    this.calls.push({ name, parameters });
    if (name === "wali_edge_claim_automatic_publication_v1") {
      const data = { job: this.claimed ? null : { id: ID, lease_token: ID } };
      this.claimed = true;
      return Promise.resolve(data as T);
    }
    if (name === "wali_edge_prepare_automatic_publication_v1") {
      if (this.prepared instanceof Error) throw this.prepared;
      return Promise.resolve(this.prepared as T);
    }
    if (name === "wali_edge_finalize_automatic_publication_v1") {
      if (this.finalized instanceof Error) throw this.finalized;
      return Promise.resolve(this.finalized as T);
    }
    return Promise.resolve(true as T);
  }
}
function deps(database: Database): AutomaticPublicationDependencies {
  return {
    database,
    dispatchToken: TOKEN,
    now: () => new Date("2026-09-12T12:00:00Z"),
    sign: () => Promise.resolve(signature),
  };
}
function request(
  token: string | null = TOKEN,
  body: unknown = { api_version: "publication_worker.v1" },
) {
  return new Request(
    "https://catalog.example/functions/v1/automatic-publication",
    {
      method: "POST",
      headers: {
        "content-type": "application/json",
        ...(token ? { "x-wali-publication-token": token } : {}),
      },
      body: JSON.stringify(body),
    },
  );
}
for (const token of [null, "user-access-token", "b".repeat(64)]) {
  Deno.test(`dispatcher refuses non-scheduler credential ${token === null ? "missing" : token.length}`, async () => {
    const db = new Database();
    equal(
      (await handleAutomaticPublication(request(token), deps(db))).status,
      401,
    );
    equal(db.calls.length, 0);
  });
}
Deno.test("dispatcher rejects caller-selected release or actor", async () => {
  const db = new Database();
  equal(
    (await handleAutomaticPublication(
      request(TOKEN, {
        api_version: "publication_worker.v1",
        job_id: ID,
        actor_aal: "aal2",
      }),
      deps(db),
    )).status,
    400,
  );
  equal(db.calls.length, 0);
});
Deno.test("promotion wait is retried without signing or pretending publication succeeded", async () => {
  const db = new Database({
    status: "promotion_pending",
    promotion_id: ID,
    retry_after_seconds: 2,
  });
  let signed = false;
  equal(
    (await handleAutomaticPublication(request(), {
      ...deps(db),
      sign: () => {
        signed = true;
        throw new Error("must not sign");
      },
    })).status,
    200,
  );
  assert(!signed);
  equal(
    db.calls.find((c) => c.name === "wali_edge_finish_automatic_publication_v1")
      ?.parameters.outcome,
    "retry",
  );
});
Deno.test("system publication signs and finalizes through job lease without human actor", async () => {
  const db = new Database({ wallpaper_id: ID, release_id: ID, edition: 1 });
  equal((await handleAutomaticPublication(request(), deps(db))).status, 200);
  const call = db.calls.find((c) =>
    c.name === "wali_edge_finalize_automatic_publication_v1"
  );
  assert(call);
  equal(call.parameters, { job_id: ID, lease_token: ID, ...signature });
  equal(
    db.calls.find((c) => c.name === "wali_edge_finish_automatic_publication_v1")
      ?.parameters.outcome,
    "completed",
  );
  assert(
    db.calls.every((c) =>
      !("actor_id" in c.parameters) && !("actor_aal" in c.parameters)
    ),
  );
});
Deno.test("lost final response replays prior publication without resigning", async () => {
  const db = new Database({ replayed: true, response: receipt });
  let signed = false;
  equal(
    (await handleAutomaticPublication(request(), {
      ...deps(db),
      sign: () => {
        signed = true;
        throw new Error("must not sign");
      },
    })).status,
    200,
  );
  assert(!signed);
  equal(
    db.calls.find((c) => c.name === "wali_edge_finish_automatic_publication_v1")
      ?.parameters.outcome,
    "completed",
  );
});
Deno.test("transport failure retains a retryable durable job", async () => {
  const db = new Database(new EdgeError("temporarily_unavailable", 503, true));
  equal((await handleAutomaticPublication(request(), deps(db))).status, 200);
  equal(
    db.calls.find((c) => c.name === "wali_edge_finish_automatic_publication_v1")
      ?.parameters.outcome,
    "retry",
  );
});
Deno.test("ineligible account cannot become system approved", async () => {
  const db = new Database(
    new EdgeError("publication_not_eligible", 409, false),
  );
  equal((await handleAutomaticPublication(request(), deps(db))).status, 200);
  equal(
    db.calls.find((c) => c.name === "wali_edge_finish_automatic_publication_v1")
      ?.parameters.outcome,
    "failed",
  );
});
Deno.test("mismatched finalized digest cannot be acknowledged", async () => {
  const db = new Database({ wallpaper_id: ID, release_id: ID, edition: 1 }, {
    ...receipt,
    manifest_digest: "d".repeat(64),
  });
  equal((await handleAutomaticPublication(request(), deps(db))).status, 200);
  equal(
    db.calls.find((c) => c.name === "wali_edge_finish_automatic_publication_v1")
      ?.parameters.outcome,
    "retry",
  );
});

Deno.test("finalize success then finish timeout retries and replays without a second publication", async () => {
  class FinishTimeoutDatabase extends Database {
    committed = false;
    finishFailed = false;
    override rpc<T>(
      name: string,
      parameters: Record<string, unknown>,
    ): Promise<T> {
      if (
        name === "wali_edge_prepare_automatic_publication_v1" && this.committed
      ) {
        this.calls.push({ name, parameters });
        return Promise.resolve({ replayed: true, response: receipt } as T);
      }
      if (name === "wali_edge_finalize_automatic_publication_v1") {
        this.committed = true;
      }
      if (
        name === "wali_edge_finish_automatic_publication_v1" &&
        parameters.outcome === "completed" && !this.finishFailed
      ) {
        this.calls.push({ name, parameters });
        this.finishFailed = true;
        throw new EdgeError("temporarily_unavailable", 503, true);
      }
      return super.rpc<T>(name, parameters);
    }
  }
  const db = new FinishTimeoutDatabase({
    wallpaper_id: ID,
    release_id: ID,
    edition: 1,
  });
  let signatures = 0;
  const dependencies = {
    ...deps(db),
    sign: () => {
      signatures++;
      return Promise.resolve(signature);
    },
  };
  equal(
    (await handleAutomaticPublication(request(), dependencies)).status,
    200,
  );
  db.claimed = false;
  equal(
    (await handleAutomaticPublication(request(), dependencies)).status,
    200,
  );
  equal(signatures, 1);
  equal(
    db.calls.filter((c) =>
      c.name === "wali_edge_finalize_automatic_publication_v1"
    ).length,
    1,
  );
  equal(
    db.calls.filter((c) =>
      c.name === "wali_edge_finish_automatic_publication_v1"
    ).map((c) => c.parameters.outcome),
    ["completed", "retry", "completed"],
  );
});
Deno.test("a second finish failure returns retryable failure and never pretends the lease was acknowledged", async () => {
  class UnavailableFinishDatabase extends Database {
    override rpc<T>(
      name: string,
      parameters: Record<string, unknown>,
    ): Promise<T> {
      if (name === "wali_edge_finish_automatic_publication_v1") {
        this.calls.push({ name, parameters });
        throw new EdgeError("temporarily_unavailable", 503, true);
      }
      return super.rpc<T>(name, parameters);
    }
  }
  const db = new UnavailableFinishDatabase({
    wallpaper_id: ID,
    release_id: ID,
    edition: 1,
  });
  const response = await handleAutomaticPublication(request(), deps(db));
  equal(response.status, 503);
  equal(
    db.calls.filter((c) =>
      c.name === "wali_edge_finish_automatic_publication_v1"
    ).map((c) => c.parameters.outcome),
    ["completed", "retry"],
  );
  equal(
    db.calls.filter((c) =>
      c.name === "wali_edge_claim_automatic_publication_v1"
    ).length,
    1,
  );
});
