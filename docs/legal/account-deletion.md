# WALI Account Deletion

**Version:** 2026-09-01

**Status:** Draft target; not publicly enabled. The development build includes
native request/status UI and the local backend includes queue, private-object
cleanup, and database pseudonymization primitives. Hosted processing, fresh MFA,
session revocation, and operator-owned Auth identity cleanup still require an
exercised deployment. Processing that ends at `awaiting_auth_cleanup` must not
be presented as completed.

Once every gate above is enabled, signed-in users will be able to request
deletion from WALI’s native Account screen. The request will require a fresh
authenticated session and return a receipt; it will never ask the user to email
a password or service token.

The completed workflow must revoke sessions, remove or anonymize profile and
engagement data, delist creator content when required, schedule eligible private
objects for deletion, and preserve only records required for security,
copyright, fraud prevention, financial/legal obligations, or bounded backup
retention. Rights-proof objects enter this scope only if the separate proof
workflow is enabled. Public attribution is removed when legally and technically
possible.

Local wallpapers and settings on the Mac are separate. Deleting a marketplace
account does not delete local files. The app must clearly show the exact
server-side scope, a confirmation step, request status, and final completion or
retention exceptions.
