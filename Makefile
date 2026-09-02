.DEFAULT_GOAL := build

.PHONY: generate build development test check-architecture verify-bundle verify clean \
	backend-start backend-stop backend-reset backend-test backend-lint marketplace-contracts \
	worker-test classifier-test sandbox-test edge-test marketplace-verify licenses sbom
.NOTPARALLEL: verify

generate:
	./scripts/generate.sh

build:
	./scripts/build.sh

development:
	CONFIGURATION=Development ./scripts/build.sh

test:
	./scripts/test.sh

check-architecture:
	./scripts/check-architecture.sh

verify-bundle:
	./scripts/verify-bundle.sh

verify:
	./scripts/verify.sh

backend-start:
	supabase start

backend-stop:
	supabase stop

backend-reset: backend-start
	supabase db reset --local

backend-test: backend-start
	supabase test db

backend-lint: backend-start
	supabase db lint --local --level warning --fail-on error

marketplace-contracts:
	ruby scripts/check-marketplace-contracts.rb

worker-test:
	cd Services/WALIMediaWorker && go vet ./... && go test -race ./...

classifier-test:
	cd Services/WALIClassifier && uv lock --check && uv run --frozen pytest

sandbox-test:
	./Services/WALIMediaSandbox/tests/run-corpus.sh

edge-test:
	deno fmt --check supabase/functions
	deno check supabase/functions/*/index.ts supabase/functions/tests/*.ts
	deno lint supabase/functions
	deno test --allow-env --allow-net=127.0.0.1 supabase/functions/tests

licenses:
	./scripts/check-licenses.sh

sbom:
	./scripts/generate-sbom.sh

marketplace-verify: marketplace-contracts backend-test backend-lint edge-test worker-test classifier-test sandbox-test licenses

clean:
	rm -rf .build build WALI.xcodeproj \
		Packages/WALICore/.build Packages/WALICore/.swiftpm Config/Generated
