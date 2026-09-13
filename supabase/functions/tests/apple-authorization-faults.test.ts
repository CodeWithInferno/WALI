import { handleBindAppleAuthorization } from "../bind-apple-authorization/index.ts";
import {
  type AppleAuthorizationConfiguration,
  appleSHA256,
} from "../_shared/apple-authorization.ts";
import type { EndpointDependencies } from "../_shared/runtime.ts";

function assert(value: unknown, message = "assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
const actorID = "74000000-0000-4000-8000-000000000001";
const leaseToken = "74000000-0000-4000-8000-000000000002";
const clientID = "com.wali.store.development.WALI";
const subject = "local-fault-test-subject";
const nonce = "local-fault-test-nonce-not-a-production-credential";
const now = new Date("2026-09-13T12:00:00Z");
const encoder = new TextEncoder();
const encoded = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replaceAll("+", "-")
    .replaceAll("/", "_").replaceAll("=", "");

async function fixture(
  complete: (parameters: Record<string, unknown>, attempt: number) => unknown,
  returnedSubject = subject,
) {
  const rsa = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  );
  const signer = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const encodedPrivateKey = btoa(
    String.fromCharCode(
      ...new Uint8Array(
        await crypto.subtle.exportKey("pkcs8", signer.privateKey),
      ),
    ),
  );
  const config: AppleAuthorizationConfiguration = {
    clientID,
    keyID: "TESTKEY002",
    privateKeyP8:
      `-----BEGIN PRIVATE KEY-----\n${encodedPrivateKey}\n-----END PRIVATE KEY-----`,
    encryptionKeyVersion: "local-fault-v1",
    encryptionKey: crypto.getRandomValues(new Uint8Array(32)),
  };
  const jwk = {
    ...await crypto.subtle.exportKey("jwk", rsa.publicKey),
    kid: "local-fault-key",
    alg: "RS256",
    use: "sig",
  };
  async function token(appleSubject: string) {
    const input =
      encoded(encoder.encode(JSON.stringify({ alg: "RS256", kid: jwk.kid }))) +
      "." +
      encoded(encoder.encode(JSON.stringify({
        iss: "https://appleid.apple.com",
        aud: clientID,
        sub: appleSubject,
        nonce: await appleSHA256(nonce),
        iat: now.getTime() / 1000,
        exp: now.getTime() / 1000 + 300,
      })));
    return input + "." +
      encoded(
        new Uint8Array(
          await crypto.subtle.sign(
            "RSASSA-PKCS1-v1_5",
            rsa.privateKey,
            encoder.encode(input),
          ),
        ),
      );
  }
  const rpcCalls: Array<{ name: string; parameters: Record<string, unknown> }> =
    [];
  const providerCalls: Array<{ path: string; body: URLSearchParams }> = [];
  let completeAttempts = 0;
  let configurations = 0;
  const dependencies: EndpointDependencies = {
    database: {
      rpc<T>(name: string, parameters: Record<string, unknown>): Promise<T> {
        rpcCalls.push({ name, parameters: structuredClone(parameters) });
        if (name === "wali_edge_take_rate_limit_v1") {
          return Promise.resolve(
            { allowed: true, retry_after_seconds: 0 } as T,
          );
        }
        if (name === "wali_edge_begin_apple_authorization_v1") {
          return Promise.resolve(
            { status: "exchange", revision: 1, lease_token: leaseToken } as T,
          );
        }
        if (name === "wali_edge_complete_apple_authorization_v1") {
          return Promise.resolve().then(() =>
            complete(parameters, ++completeAttempts) as T
          );
        }
        if (name === "wali_edge_cancel_apple_authorization_v1") {
          return Promise.resolve(null as T);
        }
        throw new Error("unexpected database operation");
      },
    },
    authenticate: () =>
      Promise.resolve({
        actorID,
        assuranceLevel: "aal1",
        accessToken: "local-fault-session",
        expiresAt: now.getTime() / 1000 + 300,
      }),
    now: () => now,
    fetcher: (async (input, init) => {
      const url = new URL(String(input));
      assert(
        url.origin === "https://appleid.apple.com" &&
          init?.redirect === "error",
      );
      const body = new URLSearchParams(String(init?.body ?? ""));
      providerCalls.push({ path: url.pathname, body });
      if (url.pathname === "/auth/keys") return Response.json({ keys: [jwk] });
      assert(body.get("client_id") === clientID);
      if (url.pathname === "/auth/token") {
        return Response.json({
          access_token: "local-fault-access",
          refresh_token: "local-fault-refresh",
          token_type: "Bearer",
          expires_in: 3600,
          id_token: await token(returnedSubject),
        });
      }
      if (url.pathname === "/auth/revoke") {
        assert(
          body.get("token") === "local-fault-refresh" &&
            body.get("token_type_hint") === "refresh_token",
        );
        return new Response(null, { status: 200 });
      }
      throw new Error("unexpected provider operation");
    }) as typeof fetch,
    supabaseURL: "https://local.example",
    serviceRoleKey: "local-fault-service",
    publishableKey: "local-fault-public",
  };
  async function run() {
    const response = await handleBindAppleAuthorization(
      new Request("https://local.example/bind", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          api_version: "apple_authorization.v1",
          request_id: actorID,
          client_id: clientID,
          id_token: await token(subject),
          nonce,
          authorization_code: "local-fault-code",
        }),
      }),
      dependencies,
      (selectedClient) => {
        assert(selectedClient === clientID);
        configurations++;
        return config;
      },
    );
    const body = await response.text();
    assert(
      !body.includes("local-fault-refresh") &&
        !body.includes("local-fault-code") && !body.includes("v1."),
    );
    return { status: response.status, body: JSON.parse(body) };
  }
  return {
    run,
    rpcCalls,
    providerCalls,
    configurationCount: () => configurations,
  };
}

Deno.test("Apple bind retries an uncertain commit with the exact encrypted binding", async () => {
  const f = await fixture((_parameters, attempt) => {
    if (attempt === 1) throw new Error("local simulated lost commit reply");
    return { status: "bound" };
  });
  const result = await f.run();
  assert(result.status === 200 && result.body.data.subject_id === actorID);
  const commits = f.rpcCalls.filter((c) =>
    c.name === "wali_edge_complete_apple_authorization_v1"
  );
  assert(
    commits.length === 2 &&
      JSON.stringify(commits[0].parameters) ===
        JSON.stringify(commits[1].parameters),
  );
  assert(
    commits[0].parameters.actor_id === actorID &&
      commits[0].parameters.lease_token === leaseToken,
  );
  assert(f.providerCalls.filter((c) => c.path === "/auth/token").length === 1);
  assert(!f.providerCalls.some((c) => c.path === "/auth/revoke"));
  assert(
    !f.rpcCalls.some((c) =>
      c.name === "wali_edge_cancel_apple_authorization_v1"
    ),
  );
  assert(f.configurationCount() === 1);
});

Deno.test("Apple bind preserves possibly committed custody after both replies are lost", async () => {
  const f = await fixture(() => {
    throw new Error("local simulated uncertain commit");
  });
  assert((await f.run()).status === 503);
  assert(
    f.rpcCalls.filter((c) =>
      c.name === "wali_edge_complete_apple_authorization_v1"
    ).length === 2,
  );
  assert(!f.providerCalls.some((c) => c.path === "/auth/revoke"));
  assert(
    !f.rpcCalls.some((c) =>
      c.name === "wali_edge_cancel_apple_authorization_v1"
    ),
  );
});

Deno.test("Apple bind preserves committed custody after deletion freezes a lost-reply retry", async () => {
  const f = await fixture(() => ({ status: "retained" }));
  assert((await f.run()).status === 401);
  assert(
    f.rpcCalls.filter((c) =>
      c.name === "wali_edge_complete_apple_authorization_v1"
    ).length === 1,
  );
  assert(!f.providerCalls.some((c) => c.path === "/auth/revoke"));
  assert(
    !f.rpcCalls.some((c) =>
      c.name === "wali_edge_cancel_apple_authorization_v1"
    ),
  );
});

Deno.test("Apple bind revokes only the issued token after a confirmed commit rejection", async () => {
  const f = await fixture(() => ({ status: "rejected" }));
  assert((await f.run()).status === 401);
  assert(f.providerCalls.filter((c) => c.path === "/auth/revoke").length === 1);
  assert(
    f.rpcCalls.filter((c) =>
      c.name === "wali_edge_complete_apple_authorization_v1"
    ).length === 1,
  );
  assert(
    !f.rpcCalls.some((c) =>
      c.name === "wali_edge_cancel_apple_authorization_v1"
    ),
  );
});

Deno.test("Apple bind revokes a mismatched provider response and cancels only its uncommitted lease", async () => {
  const f = await fixture(() => {
    throw new Error("mismatched identity reached commit");
  }, "different-local-subject");
  assert((await f.run()).status === 401);
  assert(f.providerCalls.filter((c) => c.path === "/auth/revoke").length === 1);
  assert(
    !f.rpcCalls.some((c) =>
      c.name === "wali_edge_complete_apple_authorization_v1"
    ),
  );
  const cancellations = f.rpcCalls.filter((c) =>
    c.name === "wali_edge_cancel_apple_authorization_v1"
  );
  assert(
    cancellations.length === 1 &&
      JSON.stringify(cancellations[0].parameters) ===
        JSON.stringify({
          actor_id: actorID,
          client_id: clientID,
          lease_token: leaseToken,
        }),
  );
});
