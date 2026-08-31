.DEFAULT_GOAL := build

.PHONY: generate build development test check-architecture verify-bundle verify clean
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

clean:
	rm -rf .build build WALI.xcodeproj \
		Packages/WALICore/.build Packages/WALICore/.swiftpm Config/Generated

