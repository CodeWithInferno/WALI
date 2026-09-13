import {
  type AppleAuthorizationConfiguration,
  appleAuthorizationConfigurationFromEnvironment,
  exchangeAppleAuthorization,
  revokeAppleAuthorization,
  verifyAppleIdentityToken,
} from "../_shared/apple-authorization.ts";

function assert(value: unknown, message = "assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
async function rejects(action: () => unknown | Promise<unknown>) {
  let failed = false;
  try {
    await action();
  } catch {
    failed = true;
  }
  assert(failed);
}
const encode = (value: Uint8Array) =>
  btoa(String.fromCharCode(...value)).replaceAll("+", "-").replaceAll("/", "_")
    .replaceAll("=", "");
const text = new TextEncoder();
const clientID = "com.wali.store.development.WALI";
const actorID = "71000000-0000-4000-8000-000000000001";
const nonce = "test-nonce-created-only-for-local-crypto-tests";
const now = new Date("2026-09-13T12:00:00Z");
async function fixture() {
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
  const pem = btoa(
    String.fromCharCode(
      ...new Uint8Array(
        await crypto.subtle.exportKey("pkcs8", signer.privateKey),
      ),
    ),
  );
  const config: AppleAuthorizationConfiguration = {
    clientID,
    keyID: "TESTKEY001",
    privateKeyP8:
      `-----BEGIN PRIVATE KEY-----\n${pem}\n-----END PRIVATE KEY-----`,
    encryptionKeyVersion: "test-v1",
    encryptionKey: crypto.getRandomValues(new Uint8Array(32)),
  };
  const jwk = {
    ...await crypto.subtle.exportKey("jwk", rsa.publicKey),
    kid: "local-test",
    alg: "RS256",
    use: "sig",
  };
  const nonceHash = [
    ...new Uint8Array(
      await crypto.subtle.digest("SHA-256", text.encode(nonce)),
    ),
  ].map((v) => v.toString(16).padStart(2, "0")).join("");
  async function token(overrides: Record<string, unknown> = {}) {
    const header = encode(
      text.encode(JSON.stringify({ alg: "RS256", kid: jwk.kid })),
    );
    const payload = encode(
      text.encode(
        JSON.stringify({
          iss: "https://appleid.apple.com",
          aud: clientID,
          sub: "local-apple-subject",
          nonce: nonceHash,
          iat: now.getTime() / 1000,
          exp: now.getTime() / 1000 + 300,
          ...overrides,
        }),
      ),
    );
    const signingInput = `${header}.${payload}`;
    const signature = await crypto.subtle.sign(
      "RSASSA-PKCS1-v1_5",
      rsa.privateKey,
      text.encode(signingInput),
    );
    return `${signingInput}.${encode(new Uint8Array(signature))}`;
  }
  const calls: Array<
    { url: string; body: URLSearchParams; redirect: string | undefined }
  > = [];
  let returnedToken = await token();
  let tokenType = "Bearer";
  const fetcher =
    ((url: URL | Request | string, init?: RequestInit) =>
      Promise.resolve().then(() => {
        calls.push({
          url: String(url),
          body: new URLSearchParams(String(init?.body ?? "")),
          redirect: init?.redirect,
        });
        if (String(url).endsWith("/auth/keys")) {
          return Response.json({ keys: [jwk] });
        }
        if (String(url).endsWith("/auth/token")) {
          return Response.json({
            access_token: "local-access",
            token_type: tokenType,
            expires_in: 3600,
            refresh_token: "local-refresh-credential",
            id_token: returnedToken,
          });
        }
        if (String(url).endsWith("/auth/revoke")) {
          return new Response(null, { status: 200 });
        }
        throw new Error("unexpected URL");
      })) as typeof fetch;
  return {
    config,
    token,
    fetcher,
    calls,
    setTokenType(value: string) {
      tokenType = value;
    },
    setReturnedToken(value: string) {
      returnedToken = value;
    },
  };
}
Deno.test("Apple exchange validates provider identity and encrypts a same-account revocation binding", async () => {
  const f = await fixture();
  const idToken = await f.token();
  const identity = await verifyAppleIdentityToken(
    idToken,
    clientID,
    nonce,
    f.fetcher,
    now,
  );
  assert(identity.subject === "local-apple-subject");
  const binding = await exchangeAppleAuthorization(
    {
      actorID,
      clientID,
      appleSubject: identity.subject,
      authorizationCode: "local-code",
      nonce,
    },
    f.config,
    f.fetcher,
    now,
  );
  assert(!binding.encryptedRefreshToken.includes("local-refresh"));
  const exchange = f.calls.find((c) => c.url.endsWith("/auth/token"))!;
  assert(exchange.body.get("grant_type") === "authorization_code");
  assert(!exchange.body.has("redirect_uri"));
  await revokeAppleAuthorization(binding, f.config, f.fetcher);
  const revoke = f.calls.find((c) => c.url.endsWith("/auth/revoke"))!;
  assert(revoke.body.get("token") === "local-refresh-credential");
  assert(revoke.body.get("token_type_hint") === "refresh_token");
  assert(f.calls.every((c) => c.redirect === "error"));
});
Deno.test("Apple token rejects wrong nonce, issuer, subject freshness and audience", async () => {
  const f = await fixture();
  for (
    const claims of [
      { nonce: "wrong" },
      { iss: "https://wrong.example" },
      { aud: "com.wali.unapproved" },
      { exp: 1 },
      { iat: now.getTime() / 1000 + 60 },
      { sub: "" },
    ]
  ) {
    await rejects(async () =>
      verifyAppleIdentityToken(
        await f.token(claims),
        clientID,
        nonce,
        f.fetcher,
        now,
      )
    );
  }
  await rejects(async () =>
    verifyAppleIdentityToken(
      await f.token(),
      "unapproved",
      nonce,
      f.fetcher,
      now,
    )
  );
});
Deno.test("Apple exchange fails closed when returned subject differs", async () => {
  const f = await fixture();
  f.setReturnedToken(await f.token({ sub: "different-apple-account" }));
  await rejects(() =>
    exchangeAppleAuthorization(
      {
        actorID,
        clientID,
        appleSubject: "local-apple-subject",
        authorizationCode: "local-code",
        nonce,
      },
      f.config,
      f.fetcher,
      now,
    )
  );
});
Deno.test("encrypted Apple credentials cannot cross actor, client, subject or key version", async () => {
  const f = await fixture();
  const binding = await exchangeAppleAuthorization(
    {
      actorID,
      clientID,
      appleSubject: "local-apple-subject",
      authorizationCode: "local-code",
      nonce,
    },
    f.config,
    f.fetcher,
    now,
  );
  for (
    const altered of [
      { actorID: "71000000-0000-4000-8000-000000000002" },
      { clientID: "com.wali.store.WALI" },
      { appleSubject: "different" },
      { keyVersion: "wrong" },
    ]
  ) {
    await rejects(() =>
      revokeAppleAuthorization({ ...binding, ...altered }, f.config, f.fetcher)
    );
  }
  assert(!f.calls.some((c) => c.url.endsWith("/auth/revoke")));
});
Deno.test("Apple provider body size and revocation status are bounded and checked", async () => {
  const f = await fixture();
  const binding = await exchangeAppleAuthorization(
    {
      actorID,
      clientID,
      appleSubject: "local-apple-subject",
      authorizationCode: "local-code",
      nonce,
    },
    f.config,
    f.fetcher,
    now,
  );
  for (
    const response of [
      new Response(null, { status: 302 }),
      Response.json({ error: "invalid_client" }, { status: 400 }),
      new Response("x".repeat(17000)),
      new Response("unexpected"),
    ]
  ) {
    await rejects(() =>
      revokeAppleAuthorization(
        binding,
        f.config,
        (() => Promise.resolve(response)) as typeof fetch,
      )
    );
  }
});

Deno.test("Apple bind rejects a client-selected actor before any provider or database call", async () => {
  const { handleBindAppleAuthorization } = await import(
    "../bind-apple-authorization/index.ts"
  );
  const response = await handleBindAppleAuthorization(
    new Request("https://local.example/bind", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        api_version: "apple_authorization.v1",
        request_id: actorID,
        client_id: clientID,
        id_token: "local",
        nonce,
        authorization_code: "local",
        actor_id: actorID,
      }),
    }),
    {} as never,
  );
  assert(response.status === 400);
});
Deno.test("Apple bind replays a committed code without exchanging it again", async () => {
  const { handleBindAppleAuthorization } = await import(
    "../bind-apple-authorization/index.ts"
  );
  const f = await fixture();
  const calls: string[] = [];
  const database = {
    rpc<T>(name: string): Promise<T> {
      calls.push(name);
      return Promise.resolve(
        (name === "wali_edge_begin_apple_authorization_v1"
          ? { status: "bound", revision: 2, lease_token: null }
          : { allowed: true }) as T,
      );
    },
  };
  const response = await handleBindAppleAuthorization(
    new Request("https://local.example/bind", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        api_version: "apple_authorization.v1",
        request_id: actorID,
        client_id: clientID,
        id_token: await f.token(),
        nonce,
        authorization_code: "local",
      }),
    }),
    {
      database,
      authenticate: () =>
        Promise.resolve({
          actorID,
          assuranceLevel: "aal1",
          accessToken: "local",
          expiresAt: 9999999999,
        }),
      now: () => now,
      fetcher: f.fetcher,
      supabaseURL: "https://local.example",
      publishableKey: "local",
      serviceRoleKey: "local",
    },
    () => f.config,
  );
  assert(response.status === 200);
  assert(!f.calls.some((c) => c.url.endsWith("/auth/token")));
});

Deno.test("Apple binding requires provider-verified Supabase authentication before custody access", async () => {
  const { handleBindAppleAuthorization } = await import(
    "../bind-apple-authorization/index.ts"
  );
  const { authenticate } = await import("../_shared/auth.ts");
  const body = {
    api_version: "apple_authorization.v1",
    request_id: actorID,
    client_id: clientID,
    id_token: "local",
    nonce,
    authorization_code: "local",
  };
  let calls = 0;
  const fetcher = (() => {
    calls++;
    return Promise.resolve(new Response(null, { status: 401 }));
  }) as typeof fetch;
  const dependencies = {
    database: {
      rpc<T>(): Promise<T> {
        throw new Error("Unauthenticated database access");
      },
    },
    authenticate: (request: Request) =>
      authenticate(request, {
        supabaseURL: "https://local.example",
        publishableKey: "local",
      }, fetcher),
    now: () => now,
    fetcher,
    supabaseURL: "https://local.example",
    publishableKey: "local",
    serviceRoleKey: "local",
  };
  for (const authorization of [undefined, "Bearer invalid-local-token"]) {
    const response = await handleBindAppleAuthorization(
      new Request("https://local.example/bind", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          ...(authorization ? { authorization } : {}),
        },
        body: JSON.stringify(body),
      }),
      dependencies,
      () => {
        throw new Error("Unauthenticated secret access");
      },
    );
    assert(response.status === 401);
  }
  assert(calls === 1);
});

Deno.test("Apple signing configuration cannot cross native clients", async () => {
  const f = await fixture();
  const wrongClient = { ...f.config, clientID: "com.wali.store.WALI" };
  await rejects(() =>
    exchangeAppleAuthorization(
      {
        actorID,
        clientID,
        appleSubject: "local-apple-subject",
        authorizationCode: "local-code",
        nonce,
      },
      wrongClient,
      f.fetcher,
      now,
    )
  );
  assert(f.calls.length === 0);
});

Deno.test("Apple environment uses separate keys for each approved primary App ID", async () => {
  const f = await fixture();
  const values: Record<string, string> = {
    WALI_APPLE_STORE_KEY_ID: "STOREKEY01",
    WALI_APPLE_STORE_PRIVATE_KEY_P8: f.config.privateKeyP8,
    WALI_APPLE_DEVELOPMENT_KEY_ID: "DEVKEY0001",
    WALI_APPLE_DEVELOPMENT_PRIVATE_KEY_P8: f.config.privateKeyP8,
    WALI_APPLE_CREDENTIAL_KEY_VERSION: f.config.encryptionKeyVersion,
    WALI_APPLE_CREDENTIAL_KEY_BASE64: btoa(
      String.fromCharCode(...f.config.encryptionKey),
    ),
  };
  const previous = new Map(
    Object.keys(values).map((name) => [name, Deno.env.get(name)]),
  );
  try {
    for (const [name, value] of Object.entries(values)) {
      Deno.env.set(name, value);
    }
    const store = appleAuthorizationConfigurationFromEnvironment(
      "com.wali.store.WALI",
    );
    const development = appleAuthorizationConfigurationFromEnvironment(
      clientID,
    );
    assert(
      store.clientID === "com.wali.store.WALI" && store.keyID === "STOREKEY01",
    );
    assert(
      development.clientID === clientID && development.keyID === "DEVKEY0001",
    );
    Deno.env.delete("WALI_APPLE_STORE_KEY_ID");
    await rejects(() =>
      appleAuthorizationConfigurationFromEnvironment("com.wali.store.WALI")
    );
    assert(
      appleAuthorizationConfigurationFromEnvironment(clientID).keyID ===
        "DEVKEY0001",
    );
    await rejects(() =>
      appleAuthorizationConfigurationFromEnvironment("io.lokus.app")
    );
  } finally {
    for (const [name, value] of previous) {
      if (value === undefined) Deno.env.delete(name);
      else Deno.env.set(name, value);
    }
  }
});

Deno.test("Apple exchange accepts the documented lowercase bearer token type", async () => {
  const f = await fixture();
  f.setTokenType("bearer");
  const binding = await exchangeAppleAuthorization(
    {
      actorID,
      clientID,
      appleSubject: "local-apple-subject",
      authorizationCode: "local-code",
      nonce,
    },
    f.config,
    f.fetcher,
    now,
  );
  await revokeAppleAuthorization(binding, f.config, f.fetcher);
  assert(f.calls.some((call) => call.url.endsWith("/auth/revoke")));
});
