# Catalog signing-key rotation

**Owner:** signing operator
**Approver:** security responder

**Readiness gate:** rotation contracts and client verification exist locally;
the production signing boundary, recovery key, transition publication path,
adoption evidence, and staging exercise are external release gates.

Catalog Ed25519 private keys stay outside the database, worker image, app, and
ordinary backups. The database stores key IDs and public lifecycle metadata.

## Planned rotation

1. Freeze unrelated publish changes and record the current key ID and latest
   signed revocation-list revision.
2. Generate the new key in the approved signing boundary. Export only its raw
   public key and immutable key ID.
3. Publish a cumulative higher-revision trust transition signed by an active
   compiled primary or recovery anchor. Keep both public keys accepted for the
   documented overlap window. Never sign the transition only with a key that
   clean released clients have not compiled.
4. Deploy clients/agents containing the new trust set and measure adoption
   without collecting local wallpaper assignments.
5. Sign a synthetic staging release with the new key and verify install,
   offline playback, revocation, and rollback on a supported old and new client.
6. Switch production signing to the new key. Stop new signatures with the old
   key, but retain its public key while valid historical releases require it.
7. Mark the old key retired only after the overlap and restore drills pass.

Never reuse a key ID, overwrite a public key for an existing ID, or call a
private-key copy a rotation. For suspected disclosure, use
[Signing-key compromise](signing-key-compromise.md).
