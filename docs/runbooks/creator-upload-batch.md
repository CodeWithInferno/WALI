# Ordinary Creator batch upload

The bounded `scripts/creator-upload-batch.py` uses a real verified-email account
at AAL1 and the public Creator endpoints. The account must already have accepted
the current Creator Terms in the native app. The tool has no terms acceptance,
human review, admin, signing, or publication command. Server processing and the
automatic publication dispatcher continue after it exits.

The manifest schema is `wali.creator_upload.batch.v1`, pinned to production
project `afgxvhhubqzgpijcstsv`, with at most 24 licensed video items. Conversion
from the approved staff batch preserves file path/hash/size, title, category,
license, source, rights holder, and credit; it only changes the document schema
and `attestation_version` to `creator_terms_version`. Source media is never
changed or removed.

```sh
python3 scripts/creator-upload-batch.py validate \
  --project-ref afgxvhhubqzgpijcstsv \
  --manifest /private/path/creator-batch.json \
  --media-root /private/path/source-videos
```

For `upload`, pass the same manifest/root and an explicitly expected account
UUID, private receipt directory, public production configuration, and inherited
pipe descriptor via `--token-fd`. The caller supplies the user's existing access
token through that pipe; a regular token file, command-line token, privileged
service token, cross-project origin, redirect, or unauthenticated JWT assertion
is refused. Tokens are never stored in receipts or printed.

```sh
python3 scripts/creator-upload-batch.py upload \
  --project-ref afgxvhhubqzgpijcstsv \
  --manifest /private/path/creator-batch.json \
  --media-root /private/path/source-videos \
  --expected-subject ACTUAL_ACCOUNT_UUID \
  --receipt-dir /private/path/creator-receipts \
  --config /private/path/Marketplace.production.json \
  --token-fd 3 --wait-seconds 900
```

The invoking process must supply FD3 as a private pipe. `--item UUID` selects one
item. `--exclude-item UUID` skips a specifically known native upload; it creates
no receipt or success claim for that item. Without selection, the tool processes
the manifest in order. `--wait-seconds` is a 0–3600-second total budget for
server processing-capacity backpressure, checked every 30 seconds; other errors
stop safely. Re-run with the same receipts and a fresh token for the same account
to resume. Each receipt binds account, project, file and full metadata, uses
private atomic writes and a per-item lock, and keeps exact idempotency identities.

`status` reads only the owner's `creator_processing_status_v1` projection for
submissions already recorded by this tool. `processing` means admitted, not
published. Only an observed `published` state is reported as such. Failed
publication may require the native Retry action; failed media needs corrected
source. This tool neither invents results nor overrides either failure.

TUS reconciliation verifies destination, source hashes, inode/size/time state,
length, offset and pending chunk identity. An ambiguous PATCH resumes using HEAD;
an ambiguous completion replays its original metadata and idempotency key.
Offline tests use synthetic HTTP/media and do not prove a production upload.
