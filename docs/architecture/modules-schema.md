# Module Manifest Schema

[`modules.yml`](modules.yml) is the machine-readable registry for WALI module
presence, source ownership, import policy, build targets, and graph transitions.
Schema version 3 deliberately separates checked-in facts from target
responsibilities.

## Runtime dependency

`scripts/check-architecture.sh` requires the macOS system
`/usr/bin/ruby` and Ruby's standard-library Psych YAML parser. Package authority
also requires `swift package dump-package`; import authority requires
`xcrun swiftc -frontend -dump-parse`. The wrapper checks these Apple-toolchain
dependencies. No gem or third-party package is required, and the checker does
not require `rg`. Shared target templates additionally require the supported
XcodeGen executable (`XCODEGEN_BIN` or `xcodegen`) to resolve included specs.
The lossless JSON output retains package product names; the policy resolver
applies XcodeGen dictionary, array, and `:REPLACE` target-template merge rules.

Psych's AST is inspected before object construction so duplicate mapping keys
are rejected rather than silently resolved with last-write-wins behavior.

## Document fields

- `schema_version`: integer `3`.
- `schema_document`: repository-relative path to this document.
- `swift_packages`: package-reference registry described below.
- `xcode_test_targets`: explicit registry of current Xcode test targets.
- `modules`: mapping keyed by unique module ID.
- `edges`: `current` and `target` mappings, each containing separate `build`,
  `package`, and `embed_only` edge arrays.

An edge contains only `from` and `to` module IDs. Current edges may reference
only current modules. Target edges may reference current or planned modules;
neither phase may reference an absent module. The union of build, package, and
embed-only edges must be acyclic in each phase.

Edge meanings:

- `build`: an Xcode target dependency that links/builds another internal Xcode
  target.
- `package`: an Xcode module dependency on a declared Swift package product.
  Swift package target-to-target dependencies live in
  `swift_packages`, not this edge list.
- `embed_only`: bundle containment with `embed: true` and `link: false`; it is
  not a source import or ordinary link dependency.

Before the marketplace helper lands, the containment set is `WALI -> WALIAgent`
and `WALIAgent -> WALITranscoder`. The accepted target additionally contains
`WALILockScreenHelper` directly in `WALI`; it never contains the transcoder or
imports agent implementation. The checker also requires XcodeGen copy
destinations `Contents/Library/LoginItems` and `Contents/XPCServices`,
respectively, with nested code signing enabled. A matching manifest and project
are still rejected if they jointly assign the transcoder to the main app.

IPC is inventoried in the compatibility manifest because it is a versioned
external surface, not a compile edge.

## Xcode test-target authority

Every Xcode test target in `project.yml` is declared under
`xcode_test_targets` with its exact `type`, `source_path`,
`build_dependencies`, and `package_dependencies`. These declarations are
checked against the project but are not production modules or current graph
edges. Unknown test targets, missing declared tests, and every unregistered
non-test production target fail closed. Duplicate project dependency
declarations fail before graph edges are converted to sets. Unit-test build and
package dependencies must also equal the internal modules directly imported by
their source; UI-test application dependencies are composition dependencies and
are checked against the project registry instead.

## Swift package authority

Each `swift_packages` entry distinguishes:

- `xcodegen_reference`: the name/path pair declared under `project.yml`
  `packages`;
- `current.products`: products that exist in the current `Package.swift`;
- `current.targets`: current package targets, package-relative source paths,
  kinds, and target dependencies; and
- parallel `target.products`/`target.targets` declarations for the retained
  boundary.

Products declare `kind: library`, `linkage: static`, and target names. In
schema version 3, every product exports exactly one production (`regular` or
`executable`) target, and every production target is exported by exactly one
product. Aggregate products, aliases, and shared production targets have no
schema representation and therefore fail closed. Targets declare `kind`
(`regular`, `executable`, or `test`), package-relative `path`, and internal
target `dependencies`.

`swift_packages.<package>.<phase>.targets[*].dependencies` is the single
authority for package-target dependencies. A top-level `edges.*.package` entry
may connect an Xcode module to a package product, but may not duplicate a
package-target dependency. The checker cross-checks each package module's
current/target allowed internal imports against this canonical target list.
Every XcodeGen package dependency names its product explicitly.

Every library product subject has a `<Subject>Tests` target at
`Tests/<Subject>Tests` depending exactly on the subject. The current package has
the static products `WALIModel`, `WALIWire`, `WALIEngine`, and `WALICatalog`,
plus their matching test targets. `WALICatalog` depends only on `WALIModel`
internally and may import only Foundation/CryptoKit from the platform. The
package reference and folder may remain
named `WALICore`; no product or target may use that retired module name.

The checker invokes:

```bash
swift package dump-package --package-path Packages/WALICore
```

It parses the JSON and requires the current product/target sets, static product
linkage, product membership, target kind/path, and target dependencies to match
the manifest exactly. Unknown or missing products/targets fail closed. Current
and target package target graphs must be acyclic. The retained target
declarations are structural and must equal the Task 3 boundary; the current
declarations are also compared directly with `Package.swift`.

## Module fields

Every module entry requires:

- `presence`: `current`, `planned`, or `absent`.
- `source_path`: repository-relative source directory.
- `owner_role`: controlled role ID from `GOVERNANCE.md`.
- `stability`: `stable_contract`, `stable_interface`, `adapter`, or
  `transitional`.
- `current_capabilities`: concrete checked-in capabilities only.
- `target_responsibility`: intended architectural responsibility.
- `current_target`: current build target descriptor or `null`.
- `target_target`: target build descriptor or `null` when the module will be
  removed.
- `current_allowed_internal_imports`: internal modules source may import now.
- `target_allowed_internal_imports`: imports permitted after the transition.
- `current_allowed_internal_reexports`: internal modules source may re-export
  now through `@_exported import`.
- `target_allowed_internal_reexports`: re-exports permitted after the
  transition.
- `forbidden_frameworks`: framework/module imports forbidden in the current
  source path.

A current capability names concrete checked-in behavior, not a planned
responsibility. WALIModel's Task 4 capability entries cover validated immutable
records and its two pure package-scoped reducers; they do not imply Engine,
wire, persistence, filesystem, or worker behavior. WALIModel also lists
`Foundation` as forbidden so its identifiers, schema values, and reducers stay
standard-library-only.

A target descriptor has `build_system` (`xcode` or `swift_package`), `name`
(equal to the module ID), and `type`. A Swift package descriptor additionally
names its `package_reference`, exported `product`, and implementation `target`;
those are separate identifiers. The named product must export the named target,
and, without an explicit alias model in this schema, the target must equal the
module ID. In the split package, only the package reference spells `WALICore`.

## Presence rules

Current modules:

- have a nonempty `current_capabilities` list;
- have an existing source directory and a `current_target`;
- enforce current allowed imports, re-exports, and forbidden frameworks; and
- when represented in `project.yml`, match target name, type, source path,
  build dependencies, package dependencies, and embed-only dependencies.

Planned modules:

- have no current capabilities, current imports/re-exports, current target, or
  checked-in source directory;
- have a target responsibility and target target; and
- are validated structurally but are not enforced as current build targets or
  imports.

Creating a planned source directory requires changing its presence and current
facts in the same change. The checker never treats target permissions as
current permissions.

Accepted marketplace target modules are `WALICatalogRuntime`,
`WALILockScreenHelperRuntime`, and `WALILockScreenHelper`. The catalog runtime
may import `WALICatalog` internally and owns external Supabase transport. The
Lock Screen helper runtime may import only `WALIModel` and `WALIWire` internally;
its composition root imports only that runtime. Static policy additionally
rejects the forbidden media/network/UI/database/scripting frameworks and APIs
recorded in `modules.yml` and `docs/security/dependency-policy.yml`.

Absent modules:

- have no source directory, capabilities, current/target imports or
  re-exports, or current/target descriptor; and
- remain registered only to make retirement explicit and reject stale imports
  or graph edges.

## Swift import authority

The checker does not scan source text. For each current Swift file it requires a
successful Apple Swift parser run:

```bash
xcrun swiftc -frontend -dump-parse path/to/File.swift
```

It extracts `import_decl module="..."` nodes and the Swift frontend's
`exported` marker from parser output. Scoped parser values such as
`Foundation.URL` are normalized to their root module for policy comparison
while the complete parser value remains in diagnostics. This covers
ordinary/scoped imports; `private`, `fileprivate`, `internal`, `package`, and
`public` access; and `@_exported`, `@preconcurrency`, and
`@_implementationOnly` attributes without mistaking comments or multiline
strings for imports. Parser failure is an architecture-check failure.

The parsed internal-import set must equal
`current_allowed_internal_imports`; both unauthorized imports and missing
declared imports fail. An `@_exported import` contributes both a normal import
edge and a distinct re-export edge. Internal re-exports fail unless named by
the module's explicit phase-specific re-export allowlist, which must be a
subset of its corresponding import allowlist. Every current WALI re-export
allowlist is empty. A module in `forbidden_frameworks` is rejected regardless
of source spelling. Any policy that forbids `SQLite3` must also forbid
`CoreData` and `SwiftData`.

## Change procedure

Update the manifest and focused mutation fixtures before changing source or
`project.yml`. Current graph changes require an accepted ADR. Target-only
changes still require architectural review when they change ownership,
dependency direction, or a security boundary.

## Distribution graph authority

`distributions.direct` names `project.yml`, generated `WALI.xcodeproj`, and the
existing Debug/Development/Release configurations. The top-level current/target
module and edge registry continues to describe this direct distribution.
Its `identity_policy_adr` references
`docs/adr/0020-direct-release-identifier-namespace.md`, the accepted direct
Release namespace policy. Its `release_policy_adr` references
`docs/adr/0022-direct-production-email-otp-authentication.md`, the accepted
production email-authentication and explicit local-preview policy. ADR 0021's
Developer ID entitlement restriction remains in force outside its superseded
local-only activation condition.

`distributions.store` records `project-store.yml`, `WALIStore.xcodeproj`, exact
StoreDevelopment/AppStore configurations, the eight shared production targets,
three excluded helper modules, the excluded agent `LockScreen/**` source tree,
and required `WALI_APP_STORE` condition. It references accepted ADR 0018 and
keeps its signed feasibility gate pending. These declarations are checked
against fixed policy, then against the resolved Store graph and entitlements.
The Store targets must retain every direct dependency except helper-only code;
containment is exactly WALI → WALIAgent → WALITranscoder. The Store test graph
omits the helper target and mixed direct helper test file; other suites retain
the same module names and compile with the Store condition.

`WALILockScreenWire` is a static Foundation-only product with no package edges.
It preserves the direct helper selector/DTO contract. It is never a Store
link dependency. Generation, graph mutation checks, and actual Mach-O scans are
separate evidence; unsigned artifacts do not prove signed sandbox behavior.
