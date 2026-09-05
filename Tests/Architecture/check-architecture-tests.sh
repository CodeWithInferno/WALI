#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${REPOSITORY_ROOT}/scripts/check-architecture.sh"
MARKETPLACE_CHECKER="${REPOSITORY_ROOT}/scripts/check-marketplace-contracts.rb"
RUBY_BIN="/usr/bin/ruby"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEMP_ROOT}"' EXIT

pass_count=0
failure_count=0

contains_text() {
    "${RUBY_BIN}" -e \
        'exit(File.read(ARGV.fetch(0)).include?(ARGV.fetch(1)) ? 0 : 1)' \
        "$1" "$2"
}

mutate_yaml() {
    local path="$1"
    local mutation="$2"

    "${RUBY_BIN}" -rpsych -e '
        path, mutation = ARGV
        data = Psych.safe_load(File.read(path), aliases: false)
        eval(mutation, binding, path)
        File.write(path, Psych.dump(data))
    ' "${path}" "${mutation}"
}

replace_text() {
    local path="$1"
    local old="$2"
    local new="$3"

    "${RUBY_BIN}" -e '
        path, old, replacement = ARGV
        text = File.read(path)
        abort("missing fixture text: #{old}") unless text.include?(old)
        File.write(path, text.sub(old, replacement))
    ' "${path}" "${old}" "${new}"
}

new_fixture() {
    local name="$1"
    local root="${TEMP_ROOT}/${name}"

    mkdir -p \
        "${root}/Packages/WALICore/Sources/WALIModel" \
        "${root}/Packages/WALICore/Sources/WALIWire" \
        "${root}/Packages/WALICore/Sources/WALIEngine" \
        "${root}/Packages/WALICore/Tests/WALIModelTests" \
        "${root}/Packages/WALICore/Tests/WALIWireTests" \
        "${root}/Packages/WALICore/Tests/WALIEngineTests" \
        "${root}/Sources/WALIApp" \
        "${root}/Sources/WALIAppRuntime" \
        "${root}/Sources/WALIAgent" \
        "${root}/Sources/WALIAgentRuntime" \
        "${root}/Sources/WALILockScreenHelper" \
        "${root}/Sources/WALILockScreenHelperRuntime" \
        "${root}/Sources/WALITranscoder" \
        "${root}/Sources/WALITranscoderRuntime" \
        "${root}/Sources/WALIUI" \
        "${root}/Tests/WALIAppTests" \
        "${root}/Tests/WALILockScreenHelperTests" \
        "${root}/Config" \
        "${root}/.cursor/rules" \
        "${root}/docs/architecture" \
        "${root}/docs/compatibility" \
        "${root}/docs/adr" \
        "${root}/Fixtures/Compatibility" \
        "${root}/Fixtures/LockScreen"

    printf 'package enum WALIModelModule { package static let name = "WALIModel" }\n' > \
        "${root}/Packages/WALICore/Sources/WALIModel/Model.swift"
    printf 'import WALIModel\npackage enum WALIWireModule { package static let model = WALIModelModule.name }\n' > \
        "${root}/Packages/WALICore/Sources/WALIWire/Wire.swift"
    printf 'import WALIModel\npackage enum WALIEngineModule { package static let model = WALIModelModule.name }\n' > \
        "${root}/Packages/WALICore/Sources/WALIEngine/Engine.swift"
    printf 'import Testing\n@testable import WALIModel\n@Test func modelMarker() {}\n' > \
        "${root}/Packages/WALICore/Tests/WALIModelTests/ModelTests.swift"
    printf 'import Testing\n@testable import WALIWire\n@Test func wireMarker() {}\n' > \
        "${root}/Packages/WALICore/Tests/WALIWireTests/WireTests.swift"
    printf 'import Testing\n@testable import WALIEngine\n@Test func engineMarker() {}\n' > \
        "${root}/Packages/WALICore/Tests/WALIEngineTests/EngineTests.swift"
    printf 'import SwiftUI\nimport WALIAppRuntime\n' > "${root}/Sources/WALIApp/App.swift"
    printf 'import SwiftUI\nimport WALIModel\nimport WALIWire\nimport WALIUI\n' > \
        "${root}/Sources/WALIAppRuntime/App.swift"
    printf 'import SwiftUI\nimport WALIAgentRuntime\n' > "${root}/Sources/WALIAgent/Agent.swift"
    printf 'import SwiftUI\nimport WALIModel\nimport WALIWire\nimport WALIEngine\nimport WALICatalog\nimport WALIUI\n' > \
        "${root}/Sources/WALIAgentRuntime/Agent.swift"
    printf 'import WALILockScreenHelperRuntime\n' > \
        "${root}/Sources/WALILockScreenHelper/Helper.swift"
    printf 'import Foundation\nimport WALIWire\n' > \
        "${root}/Sources/WALILockScreenHelperRuntime/HelperRuntime.swift"
    printf 'import WALITranscoderRuntime\n' > "${root}/Sources/WALITranscoder/Transcoder.swift"
    printf 'import Foundation\nimport WALIModel\nimport WALIWire\n' > \
        "${root}/Sources/WALITranscoderRuntime/Transcoder.swift"
    printf 'import SwiftUI\nimport WALIModel\n' > "${root}/Sources/WALIUI/UI.swift"
    printf 'import XCTest\n@testable import WALIAppRuntime\n' > \
        "${root}/Tests/WALIAppTests/WALIAppTests.swift"
    printf 'import XCTest\n@testable import WALILockScreenHelperRuntime\nimport WALIWire\n' > \
        "${root}/Tests/WALILockScreenHelperTests/HelperTests.swift"
    printf '{"fixture":"golden"}\n' > \
        "${root}/Fixtures/Compatibility/model-records-v1.json"
    printf '{"fixture":"invalid"}\n' > \
        "${root}/Fixtures/Compatibility/model-records-invalid-v1.json"
    cat > "${root}/Fixtures/LockScreen/modern-aerial-v1.json" <<'EOF'
{"epoch":1,"revision":1,"verified_system_build":"25F80","manifest":{"version":1,"categories":[{"id":"57414C49-0000-4000-8000-000000000001","representativeAssetID":"11111111-2222-4333-8444-555555555555","previewImage":"file:///REDACTED/preview.png","subcategories":[{"id":"57414C49-0000-4000-8000-000000000002","representativeAssetID":"11111111-2222-4333-8444-555555555555","previewImage":"file:///REDACTED/preview.png"}]}],"assets":[{"id":"11111111-2222-4333-8444-555555555555","shotID":"CUSTOM_WALI_11111111_2222_4333_8444_555555555555","categories":["57414C49-0000-4000-8000-000000000001"],"subcategories":["57414C49-0000-4000-8000-000000000002"],"localizedNameKey":"Synthetic","accessibilityLabel":"Synthetic","showInTopLevel":true,"includeInShuffle":true,"preferredOrder":0,"pointsOfInterest":{"0":"CUSTOM_WALI_11111111_2222_4333_8444_555555555555_0"},"url-4K-SDR-240FPS":"file:///REDACTED/video.mov","previewImage":"file:///REDACTED/preview.png"}]},"wallpaper_index":{"provider":"com.apple.wallpaper.choice.aerials","configuration":{"assetID":"11111111-2222-4333-8444-555555555555"},"configuration_encoding":"binary-plist-data","selection_policy":"main_display_single_asset","managed_root_values":["AllSpacesAndDisplays","SystemDefault","Displays","Spaces"],"global_linked_node":{"Type":"linked","Linked":{"Content":{"Choices":[{"Configuration":{"assetID":"11111111-2222-4333-8444-555555555555"},"Files":[],"Provider":"com.apple.wallpaper.choice.aerials"}],"EncodedOptionValues":"REDACTED_BINARY_PLIST_DATA","Shuffle":"$null"},"LastSet":"REDACTED_DATE","LastUse":"REDACTED_DATE"}},"active_override_maps":{"Displays":{},"Spaces":{}},"mutable_node_patterns":["AllSpacesAndDisplays","SystemDefault","Displays","Spaces"],"preserved_global_fields":["Linked/Content/EncodedOptionValues","Linked/Content/Shuffle"],"daemon_timestamp_drift_fields":["Linked/LastSet","Linked/LastUse"],"rollback_policy":"restore_exact_four_root_preimage"}}
EOF

    cat > "${root}/Config/Base.xcconfig" <<'EOF'
MARKETING_VERSION = 0.1.0
CURRENT_PROJECT_VERSION = 1
WALI_MARKETPLACE_ENABLED = NO
EOF

    cat > "${root}/Config/Debug.xcconfig" <<'EOF'
#include "Base.xcconfig"
WALI_APP_BUNDLE_IDENTIFIER = com.wali.debug.WALI
WALI_AGENT_BUNDLE_IDENTIFIER = com.wali.debug.WALIAgent
WALI_TRANSCODER_BUNDLE_IDENTIFIER = com.wali.debug.WALITranscoder
WALI_APP_GROUP_IDENTIFIER =
WALI_AGENT_CONTROL_SERVICE_NAME = com.wali.debug.WALIAgent.control
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = -
DEVELOPMENT_TEAM =
ENABLE_HARDENED_RUNTIME = NO
EOF

    cat > "${root}/Config/Development.xcconfig" <<'EOF'
#include "Base.xcconfig"
WALI_APP_BUNDLE_IDENTIFIER = com.wali.development.WALI
WALI_AGENT_BUNDLE_IDENTIFIER = com.wali.development.WALIAgent
WALI_TRANSCODER_BUNDLE_IDENTIFIER = com.wali.development.WALITranscoder
WALI_APP_GROUP_IDENTIFIER = group.com.wali.development.shared
WALI_AGENT_CONTROL_SERVICE_NAME = com.wali.development.WALIAgent.control
CODE_SIGN_STYLE = Automatic
CODE_SIGN_IDENTITY = Apple Development
ENABLE_HARDENED_RUNTIME = YES
EOF

    cat > "${root}/Config/Release.xcconfig" <<'EOF'
#include "Base.xcconfig"
WALI_APP_BUNDLE_IDENTIFIER = com.wali.WALI
WALI_AGENT_BUNDLE_IDENTIFIER = com.wali.WALIAgent
WALI_TRANSCODER_BUNDLE_IDENTIFIER = com.wali.WALITranscoder
WALI_APP_GROUP_IDENTIFIER = group.com.wali.shared
WALI_AGENT_CONTROL_SERVICE_NAME = com.wali.WALIAgent.control
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = -
DEVELOPMENT_TEAM =
ENABLE_HARDENED_RUNTIME = YES
EOF

    cat > "${root}/Config/WALI.entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>com.apple.security.application-groups</key>
  <array><string>$(WALI_APP_GROUP_IDENTIFIER)</string></array>
</dict>
</plist>
EOF
    cp "${root}/Config/WALI.entitlements" "${root}/Config/WALIAgent.entitlements"

    cat > "${root}/Packages/WALICore/Package.swift" <<'EOF'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WALICore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WALIModel", type: .static, targets: ["WALIModel"]),
        .library(name: "WALIWire", type: .static, targets: ["WALIWire"]),
        .library(name: "WALIEngine", type: .static, targets: ["WALIEngine"])
    ],
    targets: [
        .target(name: "WALIModel", path: "Sources/WALIModel"),
        .target(name: "WALIWire", dependencies: ["WALIModel"], path: "Sources/WALIWire"),
        .target(name: "WALIEngine", dependencies: ["WALIModel"], path: "Sources/WALIEngine"),
        .testTarget(name: "WALIModelTests", dependencies: ["WALIModel"], path: "Tests/WALIModelTests"),
        .testTarget(name: "WALIWireTests", dependencies: ["WALIWire"], path: "Tests/WALIWireTests"),
        .testTarget(name: "WALIEngineTests", dependencies: ["WALIEngine"], path: "Tests/WALIEngineTests")
    ],
    swiftLanguageModes: [.v6]
)
EOF

    cat > "${root}/.cursor/rules/example.mdc" <<'EOF'
---
description: Fixture rule
alwaysApply: true
---

# Fixture

- Keep this concise.
EOF

    cat > "${root}/project.yml" <<'EOF'
name: WALI
configs:
  Debug: debug
  Development: debug
  Release: release
configFiles:
  Debug: Config/Debug.xcconfig
  Development: Config/Development.xcconfig
  Release: Config/Release.xcconfig
packages:
  WALICore:
    path: Packages/WALICore
targets:
  WALI:
    type: application
    sources:
      - path: Sources/WALIApp
    info:
      properties:
        WALIMarketplaceEnabled: "$(WALI_MARKETPLACE_ENABLED)"
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: "$(WALI_APP_BUNDLE_IDENTIFIER)"
      configs:
        Development:
          CODE_SIGN_ENTITLEMENTS: Config/WALI.entitlements
        Release:
          CODE_SIGN_ENTITLEMENTS: Config/WALI.entitlements
    dependencies:
      - target: WALIAppRuntime
      - target: WALIAgent
        embed: true
        link: false
        codeSign: true
        copy:
          destination: wrapper
          subpath: Contents/Library/LoginItems
  WALIAppRuntime:
    type: framework.static
    sources:
      - path: Sources/WALIAppRuntime
    dependencies:
      - package: WALICore
        product: WALIModel
      - package: WALICore
        product: WALIWire
      - target: WALIUI
  WALIAgent:
    type: application
    sources:
      - path: Sources/WALIAgent
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: "$(WALI_AGENT_BUNDLE_IDENTIFIER)"
      configs:
        Development:
          CODE_SIGN_ENTITLEMENTS: Config/WALIAgent.entitlements
        Release:
          CODE_SIGN_ENTITLEMENTS: Config/WALIAgent.entitlements
    dependencies:
      - target: WALIAgentRuntime
      - target: WALITranscoder
        embed: true
        link: false
        codeSign: true
        copy:
          destination: wrapper
          subpath: Contents/XPCServices
  WALIAgentRuntime:
    type: framework.static
    sources:
      - path: Sources/WALIAgentRuntime
    dependencies:
      - package: WALICore
        product: WALIModel
      - package: WALICore
        product: WALIWire
      - package: WALICore
        product: WALIEngine
      - target: WALIUI
  WALITranscoder:
    type: xpc-service
    sources:
      - path: Sources/WALITranscoder
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: "$(WALI_TRANSCODER_BUNDLE_IDENTIFIER)"
    dependencies:
      - target: WALITranscoderRuntime
  WALITranscoderRuntime:
    type: framework.static
    sources:
      - path: Sources/WALITranscoderRuntime
    dependencies:
      - package: WALICore
        product: WALIModel
      - package: WALICore
        product: WALIWire
  WALIUI:
    type: framework.static
    sources:
      - path: Sources/WALIUI
    dependencies:
      - package: WALICore
        product: WALIModel
  WALIAppTests:
    type: bundle.unit-test
    sources:
      - path: Tests/WALIAppTests
    dependencies:
      - target: WALIAppRuntime
EOF

    printf '# Fixture module schema\n' > "${root}/docs/architecture/modules-schema.md"
    printf '# Fixture compatibility schema\n' > "${root}/docs/compatibility/surfaces-schema.md"

    cat > "${root}/docs/adr/0001-process-topology.md" <<'EOF'
# 0001: Fixture topology

- status: partially_superseded
- date: 2026-08-30
- owner_role: architecture_maintainer
- accepted_by: project_owner_delegation
- approval_reference: founding autonomous architecture mandate
- superseded_by: 0004
- superseded_scope: shared_core_clause,transcoder_host_ambiguity,main_app_authority_fallback

## Context
Fixture.
EOF

    cat > "${root}/docs/adr/0004-engine-owned-use-cases.md" <<'EOF'
# 0004: Fixture engine authority

- status: accepted
- date: 2026-08-30
- owner_role: architecture_maintainer
- accepted_by: project_owner_delegation
- approval_reference: founding autonomous architecture mandate
- supersedes: 0001
- supersedes_scope: shared_core_clause,transcoder_host_ambiguity,main_app_authority_fallback

## Context
Fixture.
EOF

    cat > "${root}/docs/adr/0008-session-lock-aerial-adapter.md" <<'EOF'
# 0008: Fixture lock screen adapter

- status: accepted
- date: 2026-08-31
- owner_role: compatibility_maintainer
- accepted_by: project_owner
- approval_reference: user-directed autonomous implementation mandate 2026-08-31

## Context
Fixture.
EOF

    cat > "${root}/docs/adr/0009-global-linked-lock-screen-activation.md" <<'EOF'
# 0009: Fixture global linked lock screen adapter

- status: partially_superseded
- date: 2026-08-31
- owner_role: compatibility_maintainer
- accepted_by: project_owner
- approval_reference: project-owner global linked activation directive 2026-08-31
- related: 0008
- superseded_by: 0010
- superseded_scope: refresh_only_after_required_mutation

## Context
Fixture.
EOF

    cat > "${root}/docs/adr/0010-restart-lock-screen-playback-on-session-lock.md" <<'EOF'
# 0010: Fixture session lock playback restart

- status: accepted
- date: 2026-09-01
- owner_role: compatibility_maintainer
- accepted_by: project_owner
- approval_reference: project-owner autonomous Lock Screen completion directive 2026-09-01
- supersedes: 0009
- supersedes_scope: refresh_only_after_required_mutation

## Context
Fixture.
EOF

    FIXTURE_ROOT="${root}" "${RUBY_BIN}" -rpsych <<'RUBY'
root = ENV.fetch("FIXTURE_ROOT")

targets = {
  "WALIModel" => ["Packages/WALICore/Sources/WALIModel", "swift_package", "WALIModel", "library.static"],
  "WALIWire" => ["Packages/WALICore/Sources/WALIWire", "swift_package", "WALIWire", "library.static"],
  "WALIEngine" => ["Packages/WALICore/Sources/WALIEngine", "swift_package", "WALIEngine", "library.static"],
  "WALI" => ["Sources/WALIApp", "xcode", "WALI", "application"],
  "WALIAppRuntime" => ["Sources/WALIAppRuntime", "xcode", "WALIAppRuntime", "framework.static"],
  "WALIAgent" => ["Sources/WALIAgent", "xcode", "WALIAgent", "application"],
  "WALIAgentRuntime" => ["Sources/WALIAgentRuntime", "xcode", "WALIAgentRuntime", "framework.static"],
  "WALITranscoder" => ["Sources/WALITranscoder", "xcode", "WALITranscoder", "xpc-service"],
  "WALITranscoderRuntime" => ["Sources/WALITranscoderRuntime", "xcode", "WALITranscoderRuntime", "framework.static"],
  "WALIUI" => ["Sources/WALIUI", "xcode", "WALIUI", "framework.static"]
}

current_imports = {
  "WALIModel" => [],
  "WALIWire" => ["WALIModel"],
  "WALIEngine" => ["WALIModel"],
  "WALI" => ["WALIAppRuntime"],
  "WALIAppRuntime" => ["WALIModel", "WALIWire", "WALIUI"],
  "WALIAgent" => ["WALIAgentRuntime"],
  "WALIAgentRuntime" => ["WALIModel", "WALIWire", "WALIEngine", "WALIUI"],
  "WALITranscoder" => ["WALITranscoderRuntime"],
  "WALITranscoderRuntime" => ["WALIModel", "WALIWire"],
  "WALIUI" => ["WALIModel"]
}

modules = {}
targets.each do |id, (path, system, target_name, type)|
  current_target = {
    "build_system" => system,
    "name" => target_name,
    "type" => type
  }
  if system == "swift_package"
    current_target["package_reference"] = "WALICore"
    current_target["product"] = id
    current_target["target"] = id
  end
  modules[id] = {
    "presence" => "current",
    "source_path" => path,
    "owner_role" => "module_maintainer",
    "stability" => system == "swift_package" ? "stable_contract" : "adapter",
    "current_capabilities" => ["foundation_placeholder"],
    "target_responsibility" => "Fixture target responsibility for #{id}.",
    "current_target" => current_target,
    "target_target" => current_target.dup,
    "current_allowed_internal_imports" => current_imports.fetch(id),
    "target_allowed_internal_imports" => current_imports.fetch(id).dup,
    "current_allowed_internal_reexports" => [],
    "target_allowed_internal_reexports" => [],
    "forbidden_frameworks" => system == "swift_package" ? ["AppKit", "SwiftUI", "SQLite3", "CoreData", "SwiftData"] : []
  }
end

modules["WALICore"] = {
  "presence" => "absent",
  "source_path" => "Packages/WALICore/Sources/WALICore",
  "owner_role" => "architecture_maintainer",
  "stability" => "transitional",
  "current_capabilities" => [],
  "target_responsibility" => "Retired imported module fixture.",
  "current_target" => nil,
  "target_target" => nil,
  "current_allowed_internal_imports" => [],
  "target_allowed_internal_imports" => [],
  "current_allowed_internal_reexports" => [],
  "target_allowed_internal_reexports" => [],
  "forbidden_frameworks" => ["AppKit", "SwiftUI", "SQLite3", "CoreData", "SwiftData"]
}
modules["WALIModel"]["forbidden_frameworks"] << "Foundation"

edge = ->(from, to) { {"from" => from, "to" => to} }
package_products = {
  "WALIModel" => {
    "kind" => "library", "linkage" => "static", "targets" => ["WALIModel"]
  },
  "WALIWire" => {
    "kind" => "library", "linkage" => "static", "targets" => ["WALIWire"]
  },
  "WALIEngine" => {
    "kind" => "library", "linkage" => "static", "targets" => ["WALIEngine"]
  }
}
package_targets = {
  "WALIModel" => {
    "kind" => "regular", "path" => "Sources/WALIModel", "dependencies" => []
  },
  "WALIWire" => {
    "kind" => "regular", "path" => "Sources/WALIWire", "dependencies" => ["WALIModel"]
  },
  "WALIEngine" => {
    "kind" => "regular", "path" => "Sources/WALIEngine", "dependencies" => ["WALIModel"]
  },
  "WALIModelTests" => {
    "kind" => "test", "path" => "Tests/WALIModelTests", "dependencies" => ["WALIModel"]
  },
  "WALIWireTests" => {
    "kind" => "test", "path" => "Tests/WALIWireTests", "dependencies" => ["WALIWire"]
  },
  "WALIEngineTests" => {
    "kind" => "test", "path" => "Tests/WALIEngineTests", "dependencies" => ["WALIEngine"]
  }
}
package_phase = {"products" => package_products, "targets" => package_targets}
swift_packages = {
  "WALICore" => {
    "xcodegen_reference" => {
      "name" => "WALICore",
      "path" => "Packages/WALICore"
    },
    "current" => Marshal.load(Marshal.dump(package_phase)),
    "target" => Marshal.load(Marshal.dump(package_phase))
  }
}
build_edges = -> {
  [
    edge.call("WALI", "WALIAppRuntime"),
    edge.call("WALIAppRuntime", "WALIUI"),
    edge.call("WALIAgent", "WALIAgentRuntime"),
    edge.call("WALIAgentRuntime", "WALIUI"),
    edge.call("WALITranscoder", "WALITranscoderRuntime")
  ]
}
package_edges = -> {
  [
    edge.call("WALIAppRuntime", "WALIModel"),
    edge.call("WALIAppRuntime", "WALIWire"),
    edge.call("WALIAgentRuntime", "WALIModel"),
    edge.call("WALIAgentRuntime", "WALIWire"),
    edge.call("WALIAgentRuntime", "WALIEngine"),
    edge.call("WALITranscoderRuntime", "WALIModel"),
    edge.call("WALITranscoderRuntime", "WALIWire"),
    edge.call("WALIUI", "WALIModel")
  ]
}
embed_edges = -> {
  [
    edge.call("WALI", "WALIAgent"),
    edge.call("WALIAgent", "WALITranscoder")
  ]
}
module_manifest = {
  "schema_version" => 3,
  "schema_document" => "docs/architecture/modules-schema.md",
  "xcode_test_targets" => {
    "WALIAppTests" => {
      "type" => "bundle.unit-test",
      "source_path" => "Tests/WALIAppTests",
      "build_dependencies" => ["WALIAppRuntime"],
      "package_dependencies" => []
    }
  },
  "modules" => modules,
  "swift_packages" => swift_packages,
  "edges" => {
    "current" => {
      "build" => build_edges.call,
      "package" => package_edges.call,
      "embed_only" => embed_edges.call
    },
    "target" => {
      "build" => build_edges.call,
      "package" => package_edges.call,
      "embed_only" => embed_edges.call
    }
  }
}
File.write(File.join(root, "docs/architecture/modules.yml"), Psych.dump(module_manifest))

surface_ids = %w[
  sqlite_schema artifact_manifest model_records app_agent_wire agent_worker_wire
  bundle_identifiers application_group_containers app_agent_service_names agent_worker_service_names
  content_store preferences url_schemes catalog_manifest lock_screen_manifest
  diagnostic_export
]

owners = {
  "sqlite_schema" => "storage_maintainer",
  "artifact_manifest" => "storage_maintainer",
  "model_records" => "domain_maintainer",
  "app_agent_wire" => "ipc_maintainer",
  "agent_worker_wire" => "ipc_maintainer",
  "bundle_identifiers" => "security_responder",
  "application_group_containers" => "security_responder",
  "app_agent_service_names" => "ipc_maintainer",
  "agent_worker_service_names" => "ipc_maintainer",
  "content_store" => "storage_maintainer",
  "preferences" => "agent_runtime_maintainer",
  "url_schemes" => "foreground_runtime_maintainer",
  "catalog_manifest" => "catalog_maintainer",
  "lock_screen_manifest" => "compatibility_maintainer",
  "diagnostic_export" => "diagnostics_maintainer"
}

access = Hash.new { {"readers" => [], "writers" => []} }
access["sqlite_schema"] = {"readers" => ["WALIAgent"], "writers" => ["WALIAgent"]}
access["artifact_manifest"] = {"readers" => ["WALIAgent"], "writers" => ["WALIAgent"]}
access["model_records"] = {"readers" => ["WALIModel"], "writers" => ["WALIModel"]}
access["app_agent_wire"] = {"readers" => ["WALI", "WALIAgent"], "writers" => ["WALI", "WALIAgent"]}
access["agent_worker_wire"] = {"readers" => ["WALIAgent", "WALITranscoder"], "writers" => ["WALIAgent", "WALITranscoder"]}
access["preferences"] = {"readers" => ["WALIAgent"], "writers" => ["WALIAgent"]}
access["lock_screen_manifest"] = {"readers" => ["WALIAgent"], "writers" => ["WALIAgent"]}
access["url_schemes"] = {"readers" => ["WALI"], "writers" => []}
access["diagnostic_export"] = {"readers" => [], "writers" => ["WALIAgent"]}

kinds = {
  "sqlite_schema" => "sqlite_schema",
  "artifact_manifest" => "artifact_manifest",
  "model_records" => "model_records",
  "app_agent_wire" => "wire_channel",
  "agent_worker_wire" => "wire_channel",
  "bundle_identifiers" => "bundle_identity",
  "application_group_containers" => "container_identity",
  "app_agent_service_names" => "service_identity",
  "agent_worker_service_names" => "service_identity",
  "content_store" => "content_store",
  "preferences" => "preferences",
  "url_schemes" => "url_scheme",
  "catalog_manifest" => "catalog_manifest",
  "lock_screen_manifest" => "lock_screen_manifest",
  "diagnostic_export" => "diagnostic_export"
}

surfaces = surface_ids.map do |id|
  implementation =
    if %w[model_records lock_screen_manifest].include?(id)
      "implemented"
    elsif %w[bundle_identifiers application_group_containers agent_worker_service_names].include?(id)
      "configured"
    elsif id == "catalog_manifest"
      "deferred"
    else
      "unimplemented"
    end
  {
    "id" => id,
    "kind" => kinds.fetch(id),
    "owner_role" => owners.fetch(id),
    "implementation" => implementation,
    "version" => {
      "current" => nil,
      "readable_epochs" => [],
      "additive_compatibility" => nil
    },
    "product_compatibility" => {
      "minimum_reader" => nil,
      "minimum_writer" => nil,
      "rollback_readers" => [],
      "rollback_fixture_paths" => []
    },
    "module_access" => access[id],
    "fixture_gate" => {
      "status" => implementation == "implemented" ? "passing" : (implementation == "deferred" ? "deferred" : (implementation == "configured" ? "not_applicable" : "planned")),
      "paths" => if id == "model_records"
        [
          "Fixtures/Compatibility/model-records-v1.json",
          "Fixtures/Compatibility/model-records-invalid-v1.json"
        ]
      elsif id == "lock_screen_manifest"
        ["Fixtures/LockScreen/modern-aerial-v1.json"]
      else
        []
      end
    },
    "details" => {}
  }
end

by_id = surfaces.to_h { |surface| [surface.fetch("id"), surface] }
configurations = %w[Debug Development Release]
by_id["sqlite_schema"]["details"] = {
  "runtime_owner" => "WALIAgent",
  "database_openers" => ["WALIAgent"],
  "migration_policy" => {
    "fixture_requirement" => "every_supported_epoch_revision",
    "unknown_newer" => "reject_before_write",
    "stepwise" => true
  }
}
by_id["artifact_manifest"]["details"] = {
  "trust_authority" => "WALIAgent",
  "checksum_algorithm" => "SHA-256",
  "schema_policy" => "immutable_versioned_manifest",
  "worker_claims" => "untrusted"
}
by_id["model_records"]["details"] = {
  "schema" => {"epoch" => 1, "revision" => 0},
  "coding_semantics" => "logical_record_shape",
  "canonical_bytes" => false,
  "record_roots" => %w[
    artifact asset_release library_item display_record
    device_local_presentation_assignment playback_state durable_job import_job
  ],
  "golden_fixture_paths" => ["Fixtures/Compatibility/model-records-v1.json"],
  "invalid_fixture_paths" => ["Fixtures/Compatibility/model-records-invalid-v1.json"]
}
by_id["model_records"]["version"] = {
  "current" => {"epoch" => 1, "revision" => 0},
  "readable_epochs" => [
    {"epoch" => 1, "minimum_revision" => 0, "maximum_revision" => 0}
  ],
  "additive_compatibility" => "declared_ranges_only"
}
by_id["lock_screen_manifest"]["version"] = {
  "current" => {"epoch" => 1, "revision" => 1},
  "readable_epochs" => [
    {"epoch" => 1, "minimum_revision" => 1, "maximum_revision" => 1}
  ],
  "additive_compatibility" => "declared_ranges_only"
}
by_id["lock_screen_manifest"]["product_compatibility"] = {
  "minimum_reader" => "0.1.0",
  "minimum_writer" => "0.1.0",
  "rollback_readers" => [],
  "rollback_fixture_paths" => []
}
by_id["model_records"]["product_compatibility"] = {
  "minimum_reader" => "0.1.0",
  "minimum_writer" => "0.1.0",
  "rollback_readers" => [],
  "rollback_fixture_paths" => []
}
wire_fields = %w[
  protocol_version message_type message_version request_id idempotency_key
  expected_revision payload_length
]
by_id["app_agent_wire"]["details"] = {
  "direction" => [
    {"from" => "WALI", "to" => "WALIAgent", "message_flow" => "commands"},
    {"from" => "WALIAgent", "to" => "WALI", "message_flow" => "replies_and_snapshots"}
  ],
  "message_catalog" => {
    "status" => "planned",
    "path" => nil,
    "messages" => [],
    "required_envelope_fields" => wire_fields.dup
  }
}
by_id["agent_worker_wire"]["details"] = {
  "direction" => [
    {"from" => "WALIAgent", "to" => "WALITranscoder", "message_flow" => "attempts"},
    {"from" => "WALITranscoder", "to" => "WALIAgent", "message_flow" => "progress_and_claims"}
  ],
  "message_catalog" => {
    "status" => "planned",
    "path" => nil,
    "messages" => [],
    "required_envelope_fields" => wire_fields.dup
  }
}
by_id["bundle_identifiers"]["details"] = {
  "configurations" => {
    "Debug" => {
      "WALI" => "com.wali.debug.WALI",
      "WALIAgent" => "com.wali.debug.WALIAgent",
      "WALITranscoder" => "com.wali.debug.WALITranscoder"
    },
    "Development" => {
      "WALI" => "com.wali.development.WALI",
      "WALIAgent" => "com.wali.development.WALIAgent",
      "WALITranscoder" => "com.wali.development.WALITranscoder"
    },
    "Release" => {
      "WALI" => "com.wali.WALI",
      "WALIAgent" => "com.wali.WALIAgent",
      "WALITranscoder" => "com.wali.WALITranscoder"
    }
  }
}
by_id["application_group_containers"]["details"] = {
  "entitlement_key" => "com.apple.security.application-groups",
  "configurations" => {
    "Debug" => {"WALI" => [], "WALIAgent" => []},
    "Development" => {
      "WALI" => ["group.com.wali.development.shared"],
      "WALIAgent" => ["group.com.wali.development.shared"]
    },
    "Release" => {
      "WALI" => ["group.com.wali.shared"],
      "WALIAgent" => ["group.com.wali.shared"]
    }
  }
}
by_id["app_agent_service_names"]["details"] = {
  "decision_gate" => "adr_0006_signed_lifecycle_spike",
  "configurations" => {
    "Debug" => {
      "current" => [],
      "target" => ["com.wali.debug.WALIAgent.control"]
    },
    "Development" => {
      "current" => [],
      "target" => ["com.wali.development.WALIAgent.control"]
    },
    "Release" => {
      "current" => [],
      "target" => ["com.wali.WALIAgent.control"]
    }
  }
}
by_id["agent_worker_service_names"]["details"] = {
  "decision_gate" => "hardening_task_2",
  "configurations" => {
    "Debug" => {
      "current" => ["com.wali.debug.WALITranscoder"],
      "target" => ["com.wali.debug.WALITranscoder"]
    },
    "Development" => {
      "current" => ["com.wali.development.WALITranscoder"],
      "target" => ["com.wali.development.WALITranscoder"]
    },
    "Release" => {
      "current" => ["com.wali.WALITranscoder"],
      "target" => ["com.wali.WALITranscoder"]
    }
  }
}
by_id["content_store"]["details"] = {
  "current_layout" => nil,
  "target_layout" => "Objects/sha256/<prefix>/<digest>",
  "digest_algorithm" => "SHA-256",
  "publication_scope" => "same_volume_only",
  "publication_primitive" => "no_replace"
}
by_id["preferences"]["details"] = {
  "authority" => "WALIAgent",
  "storage_status" => "unimplemented",
  "current_keys" => [],
  "unknown_newer_policy" => "reject_before_mutation"
}
by_id["url_schemes"]["details"] = {
  "configurations" => configurations.to_h { |configuration| [configuration, []] },
  "mutation_policy" => "validate_and_confirm"
}
by_id["catalog_manifest"]["details"] = {
  "trust_model" => "signed_manifest_required",
  "signature_required" => true,
  "network_status" => "deferred",
  "schema_policy" => "bounded_versioned"
}
by_id["lock_screen_manifest"]["details"] = {
  "support_scope" => "session_lock_screen_only",
  "implementation_gate" => "accepted_adr_0010",
  "fixture_policy" => "redacted_version_gated_store",
  "verified_system_builds" => ["25F80", "25G83"],
  "manifest_version" => 1,
  "provider" => "com.apple.wallpaper.choice.aerials",
  "category_id" => "57414C49-0000-4000-8000-000000000001",
  "subcategory_id" => "57414C49-0000-4000-8000-000000000002",
  "shot_prefix" => "CUSTOM_WALI_",
  "maximum_owned_assets" => 8,
  "unknown_newer_policy" => "reject_before_write",
  "global_default_policy" => "transactional_current_user_linked",
  "selection_policy" => "main_display_single_asset",
  "active_override_policy" => "clear_displays_and_spaces_restore_exact",
  "rollback_policy" => "exact_four_root_preimage_with_conflict_detection",
  "agent_quiesce_policy" => "before_managed_manifest_or_index_write",
  "daemon_timestamp_policy" => "allow_last_set_and_last_use_drift_only",
  "session_lock_refresh_policy" => "restart_active_selection_once_per_distinct_lock"
}
by_id["diagnostic_export"]["details"] = {
  "current_format" => nil,
  "required_redaction" => ["user_paths", "credentials", "private_values", "media_bytes"],
  "excluded_payloads" => ["source_media", "secrets"],
  "lease_required" => true
}

surface_manifest = {
  "schema_version" => 3,
  "schema_document" => "docs/compatibility/surfaces-schema.md",
  "surfaces" => surfaces
}
File.write(File.join(root, "docs/compatibility/surfaces.yml"), Psych.dump(surface_manifest))
RUBY

    # Overlay the current governed marketplace baseline. The synthetic sources
    # remain intentionally tiny, but their direct imports mirror the registered
    # package/build graph so legacy mutation cases exercise one clean baseline.
    mkdir -p \
        "${root}/Packages/WALICore/Sources/WALICatalog" \
        "${root}/Packages/WALICore/Tests/WALICatalogTests" \
        "${root}/Packages/WALICore/Tests/WALIModelTests/Fixtures" \
        "${root}/Sources/WALICatalogRuntime" \
        "${root}/Tests/WALICatalogRuntimeTests" \
        "${root}/Tests/WALIAgentTests" \
        "${root}/Tests/WALITranscoderTests" \
        "${root}/Tests/WALIUITests" \
        "${root}/UITests/WALIEndToEndTests" \
        "${root}/docs/api" \
        "${root}/docs/security" \
        "${root}/Fixtures/Catalog/invalid"
    printf 'import WALIModel\npackage enum WALICatalogModule { package static let model = WALIModelModule.name }\n' > \
        "${root}/Packages/WALICore/Sources/WALICatalog/Catalog.swift"
    printf 'import Testing\n@testable import WALICatalog\n@Test func catalogMarker() {}\n' > \
        "${root}/Packages/WALICore/Tests/WALICatalogTests/CatalogTests.swift"
    printf 'import Foundation\nimport WALICatalog\n' > \
        "${root}/Sources/WALICatalogRuntime/CatalogRuntime.swift"
    printf 'import SwiftUI\nimport WALIModel\nimport WALIWire\nimport WALIUI\nimport WALICatalogRuntime\n' > \
        "${root}/Sources/WALIAppRuntime/App.swift"
    printf 'import XCTest\n@testable import WALIAppRuntime\n@testable import WALICatalogRuntime\nimport WALIUI\nimport WALICatalog\n' > \
        "${root}/Tests/WALIAppTests/WALIAppTests.swift"
    printf 'import XCTest\n@testable import WALICatalogRuntime\nimport WALICatalog\n' > \
        "${root}/Tests/WALICatalogRuntimeTests/CatalogRuntimeTests.swift"
    printf 'import XCTest\n@testable import WALIAgentRuntime\nimport WALIWire\nimport WALIEngine\nimport WALIModel\nimport WALICatalog\n' > \
        "${root}/Tests/WALIAgentTests/AgentTests.swift"
    printf 'import XCTest\n@testable import WALITranscoderRuntime\n' > \
        "${root}/Tests/WALITranscoderTests/TranscoderTests.swift"
    printf 'import XCTest\n@testable import WALIUI\n' > \
        "${root}/Tests/WALIUITests/UITests.swift"
    printf 'import XCTest\n' > "${root}/UITests/WALIEndToEndTests/EndToEndTests.swift"

    cp "${REPOSITORY_ROOT}/project.yml" "${root}/project.yml"
    cp "${REPOSITORY_ROOT}/Packages/WALICore/Package.swift" \
        "${root}/Packages/WALICore/Package.swift"
    cp "${REPOSITORY_ROOT}/docs/architecture/modules.yml" \
        "${root}/docs/architecture/modules.yml"
    cp "${REPOSITORY_ROOT}/docs/compatibility/surfaces.yml" \
        "${root}/docs/compatibility/surfaces.yml"
    cp "${REPOSITORY_ROOT}/docs/api/"*.md "${root}/docs/api/"
    cp "${REPOSITORY_ROOT}/docs/security/marketplace-threat-model.md" \
        "${REPOSITORY_ROOT}/docs/security/data-inventory.yml" \
        "${REPOSITORY_ROOT}/docs/security/media-policy.yml" \
        "${REPOSITORY_ROOT}/docs/security/dependency-policy.yml" \
        "${root}/docs/security/"
    cp "${REPOSITORY_ROOT}/Fixtures/Catalog/manifest-v1.json" \
        "${REPOSITORY_ROOT}/Fixtures/Catalog/manifest-v1.signature" \
        "${REPOSITORY_ROOT}/Fixtures/Catalog/revocations-v1.json" \
        "${root}/Fixtures/Catalog/"
    cp "${REPOSITORY_ROOT}/Fixtures/Catalog/invalid/"*.json \
        "${root}/Fixtures/Catalog/invalid/"
    cp "${REPOSITORY_ROOT}/Packages/WALICore/Tests/WALIModelTests/Fixtures/"*.json \
        "${root}/Packages/WALICore/Tests/WALIModelTests/Fixtures/"
    cp "${REPOSITORY_ROOT}/docs/adr/0008-session-lock-aerial-adapter.md" \
        "${REPOSITORY_ROOT}/docs/adr/0009-global-linked-lock-screen-activation.md" \
        "${REPOSITORY_ROOT}/docs/adr/0010-restart-lock-screen-playback-on-session-lock.md" \
        "${REPOSITORY_ROOT}/docs/adr/0011-supabase-marketplace-control-plane.md" \
        "${REPOSITORY_ROOT}/docs/adr/0012-signed-remote-catalog-releases.md" \
        "${REPOSITORY_ROOT}/docs/adr/0013-separate-full-disk-access-helper.md" \
        "${REPOSITORY_ROOT}/docs/adr/0014-marketplace-schema-and-rls.md" \
        "${REPOSITORY_ROOT}/docs/adr/0015-hostile-media-canonicalization.md" \
        "${REPOSITORY_ROOT}/docs/adr/0016-minimal-engagement-and-ranking-data.md" \
        "${REPOSITORY_ROOT}/docs/adr/0017-marketplace-hevc-main10.md" \
        "${root}/docs/adr/"

    printf '%s\n' "${root}"
}

expect_success() {
    local name="$1"
    local fixture="$2"
    local output="${TEMP_ROOT}/${name}.out"

    if "${CHECKER}" "${fixture}" > "${output}" 2>&1; then
        pass_count=$((pass_count + 1))
    else
        printf 'FAIL: %s expected success\n' "${name}" >&2
        awk '{ print }' "${output}" >&2
        failure_count=$((failure_count + 1))
    fi
}

expect_failure() {
    local name="$1"
    local fixture="$2"
    local expected="$3"
    local output="${TEMP_ROOT}/${name}.out"

    if "${CHECKER}" "${fixture}" > "${output}" 2>&1; then
        printf 'RED GAP: %s expected failure containing: %s\n' "${name}" "${expected}" >&2
        failure_count=$((failure_count + 1))
        return
    fi
    if ! contains_text "${output}" "${expected}"; then
        printf 'RED GAP: %s did not report: %s\n' "${name}" "${expected}" >&2
        awk '{ print }' "${output}" >&2
        failure_count=$((failure_count + 1))
        return
    fi
    pass_count=$((pass_count + 1))
}

new_marketplace_fixture() {
    local name="$1"
    local root="${TEMP_ROOT}/marketplace-${name}"

    mkdir -p \
        "${root}/docs/adr" \
        "${root}/docs/api" \
        "${root}/docs/architecture" \
        "${root}/docs/compatibility" \
        "${root}/docs/security" \
        "${root}/Fixtures/Catalog/invalid" \
        "${root}/Packages/WALICore"
    cp "${REPOSITORY_ROOT}/project.yml" "${root}/project.yml"
    cp "${REPOSITORY_ROOT}/Packages/WALICore/Package.swift" \
        "${root}/Packages/WALICore/Package.swift"
    cp "${REPOSITORY_ROOT}/docs/architecture/modules.yml" \
        "${root}/docs/architecture/modules.yml"
    cp "${REPOSITORY_ROOT}/docs/compatibility/surfaces.yml" \
        "${root}/docs/compatibility/surfaces.yml"
    cp "${REPOSITORY_ROOT}/docs/api/"*.md "${root}/docs/api/"
    cp "${REPOSITORY_ROOT}/docs/security/marketplace-threat-model.md" \
        "${REPOSITORY_ROOT}/docs/security/data-inventory.yml" \
        "${REPOSITORY_ROOT}/docs/security/media-policy.yml" \
        "${REPOSITORY_ROOT}/docs/security/dependency-policy.yml" \
        "${root}/docs/security/"
    cp "${REPOSITORY_ROOT}/docs/adr/0008-session-lock-aerial-adapter.md" \
        "${REPOSITORY_ROOT}/docs/adr/0009-global-linked-lock-screen-activation.md" \
        "${REPOSITORY_ROOT}/docs/adr/0010-restart-lock-screen-playback-on-session-lock.md" \
        "${REPOSITORY_ROOT}/docs/adr/0011-supabase-marketplace-control-plane.md" \
        "${REPOSITORY_ROOT}/docs/adr/0012-signed-remote-catalog-releases.md" \
        "${REPOSITORY_ROOT}/docs/adr/0013-separate-full-disk-access-helper.md" \
        "${REPOSITORY_ROOT}/docs/adr/0014-marketplace-schema-and-rls.md" \
        "${REPOSITORY_ROOT}/docs/adr/0015-hostile-media-canonicalization.md" \
        "${REPOSITORY_ROOT}/docs/adr/0016-minimal-engagement-and-ranking-data.md" \
        "${REPOSITORY_ROOT}/docs/adr/0017-marketplace-hevc-main10.md" \
        "${root}/docs/adr/"
    cp "${REPOSITORY_ROOT}/Fixtures/Catalog/manifest-v1.json" \
        "${REPOSITORY_ROOT}/Fixtures/Catalog/manifest-v1.signature" \
        "${REPOSITORY_ROOT}/Fixtures/Catalog/revocations-v1.json" \
        "${root}/Fixtures/Catalog/"
    cp "${REPOSITORY_ROOT}/Fixtures/Catalog/invalid/"*.json \
        "${root}/Fixtures/Catalog/invalid/"

    printf '%s\n' "${root}"
}

expect_marketplace_success() {
    local name="$1"
    local fixture="$2"
    local output="${TEMP_ROOT}/${name}.out"

    if "${RUBY_BIN}" "${MARKETPLACE_CHECKER}" "${fixture}" > "${output}" 2>&1; then
        pass_count=$((pass_count + 1))
    else
        printf 'FAIL: %s expected marketplace success\n' "${name}" >&2
        awk '{ print }' "${output}" >&2
        failure_count=$((failure_count + 1))
    fi
}

expect_marketplace_failure() {
    local name="$1"
    local fixture="$2"
    local expected="$3"
    local output="${TEMP_ROOT}/${name}.out"

    if "${RUBY_BIN}" "${MARKETPLACE_CHECKER}" "${fixture}" > "${output}" 2>&1; then
        printf 'RED GAP: %s expected marketplace failure containing: %s\n' \
            "${name}" "${expected}" >&2
        failure_count=$((failure_count + 1))
        return
    fi
    if ! contains_text "${output}" "${expected}"; then
        printf 'RED GAP: %s did not report: %s\n' "${name}" "${expected}" >&2
        awk '{ print }' "${output}" >&2
        failure_count=$((failure_count + 1))
        return
    fi
    pass_count=$((pass_count + 1))
}

clean_fixture="$(new_fixture clean)"
expect_success "clean architecture" "${clean_fixture}"

missing_modules_fixture="$(new_fixture missing-modules)"
rm "${missing_modules_fixture}/docs/architecture/modules.yml"
expect_failure "missing modules manifest" "${missing_modules_fixture}" "missing docs/architecture/modules.yml"

malformed_modules_fixture="$(new_fixture malformed-modules)"
printf '\nbroken: [\n' >> "${malformed_modules_fixture}/docs/architecture/modules.yml"
expect_failure "malformed modules YAML" "${malformed_modules_fixture}" "modules.yml is invalid YAML"

duplicate_modules_fixture="$(new_fixture duplicate-modules)"
printf '\nschema_version: 3\n' >> "${duplicate_modules_fixture}/docs/architecture/modules.yml"
expect_failure "duplicate modules key" "${duplicate_modules_fixture}" 'modules.yml contains duplicate key "schema_version"'

missing_field_fixture="$(new_fixture missing-module-field)"
mutate_yaml "${missing_field_fixture}/docs/architecture/modules.yml" \
    'data["modules"]["WALICore"].delete("target_responsibility")'
expect_failure "missing module field" "${missing_field_fixture}" "WALICore missing required field target_responsibility"

absent_state_fixture="$(new_fixture invalid-absent-state)"
mutate_yaml "${absent_state_fixture}/docs/architecture/modules.yml" \
    'data["modules"]["WALICore"]["current_capabilities"] = ["placeholder"]'
expect_failure "invalid absent state" "${absent_state_fixture}" "absent module WALICore must have empty current_capabilities"

absent_path_fixture="$(new_fixture lingering-absent-source)"
mkdir -p "${absent_path_fixture}/Packages/WALICore/Sources/WALICore"
printf 'public enum RetiredCore {}\n' > \
    "${absent_path_fixture}/Packages/WALICore/Sources/WALICore/Core.swift"
expect_failure "lingering absent source" "${absent_path_fixture}" "absent module WALICore source_path still exists"

current_state_fixture="$(new_fixture invalid-current-state)"
mutate_yaml "${current_state_fixture}/docs/architecture/modules.yml" \
    'data["modules"]["WALIEngine"]["current_capabilities"] = []'
expect_failure "invalid current state" "${current_state_fixture}" "current module WALIEngine must declare current_capabilities"

incomplete_persistence_policy_fixture="$(new_fixture incomplete-persistence-policy)"
mutate_yaml "${incomplete_persistence_policy_fixture}/docs/architecture/modules.yml" \
    'data["modules"]["WALICore"]["forbidden_frameworks"].delete("CoreData")'
expect_failure "incomplete persistence import policy" "${incomplete_persistence_policy_fixture}" "WALICore persistence policy is missing CoreData"

source_path_fixture="$(new_fixture source-path-mismatch)"
mutate_yaml "${source_path_fixture}/docs/architecture/modules.yml" \
    'data["modules"]["WALIAppRuntime"]["source_path"] = "Sources/WALIUI"'
expect_failure "source path mismatch" "${source_path_fixture}" "WALIAppRuntime source_path does not match project.yml"

dynamic_target_fixture="$(new_fixture dynamic-target)"
mutate_yaml "${dynamic_target_fixture}/project.yml" \
    'data["targets"]["WALIAppRuntime"]["type"] = "framework"'
expect_failure "dynamic target mismatch" "${dynamic_target_fixture}" "WALIAppRuntime target type mismatch"

unregistered_production_target_fixture="$(new_fixture unregistered-production-target)"
mkdir -p "${unregistered_production_target_fixture}/Sources/GhostRuntime"
printf 'import Foundation\n' > \
    "${unregistered_production_target_fixture}/Sources/GhostRuntime/Ghost.swift"
mutate_yaml "${unregistered_production_target_fixture}/project.yml" '
    data["targets"]["GhostRuntime"] = {
      "type" => "framework.static",
      "sources" => [{"path" => "Sources/GhostRuntime"}],
      "dependencies" => []
    }
'
expect_failure \
    "unregistered production target" \
    "${unregistered_production_target_fixture}" \
    "project.yml contains unregistered production target GhostRuntime"

unregistered_test_target_fixture="$(new_fixture unregistered-test-target)"
mkdir -p "${unregistered_test_target_fixture}/Tests/GhostTests"
printf 'import XCTest\n' > \
    "${unregistered_test_target_fixture}/Tests/GhostTests/GhostTests.swift"
mutate_yaml "${unregistered_test_target_fixture}/project.yml" '
    data["targets"]["GhostTests"] = {
      "type" => "bundle.unit-test",
      "sources" => [{"path" => "Tests/GhostTests"}],
      "dependencies" => []
    }
'
expect_failure \
    "unregistered test target" \
    "${unregistered_test_target_fixture}" \
    "project.yml contains undeclared test target GhostTests"

missing_declared_test_target_fixture="$(new_fixture missing-declared-test-target)"
mutate_yaml "${missing_declared_test_target_fixture}/project.yml" \
    'data["targets"].delete("WALIAppTests")'
expect_failure \
    "missing declared test target" \
    "${missing_declared_test_target_fixture}" \
    "declared Xcode test target WALIAppTests is missing from project.yml"

build_dependency_fixture="$(new_fixture build-dependency-mismatch)"
mutate_yaml "${build_dependency_fixture}/project.yml" \
    'data["targets"]["WALIAppRuntime"]["dependencies"].reject! { |item| item["target"] == "WALIUI" }'
expect_failure "build dependency mismatch" "${build_dependency_fixture}" "current build edges do not match project.yml"

duplicate_build_dependency_fixture="$(new_fixture duplicate-build-dependency)"
mutate_yaml "${duplicate_build_dependency_fixture}/project.yml" '
    dependency = data["targets"]["WALIAppRuntime"]["dependencies"].find { |item| item["target"] == "WALIUI" }
    data["targets"]["WALIAppRuntime"]["dependencies"] << Marshal.load(Marshal.dump(dependency))
'
expect_failure \
    "duplicate build dependency" \
    "${duplicate_build_dependency_fixture}" \
    "WALIAppRuntime has duplicate build dependency WALIUI"

package_dependency_fixture="$(new_fixture package-dependency-mismatch)"
mutate_yaml "${package_dependency_fixture}/project.yml" \
    'data["targets"]["WALIUI"]["dependencies"].reject! { |item| item["package"] == "WALICore" }'
expect_failure "package dependency mismatch" "${package_dependency_fixture}" "current package edges do not match project.yml"

duplicate_package_dependency_fixture="$(new_fixture duplicate-package-dependency)"
mutate_yaml "${duplicate_package_dependency_fixture}/project.yml" '
    dependency = data["targets"]["WALIUI"]["dependencies"].find { |item| item["package"] == "WALICore" }
    data["targets"]["WALIUI"]["dependencies"] << Marshal.load(Marshal.dump(dependency))
'
expect_failure \
    "duplicate package dependency" \
    "${duplicate_package_dependency_fixture}" \
    "WALIUI has duplicate package dependency WALIModel"

implicit_package_product_fixture="$(new_fixture implicit-package-product)"
mutate_yaml "${implicit_package_product_fixture}/project.yml" '
    dependency = data["targets"]["WALIUI"]["dependencies"].find { |item| item["package"] == "WALICore" }
    dependency.delete("product")
'
expect_failure \
    "implicit package product" \
    "${implicit_package_product_fixture}" \
    "WALIUI package dependency WALICore must name an explicit product"

embed_dependency_fixture="$(new_fixture embed-dependency-mismatch)"
mutate_yaml "${embed_dependency_fixture}/project.yml" \
    'item = data["targets"]["WALIAgent"]["dependencies"].find { |entry| entry["target"] == "WALITranscoder" }; item.delete("embed"); item.delete("link")'
expect_failure "embed dependency mismatch" "${embed_dependency_fixture}" "current embed_only edges do not match project.yml"

duplicate_embed_dependency_fixture="$(new_fixture duplicate-embed-dependency)"
mutate_yaml "${duplicate_embed_dependency_fixture}/project.yml" '
    dependency = data["targets"]["WALIAgent"]["dependencies"].find { |item| item["target"] == "WALITranscoder" }
    data["targets"]["WALIAgent"]["dependencies"] << Marshal.load(Marshal.dump(dependency))
'
expect_failure \
    "duplicate embed dependency" \
    "${duplicate_embed_dependency_fixture}" \
    "WALIAgent has duplicate embed_only dependency WALITranscoder"

wrong_embed_owner_fixture="$(new_fixture wrong-embed-owner)"
mutate_yaml "${wrong_embed_owner_fixture}/project.yml" '
    dependency = data["targets"]["WALIAgent"]["dependencies"].find { |entry| entry["target"] == "WALITranscoder" }
    data["targets"]["WALIAgent"]["dependencies"].delete(dependency)
    data["targets"]["WALI"]["dependencies"] << dependency
'
mutate_yaml "${wrong_embed_owner_fixture}/docs/architecture/modules.yml" '
    edge = data["edges"]["current"]["embed_only"].find { |item| item["to"] == "WALITranscoder" }
    edge["from"] = "WALI"
'
expect_failure \
    "wrong transcoder embed owner" \
    "${wrong_embed_owner_fixture}" \
    "WALITranscoder embed owner must be WALIAgent"

main_app_xpc_fixture="$(new_fixture main-app-xpc)"
mutate_yaml "${main_app_xpc_fixture}/project.yml" '
    dependency = data["targets"]["WALIAgent"]["dependencies"].find { |entry| entry["target"] == "WALITranscoder" }
    data["targets"]["WALI"]["dependencies"] << Marshal.load(Marshal.dump(dependency))
'
mutate_yaml "${main_app_xpc_fixture}/docs/architecture/modules.yml" \
    'data["edges"]["current"]["embed_only"] << {"from" => "WALI", "to" => "WALITranscoder"}'
expect_failure \
    "main app XPC containment" \
    "${main_app_xpc_fixture}" \
    "WALI must not embed WALITranscoder"

wrong_xpc_copy_location_fixture="$(new_fixture wrong-xpc-copy-location)"
mutate_yaml "${wrong_xpc_copy_location_fixture}/project.yml" '
    dependency = data["targets"]["WALIAgent"]["dependencies"].find { |entry| entry["target"] == "WALITranscoder" }
    dependency["copy"]["subpath"] = "Contents/PlugIns"
'
expect_failure \
    "wrong agent XPC copy location" \
    "${wrong_xpc_copy_location_fixture}" \
    "WALIAgent must embed-only WALITranscoder at Contents/XPCServices with code signing"

dynamic_product_fixture="$(new_fixture dynamic-package-product)"
replace_text \
    "${dynamic_product_fixture}/Packages/WALICore/Package.swift" \
    "type: .static" \
    "type: .dynamic"
expect_failure "dynamic package product" "${dynamic_product_fixture}" "Swift package product WALIModel must be a static library"

automatic_product_fixture="$(new_fixture automatic-package-product)"
replace_text \
    "${automatic_product_fixture}/Packages/WALICore/Package.swift" \
    "            type: .static,
" \
    ""
expect_failure "automatic package product" "${automatic_product_fixture}" "Swift package product WALIModel must be a static library"

missing_product_fixture="$(new_fixture missing-package-product)"
mutate_yaml "${missing_product_fixture}/docs/architecture/modules.yml" \
    'data["swift_packages"]["WALICore"]["current"]["products"].delete("WALIModel")'
expect_failure "missing package product declaration" "${missing_product_fixture}" "undeclared current Swift package product WALIModel"

unknown_product_fixture="$(new_fixture unknown-package-product)"
mutate_yaml "${unknown_product_fixture}/docs/architecture/modules.yml" '
    data["swift_packages"]["WALICore"]["current"]["products"]["Ghost"] = {
      "kind" => "library", "linkage" => "static", "targets" => ["WALIModel"]
    }
'
expect_failure "unknown package product declaration" "${unknown_product_fixture}" "declared current Swift package product Ghost is missing"

broad_product_fixture="$(new_fixture retired-broad-package-product)"
mutate_yaml "${broad_product_fixture}/docs/architecture/modules.yml" '
    package = data["swift_packages"]["WALICore"]["current"]
    package["products"]["WALICore"] = {
      "kind" => "library", "linkage" => "static", "targets" => ["WALIModel"]
    }
'
expect_failure \
    "retired broad package product" \
    "${broad_product_fixture}" \
    "current WALICore package products do not match the governed product graph"

missing_package_target_fixture="$(new_fixture missing-package-target)"
mutate_yaml "${missing_package_target_fixture}/docs/architecture/modules.yml" \
    'data["swift_packages"]["WALICore"]["current"]["targets"].delete("WALIModelTests")'
expect_failure "missing package target declaration" "${missing_package_target_fixture}" "undeclared current Swift package target WALIModelTests"

unknown_package_target_fixture="$(new_fixture unknown-package-target)"
mutate_yaml "${unknown_package_target_fixture}/docs/architecture/modules.yml" '
    data["swift_packages"]["WALICore"]["current"]["targets"]["Ghost"] = {
      "kind" => "regular", "path" => "Sources/Ghost", "dependencies" => []
    }
'
expect_failure "unknown package target declaration" "${unknown_package_target_fixture}" "declared current Swift package target Ghost is missing"

package_target_dependency_fixture="$(new_fixture package-target-dependency)"
mutate_yaml "${package_target_dependency_fixture}/docs/architecture/modules.yml" \
    'data["swift_packages"]["WALICore"]["current"]["targets"]["WALIWireTests"]["dependencies"] = []'
expect_failure "package target dependency mismatch" "${package_target_dependency_fixture}" "Swift package target WALIWireTests dependencies do not match"

package_target_path_fixture="$(new_fixture package-target-path)"
mkdir -p "${package_target_path_fixture}/Packages/WALICore/Sources/Other"
mutate_yaml "${package_target_path_fixture}/docs/architecture/modules.yml" \
    'data["swift_packages"]["WALICore"]["current"]["targets"]["WALIModel"]["path"] = "Sources/Other"'
expect_failure "package target path mismatch" "${package_target_path_fixture}" "Swift package target WALIModel path does not match"

package_product_target_fixture="$(new_fixture package-product-target)"
mutate_yaml "${package_product_target_fixture}/docs/architecture/modules.yml" \
    'data["swift_packages"]["WALICore"]["current"]["products"]["WALIModel"]["targets"] = []'
expect_failure "package product target mismatch" "${package_product_target_fixture}" "Swift package product WALIModel targets do not match"

swapped_descriptor_target_fixture="$(new_fixture swapped-descriptor-target)"
mutate_yaml "${swapped_descriptor_target_fixture}/docs/architecture/modules.yml" \
    'data["modules"]["WALIWire"]["target_target"]["target"] = "WALIEngine"'
expect_failure \
    "descriptor product target mismatch" \
    "${swapped_descriptor_target_fixture}" \
    "WALIWire target_target product WALIWire does not export target WALIEngine"

ambiguous_product_fixture="$(new_fixture ambiguous-package-product)"
mutate_yaml "${ambiguous_product_fixture}/docs/architecture/modules.yml" \
    'data["swift_packages"]["WALICore"]["target"]["products"]["WALIWire"]["targets"] << "WALIModel"'
expect_failure \
    "ambiguous package product" \
    "${ambiguous_product_fixture}" \
    "target Swift package product WALIWire must export exactly one production target"

duplicate_product_export_fixture="$(new_fixture duplicate-product-export)"
mutate_yaml "${duplicate_product_export_fixture}/docs/architecture/modules.yml" \
    'data["swift_packages"]["WALICore"]["target"]["products"]["WALIEngine"]["targets"] = ["WALIWire"]'
expect_failure \
    "duplicate production target export" \
    "${duplicate_product_export_fixture}" \
    "target Swift package target WALIWire must be exported by exactly one product"

target_package_cycle_fixture="$(new_fixture target-package-cycle)"
mutate_yaml "${target_package_cycle_fixture}/docs/architecture/modules.yml" \
    'data["swift_packages"]["WALICore"]["target"]["targets"]["WALIModel"]["dependencies"] = ["WALIEngine"]'
expect_failure "target package dependency cycle" "${target_package_cycle_fixture}" "target Swift package target graph contains a cycle"

current_package_cycle_fixture="$(new_fixture current-package-cycle)"
mkdir -p "${current_package_cycle_fixture}/Packages/WALICore/Sources/Cycle"
printf 'public enum CycleMarker {}\n' > "${current_package_cycle_fixture}/Packages/WALICore/Sources/Cycle/Cycle.swift"
replace_text \
    "${current_package_cycle_fixture}/Packages/WALICore/Package.swift" \
    '        .target(
            name: "WALIModel",
            path: "Sources/WALIModel"
        ),' \
    '        .target(
            name: "WALIModel",
            dependencies: ["Cycle"],
            path: "Sources/WALIModel"
        ),
        .target(
            name: "Cycle",
            dependencies: ["WALIModel"],
            path: "Sources/Cycle"
        ),'
mutate_yaml "${current_package_cycle_fixture}/docs/architecture/modules.yml" '
    package = data["swift_packages"]["WALICore"]["current"]
    package["targets"]["WALIModel"]["dependencies"] = ["Cycle"]
    package["targets"]["Cycle"] = {
      "kind" => "regular", "path" => "Sources/Cycle", "dependencies" => ["WALIModel"]
    }
'
expect_failure "current package dependency cycle" "${current_package_cycle_fixture}" "current Swift package target graph contains a cycle"

missing_planned_test_fixture="$(new_fixture missing-planned-test-target)"
mutate_yaml "${missing_planned_test_fixture}/docs/architecture/modules.yml" \
    'data["swift_packages"]["WALICore"]["target"]["targets"].delete("WALIWireTests")'
expect_failure "missing planned package test target" "${missing_planned_test_fixture}" "target Swift package target WALIWire is missing test target WALIWireTests"

planned_test_dependency_fixture="$(new_fixture planned-test-dependency-drift)"
mutate_yaml "${planned_test_dependency_fixture}/docs/architecture/modules.yml" \
    'data["swift_packages"]["WALICore"]["target"]["targets"]["WALIWireTests"]["dependencies"] = ["WALIEngine"]'
expect_failure "planned package test dependency drift" "${planned_test_dependency_fixture}" "target Swift package test target WALIWireTests must depend exactly on WALIWire"

planned_test_path_fixture="$(new_fixture planned-test-path-drift)"
mutate_yaml "${planned_test_path_fixture}/docs/architecture/modules.yml" \
    'data["swift_packages"]["WALICore"]["target"]["targets"]["WALIEngineTests"]["path"] = "Tests/EngineTests"'
expect_failure "planned package test path drift" "${planned_test_path_fixture}" "target Swift package test target WALIEngineTests path must be Tests/WALIEngineTests"

package_import_drift_fixture="$(new_fixture package-import-drift)"
mutate_yaml "${package_import_drift_fixture}/docs/architecture/modules.yml" \
    'data["modules"]["WALIWire"]["target_allowed_internal_imports"] = []'
expect_failure "package dependency import drift" "${package_import_drift_fixture}" "target Swift package target WALIWire dependencies do not match WALIWire permitted internal imports"

duplicate_package_edge_fixture="$(new_fixture duplicate-package-target-edge)"
mutate_yaml "${duplicate_package_edge_fixture}/docs/architecture/modules.yml" '
    data["edges"]["target"]["package"] << {"from" => "WALIWire", "to" => "WALIModel"}
'
expect_failure "duplicate package target edge authority" "${duplicate_package_edge_fixture}" "target package edge WALIWire -> WALIModel duplicates canonical Swift package target dependencies"

wire_reexport_fixture="$(new_fixture wire-internal-reexport)"
replace_text \
    "${wire_reexport_fixture}/Packages/WALICore/Sources/WALIWire/Wire.swift" \
    "import WALIModel" \
    "@_exported import WALIModel"
expect_failure \
    "WALIWire internal re-export" \
    "${wire_reexport_fixture}" \
    "WALIWire re-exports internal module WALIModel without permission"

engine_reexport_fixture="$(new_fixture engine-internal-reexport)"
replace_text \
    "${engine_reexport_fixture}/Packages/WALICore/Sources/WALIEngine/Engine.swift" \
    "import WALIModel" \
    "@_exported import WALIModel"
expect_failure \
    "WALIEngine internal re-export" \
    "${engine_reexport_fixture}" \
    "WALIEngine re-exports internal module WALIModel without permission"

allowed_reexport_fixture="$(new_fixture allowlisted-internal-reexport)"
replace_text \
    "${allowed_reexport_fixture}/Packages/WALICore/Sources/WALIWire/Wire.swift" \
    "import WALIModel" \
    "@_exported import WALIModel"
mutate_yaml "${allowed_reexport_fixture}/docs/architecture/modules.yml" \
    'data["modules"]["WALIWire"]["current_allowed_internal_reexports"] = ["WALIModel"]'
expect_success "explicitly allowlisted internal re-export" "${allowed_reexport_fixture}"

missing_source_import_fixture="$(new_fixture missing-source-import)"
replace_text \
    "${missing_source_import_fixture}/Sources/WALIAppRuntime/App.swift" \
    "import WALIWire
" \
    ""
expect_failure \
    "missing current source import" \
    "${missing_source_import_fixture}" \
    "WALIAppRuntime current internal imports do not match manifest"

extra_test_package_dependency_fixture="$(new_fixture extra-test-package-dependency)"
mutate_yaml "${extra_test_package_dependency_fixture}/project.yml" '
    data["targets"]["WALIAppTests"]["dependencies"] << {
      "package" => "WALICore", "product" => "WALIModel"
    }
'
mutate_yaml "${extra_test_package_dependency_fixture}/docs/architecture/modules.yml" \
    'data["xcode_test_targets"]["WALIAppTests"]["package_dependencies"] = ["WALIModel"]'
expect_failure \
    "test dependency without direct import" \
    "${extra_test_package_dependency_fixture}" \
    "WALIAppTests package dependencies must match its direct source imports"

missing_test_subject_import_fixture="$(new_fixture missing-test-subject-import)"
replace_text \
    "${missing_test_subject_import_fixture}/Tests/WALIAppTests/WALIAppTests.swift" \
    "@testable import WALIAppRuntime
" \
    ""
expect_failure \
    "test subject without direct import" \
    "${missing_test_subject_import_fixture}" \
    "WALIAppTests build dependencies must match its direct source imports"

declare -a import_forms=(
    "import WALIAgentRuntime"
    "private import WALIAgentRuntime"
    "fileprivate import WALIAgentRuntime"
    "@_exported import WALIAgentRuntime"
    "@preconcurrency import WALIAgentRuntime"
    "@_implementationOnly import WALIAgentRuntime"
    "internal import WALIAgentRuntime"
    "public import WALIAgentRuntime"
    "package import WALIAgentRuntime"
)
for index in "${!import_forms[@]}"; do
    import_fixture="$(new_fixture "unauthorized-import-${index}")"
    printf '%s\n' "${import_forms[${index}]}" >> "${import_fixture}/Sources/WALIAppRuntime/App.swift"
    expect_failure \
        "unauthorized import form ${index}" \
        "${import_fixture}" \
        "WALIAppRuntime imports unauthorized internal module WALIAgentRuntime"
done

declare -a scoped_import_kinds=(struct class enum protocol func var typealias)
declare -a persistence_modules=(CoreData SwiftData)
for kind in "${scoped_import_kinds[@]}"; do
    for module in "${persistence_modules[@]}"; do
        scoped_fixture="$(new_fixture "scoped-${kind}-${module}")"
        printf 'import %s %s.ScopedSymbol\n' "${kind}" "${module}" >> "${scoped_fixture}/Packages/WALICore/Sources/WALIModel/Model.swift"
        expect_failure \
            "scoped ${kind} forbidden ${module}" \
            "${scoped_fixture}" \
            "WALIModel imports forbidden framework ${module} (parsed import ${module}.ScopedSymbol)"
    done
done

declare -a internal_runtime_modules=(WALIAgentRuntime WALITranscoderRuntime)
for kind in "${scoped_import_kinds[@]}"; do
    for module in "${internal_runtime_modules[@]}"; do
        scoped_fixture="$(new_fixture "scoped-${kind}-${module}")"
        printf 'import %s %s.ScopedSymbol\n' "${kind}" "${module}" >> "${scoped_fixture}/Sources/WALIAppRuntime/App.swift"
        expect_failure \
            "scoped ${kind} unauthorized ${module}" \
            "${scoped_fixture}" \
            "WALIAppRuntime imports unauthorized internal module ${module} (parsed import ${module}.ScopedSymbol)"
    done
done

fake_block_import_fixture="$(new_fixture fake-block-comment-import)"
cat >> "${fake_block_import_fixture}/Sources/WALIAppRuntime/App.swift" <<'EOF'
/*
import WALIAgentRuntime
*/
EOF
expect_success "ignore block comment import text" "${fake_block_import_fixture}"

fake_string_import_fixture="$(new_fixture fake-multiline-string-import)"
cat >> "${fake_string_import_fixture}/Sources/WALIAppRuntime/App.swift" <<'EOF'
let fixtureText = """
import WALIAgentRuntime
"""
EOF
expect_success "ignore multiline string import text" "${fake_string_import_fixture}"

parser_failure_fixture="$(new_fixture swift-parser-failure)"
printf 'func unfinished(\n' >> "${parser_failure_fixture}/Sources/WALIAppRuntime/App.swift"
expect_failure "Swift parser failure closes policy" "${parser_failure_fixture}" "Swift parser failed"

core_data_fixture="$(new_fixture forbidden-core-data)"
printf '@_exported import CoreData\n' >> "${core_data_fixture}/Packages/WALICore/Sources/WALIModel/Model.swift"
expect_failure "forbidden CoreData import" "${core_data_fixture}" "WALIModel imports forbidden framework CoreData"

swift_data_fixture="$(new_fixture forbidden-swift-data)"
printf 'private import SwiftData\n' >> "${swift_data_fixture}/Packages/WALICore/Sources/WALIModel/Model.swift"
expect_failure "forbidden SwiftData import" "${swift_data_fixture}" "WALIModel imports forbidden framework SwiftData"

foundation_fixture="$(new_fixture forbidden-model-foundation)"
printf 'import Foundation\n' >> "${foundation_fixture}/Packages/WALICore/Sources/WALIModel/Model.swift"
expect_failure "forbidden WALIModel Foundation import" "${foundation_fixture}" "WALIModel imports forbidden framework Foundation"

missing_surfaces_fixture="$(new_fixture missing-surfaces)"
rm "${missing_surfaces_fixture}/docs/compatibility/surfaces.yml"
expect_failure "missing surfaces manifest" "${missing_surfaces_fixture}" "missing docs/compatibility/surfaces.yml"

malformed_surfaces_fixture="$(new_fixture malformed-surfaces)"
printf '\nbroken: [\n' >> "${malformed_surfaces_fixture}/docs/compatibility/surfaces.yml"
expect_failure "malformed surfaces YAML" "${malformed_surfaces_fixture}" "surfaces.yml is invalid YAML"

duplicate_surfaces_key_fixture="$(new_fixture duplicate-surfaces-key)"
printf '\nschema_version: 3\n' >> "${duplicate_surfaces_key_fixture}/docs/compatibility/surfaces.yml"
expect_failure "duplicate surfaces key" "${duplicate_surfaces_key_fixture}" 'surfaces.yml contains duplicate key "schema_version"'

missing_surface_fixture="$(new_fixture missing-required-surface)"
mutate_yaml "${missing_surface_fixture}/docs/compatibility/surfaces.yml" \
    'data["surfaces"].reject! { |surface| surface["id"] == "diagnostic_export" }'
expect_failure "missing compatibility surface" "${missing_surface_fixture}" "missing required compatibility surface diagnostic_export"

missing_bundle_surface_fixture="$(new_fixture missing-bundle-surface)"
mutate_yaml "${missing_bundle_surface_fixture}/docs/compatibility/surfaces.yml" \
    'data["surfaces"].reject! { |surface| surface["id"] == "bundle_identifiers" }'
expect_failure "missing bundle identity surface" "${missing_bundle_surface_fixture}" "missing required compatibility surface bundle_identifiers"

missing_model_records_surface_fixture="$(new_fixture missing-model-records-surface)"
mutate_yaml "${missing_model_records_surface_fixture}/docs/compatibility/surfaces.yml" \
    'data["surfaces"].reject! { |surface| surface["id"] == "model_records" }'
expect_failure "missing model records surface" "${missing_model_records_surface_fixture}" "missing required compatibility surface model_records"

declare -a required_detail_cases=(
    "sqlite_schema:migration_policy"
    "artifact_manifest:checksum_algorithm"
    "model_records:invalid_fixture_paths"
    "app_agent_wire:direction"
    "agent_worker_wire:message_catalog"
    "bundle_identifiers:configurations"
    "application_group_containers:configurations"
    "app_agent_service_names:configurations"
    "agent_worker_service_names:configurations"
    "content_store:target_layout"
    "preferences:authority"
    "url_schemes:mutation_policy"
    "catalog_manifest:signature_required"
    "lock_screen_manifest:implementation_gate"
    "lock_screen_manifest:session_lock_refresh_policy"
    "diagnostic_export:required_redaction"
)
for index in "${!required_detail_cases[@]}"; do
    IFS=: read -r surface_id detail_key <<< "${required_detail_cases[${index}]}"
    detail_fixture="$(new_fixture "missing-detail-${index}")"
    mutate_yaml "${detail_fixture}/docs/compatibility/surfaces.yml" \
        "data[\"surfaces\"].find { |surface| surface[\"id\"] == \"${surface_id}\" }[\"details\"].delete(\"${detail_key}\")"
    expect_failure \
        "missing ${surface_id} detail ${detail_key}" \
        "${detail_fixture}" \
        "${surface_id} details missing required field ${detail_key}"
done

lock_screen_build_fixture="$(new_fixture lock-screen-build)"
mutate_yaml "${lock_screen_build_fixture}/docs/compatibility/surfaces.yml" \
    'data["surfaces"].find { |surface| surface["id"] == "lock_screen_manifest" }["details"]["verified_system_builds"] = ["UNKNOWN"]'
expect_failure \
    "lock screen exact build gate" \
    "${lock_screen_build_fixture}" \
    "lock_screen_manifest verified builds are invalid"

lock_screen_provider_fixture="$(new_fixture lock-screen-provider)"
mutate_yaml "${lock_screen_provider_fixture}/docs/compatibility/surfaces.yml" \
    'data["surfaces"].find { |surface| surface["id"] == "lock_screen_manifest" }["details"]["provider"] = "example.invalid"'
expect_failure \
    "lock screen exact provider" \
    "${lock_screen_provider_fixture}" \
    "lock_screen_manifest provider is invalid"

lock_screen_global_fixture="$(new_fixture lock-screen-global-default)"
mutate_yaml "${lock_screen_global_fixture}/docs/compatibility/surfaces.yml" \
    'data["surfaces"].find { |surface| surface["id"] == "lock_screen_manifest" }["details"]["global_default_policy"] = "mutate"'
expect_failure \
    "lock screen global linked policy" \
    "${lock_screen_global_fixture}" \
    "lock_screen_manifest global policy is invalid"

lock_screen_selection_fixture="$(new_fixture lock-screen-selection-policy)"
mutate_yaml "${lock_screen_selection_fixture}/docs/compatibility/surfaces.yml" \
    'data["surfaces"].find { |surface| surface["id"] == "lock_screen_manifest" }["details"]["selection_policy"] = "per-display"'
expect_failure \
    "lock screen main display selection" \
    "${lock_screen_selection_fixture}" \
    "lock_screen_manifest selection policy is invalid"

lock_screen_refresh_fixture="$(new_fixture lock-screen-refresh-policy)"
mutate_yaml "${lock_screen_refresh_fixture}/docs/compatibility/surfaces.yml" \
    'data["surfaces"].find { |surface| surface["id"] == "lock_screen_manifest" }["details"]["session_lock_refresh_policy"] = "periodic"'
expect_failure \
    "lock screen session lock refresh policy" \
    "${lock_screen_refresh_fixture}" \
    "lock_screen_manifest session lock refresh policy is invalid"

lock_screen_redaction_fixture="$(new_fixture lock-screen-redaction)"
"${RUBY_BIN}" -rjson -e '
  path = ARGV.fetch(0)
  data = JSON.parse(File.read(path))
  data["unsafe_path"] = "/Users/example"
  File.write(path, JSON.generate(data))
' "${lock_screen_redaction_fixture}/Fixtures/LockScreen/modern-aerial-v1.json"
expect_failure \
    "lock screen fixture redaction" \
    "${lock_screen_redaction_fixture}" \
    "lock_screen_manifest fixture must remain redacted"

model_records_canonical_bytes_fixture="$(new_fixture model-records-canonical-bytes)"
mutate_yaml "${model_records_canonical_bytes_fixture}/docs/compatibility/surfaces.yml" \
    'data["surfaces"].find { |surface| surface["id"] == "model_records" }["details"]["canonical_bytes"] = true'
expect_failure "model records canonical byte claim" "${model_records_canonical_bytes_fixture}" "model_records must not claim canonical bytes"

model_records_missing_invalid_fixture="$(new_fixture model-records-missing-invalid-fixture)"
mutate_yaml "${model_records_missing_invalid_fixture}/docs/compatibility/surfaces.yml" '
    surface = data["surfaces"].find { |item| item["id"] == "model_records" }
    surface["details"]["invalid_fixture_paths"] = []
'
expect_failure "model records missing invalid fixture" "${model_records_missing_invalid_fixture}" "model_records must declare golden and invalid fixture paths"

invalid_epoch_range_fixture="$(new_fixture invalid-epoch-range)"
mkdir -p "${invalid_epoch_range_fixture}/Fixtures/Compatibility"
printf 'fixture\n' > "${invalid_epoch_range_fixture}/Fixtures/Compatibility/sqlite-v1.yml"
mutate_yaml "${invalid_epoch_range_fixture}/docs/compatibility/surfaces.yml" '
    surface = data["surfaces"].find { |item| item["id"] == "sqlite_schema" }
    surface["implementation"] = "implemented"
    surface["version"] = {
      "current" => {"epoch" => 2, "revision" => 1},
      "readable_epochs" => [
        {"epoch" => 1, "minimum_revision" => 3, "maximum_revision" => 2},
        {"epoch" => 2, "minimum_revision" => 0, "maximum_revision" => 1}
      ],
      "additive_compatibility" => "declared_ranges_only"
    }
    surface["product_compatibility"] = {
      "minimum_reader" => "0.1.0",
      "minimum_writer" => "0.1.0",
      "rollback_readers" => [],
      "rollback_fixture_paths" => []
    }
    surface["fixture_gate"] = {
      "status" => "passing",
      "paths" => ["Fixtures/Compatibility/sqlite-v1.yml"]
    }
'
expect_failure "invalid per-epoch revision range" "${invalid_epoch_range_fixture}" "sqlite_schema readable epoch 1 has invalid revision range"

current_outside_range_fixture="${TEMP_ROOT}/current-outside-range"
cp -R "${invalid_epoch_range_fixture}" "${current_outside_range_fixture}"
mutate_yaml "${current_outside_range_fixture}/docs/compatibility/surfaces.yml" '
    version = data["surfaces"].find { |item| item["id"] == "sqlite_schema" }["version"]
    version["readable_epochs"] = [
      {"epoch" => 2, "minimum_revision" => 0, "maximum_revision" => 0}
    ]
'
expect_failure "current version outside epoch range" "${current_outside_range_fixture}" "sqlite_schema readable epochs do not contain current version"

duplicate_epoch_range_fixture="${TEMP_ROOT}/duplicate-epoch-range"
cp -R "${invalid_epoch_range_fixture}" "${duplicate_epoch_range_fixture}"
mutate_yaml "${duplicate_epoch_range_fixture}/docs/compatibility/surfaces.yml" '
    version = data["surfaces"].find { |item| item["id"] == "sqlite_schema" }["version"]
    version["readable_epochs"] = [
      {"epoch" => 2, "minimum_revision" => 0, "maximum_revision" => 1},
      {"epoch" => 2, "minimum_revision" => 0, "maximum_revision" => 1}
    ]
'
expect_failure "duplicate readable epoch" "${duplicate_epoch_range_fixture}" "sqlite_schema readable epoch 2 is duplicated"

missing_configuration_fixture="$(new_fixture missing-configuration)"
mutate_yaml "${missing_configuration_fixture}/docs/compatibility/surfaces.yml" \
    'data["surfaces"].find { |surface| surface["id"] == "bundle_identifiers" }["details"]["configurations"].delete("Release")'
expect_failure "missing identity configuration" "${missing_configuration_fixture}" "bundle_identifiers configurations must contain exactly Debug, Development, Release"

malformed_configuration_fixture="$(new_fixture malformed-configuration)"
mutate_yaml "${malformed_configuration_fixture}/docs/compatibility/surfaces.yml" \
    'data["surfaces"].find { |surface| surface["id"] == "application_group_containers" }["details"]["configurations"]["Development"] = "group.com.wali.shared"'
expect_failure "malformed identity configuration" "${malformed_configuration_fixture}" "application_group_containers Development configuration must be a mapping"

bundle_identity_mismatch_fixture="$(new_fixture bundle-identity-mismatch)"
mutate_yaml "${bundle_identity_mismatch_fixture}/docs/compatibility/surfaces.yml" \
    'data["surfaces"].find { |surface| surface["id"] == "bundle_identifiers" }["details"]["configurations"]["Debug"]["WALI"] = "com.example.WALI"'
expect_failure "bundle identity mismatch" "${bundle_identity_mismatch_fixture}" "bundle_identifiers Debug WALI does not match resolved build settings"

wrong_configuration_identifier_fixture="$(new_fixture wrong-configuration-identifier)"
replace_text \
    "${wrong_configuration_identifier_fixture}/Config/Debug.xcconfig" \
    "WALI_APP_BUNDLE_IDENTIFIER = com.wali.debug.WALI" \
    "WALI_APP_BUNDLE_IDENTIFIER = com.example.WALI"
mutate_yaml "${wrong_configuration_identifier_fixture}/docs/compatibility/surfaces.yml" '
    configurations = data["surfaces"].find { |surface| surface["id"] == "bundle_identifiers" }["details"]["configurations"]
    configurations["Debug"]["WALI"] = "com.example.WALI"
'
expect_failure \
    "wrong configuration bundle identifier" \
    "${wrong_configuration_identifier_fixture}" \
    "bundle_identifiers Debug WALI must be com.wali.debug.WALI"

literal_project_identifier_fixture="$(new_fixture literal-project-identifier)"
mutate_yaml "${literal_project_identifier_fixture}/project.yml" \
    'data["targets"]["WALI"]["settings"]["base"]["PRODUCT_BUNDLE_IDENTIFIER"] = "com.wali.debug.WALI"'
expect_failure \
    "project identifier bypasses xcconfig source" \
    "${literal_project_identifier_fixture}" \
    'WALI PRODUCT_BUNDLE_IDENTIFIER must reference $(WALI_APP_BUNDLE_IDENTIFIER)'

container_identity_mismatch_fixture="$(new_fixture container-identity-mismatch)"
mutate_yaml "${container_identity_mismatch_fixture}/docs/compatibility/surfaces.yml" \
    'data["surfaces"].find { |surface| surface["id"] == "application_group_containers" }["details"]["configurations"]["Release"]["WALI"] = []'
expect_failure "container identity mismatch" "${container_identity_mismatch_fixture}" "application_group_containers Release WALI does not match resolved entitlements"

wrong_configuration_group_fixture="$(new_fixture wrong-configuration-group)"
replace_text \
    "${wrong_configuration_group_fixture}/Config/Development.xcconfig" \
    "WALI_APP_GROUP_IDENTIFIER = group.com.wali.development.shared" \
    "WALI_APP_GROUP_IDENTIFIER = group.com.example.shared"
mutate_yaml "${wrong_configuration_group_fixture}/docs/compatibility/surfaces.yml" '
    configurations = data["surfaces"].find { |surface| surface["id"] == "application_group_containers" }["details"]["configurations"]
    configurations["Development"]["WALI"] = ["group.com.example.shared"]
    configurations["Development"]["WALIAgent"] = ["group.com.example.shared"]
'
expect_failure \
    "wrong configuration application group" \
    "${wrong_configuration_group_fixture}" \
    "application_group_containers Development WALI must be group.com.wali.development.shared"

service_identity_mismatch_fixture="$(new_fixture service-identity-mismatch)"
mutate_yaml "${service_identity_mismatch_fixture}/docs/compatibility/surfaces.yml" \
    'data["surfaces"].find { |surface| surface["id"] == "agent_worker_service_names" }["details"]["configurations"]["Development"]["current"] = ["com.example.worker"]'
expect_failure "service identity mismatch" "${service_identity_mismatch_fixture}" "agent_worker_service_names Development current service does not match resolved worker bundle identifier"

wrong_configuration_service_fixture="$(new_fixture wrong-configuration-service)"
replace_text \
    "${wrong_configuration_service_fixture}/Config/Debug.xcconfig" \
    "WALI_TRANSCODER_BUNDLE_IDENTIFIER = com.wali.debug.WALITranscoder" \
    "WALI_TRANSCODER_BUNDLE_IDENTIFIER = com.example.worker"
mutate_yaml "${wrong_configuration_service_fixture}/docs/compatibility/surfaces.yml" '
    bundles = data["surfaces"].find { |surface| surface["id"] == "bundle_identifiers" }["details"]["configurations"]
    services = data["surfaces"].find { |surface| surface["id"] == "agent_worker_service_names" }["details"]["configurations"]
    bundles["Debug"]["WALITranscoder"] = "com.example.worker"
    services["Debug"]["current"] = ["com.example.worker"]
    services["Debug"]["target"] = ["com.example.worker"]
'
expect_failure \
    "wrong configuration worker service" \
    "${wrong_configuration_service_fixture}" \
    "agent_worker_service_names Debug current must be com.wali.debug.WALITranscoder"

control_service_mismatch_fixture="$(new_fixture control-service-mismatch)"
mutate_yaml "${control_service_mismatch_fixture}/docs/compatibility/surfaces.yml" '
    services = data["surfaces"].find { |surface| surface["id"] == "app_agent_service_names" }["details"]["configurations"]
    services["Development"]["target"] = ["com.example.control"]
'
expect_failure \
    "planned control service mismatch" \
    "${control_service_mismatch_fixture}" \
    "app_agent_service_names Development target service does not match resolved build settings"

wrong_configuration_control_service_fixture="$(new_fixture wrong-configuration-control-service)"
replace_text \
    "${wrong_configuration_control_service_fixture}/Config/Development.xcconfig" \
    "WALI_AGENT_CONTROL_SERVICE_NAME = com.wali.development.WALIAgent.control" \
    "WALI_AGENT_CONTROL_SERVICE_NAME = com.example.control"
mutate_yaml "${wrong_configuration_control_service_fixture}/docs/compatibility/surfaces.yml" '
    services = data["surfaces"].find { |surface| surface["id"] == "app_agent_service_names" }["details"]["configurations"]
    services["Development"]["target"] = ["com.example.control"]
'
expect_failure \
    "wrong configuration control service" \
    "${wrong_configuration_control_service_fixture}" \
    "app_agent_service_names Development target must be com.wali.development.WALIAgent.control"

development_signing_fixture="$(new_fixture invalid-development-signing)"
replace_text \
    "${development_signing_fixture}/Config/Development.xcconfig" \
    "CODE_SIGN_IDENTITY = Apple Development" \
    "CODE_SIGN_IDENTITY = -"
expect_failure \
    "Development signing identity" \
    "${development_signing_fixture}" \
    "WALI Development CODE_SIGN_IDENTITY must be Apple Development"

release_hardened_runtime_fixture="$(new_fixture disabled-release-hardened-runtime)"
replace_text \
    "${release_hardened_runtime_fixture}/Config/Release.xcconfig" \
    "ENABLE_HARDENED_RUNTIME = YES" \
    "ENABLE_HARDENED_RUNTIME = NO"
expect_failure \
    "Release hardened runtime" \
    "${release_hardened_runtime_fixture}" \
    "WALI Release ENABLE_HARDENED_RUNTIME must be YES"

release_marketplace_fixture="$(new_fixture enabled-release-marketplace)"
replace_text \
    "${release_marketplace_fixture}/Config/Release.xcconfig" \
    '#include "Base.xcconfig"' \
    $'#include "Base.xcconfig"\nWALI_MARKETPLACE_ENABLED = YES'
expect_failure \
    "Release marketplace default off" \
    "${release_marketplace_fixture}" \
    "Release marketplace must default to NO"

duplicate_surface_id_fixture="$(new_fixture duplicate-surface-id)"
mutate_yaml "${duplicate_surface_id_fixture}/docs/compatibility/surfaces.yml" \
    'data["surfaces"] << Marshal.load(Marshal.dump(data["surfaces"].first))'
expect_failure "duplicate surface ID" "${duplicate_surface_id_fixture}" "duplicate compatibility surface id sqlite_schema"

invalid_version_fixture="$(new_fixture invalid-unimplemented-version)"
mutate_yaml "${invalid_version_fixture}/docs/compatibility/surfaces.yml" \
    'data["surfaces"].find { |surface| surface["id"] == "sqlite_schema" }["version"]["current"] = {"epoch" => 1, "revision" => 0}'
expect_failure "invalid unimplemented version" "${invalid_version_fixture}" "unimplemented surface sqlite_schema must use null version and product compatibility fields"

missing_catalog_fixture="$(new_fixture missing-message-catalog)"
mutate_yaml "${missing_catalog_fixture}/docs/compatibility/surfaces.yml" \
    'data["surfaces"].find { |surface| surface["id"] == "app_agent_wire" }["details"].delete("message_catalog")'
expect_failure "missing wire message catalog" "${missing_catalog_fixture}" "app_agent_wire missing message_catalog"

unknown_module_fixture="$(new_fixture unknown-module-reference)"
mutate_yaml "${unknown_module_fixture}/docs/compatibility/surfaces.yml" \
    'data["surfaces"].find { |surface| surface["id"] == "preferences" }["module_access"]["readers"] << "UnknownModule"'
expect_failure "unknown module reference" "${unknown_module_fixture}" "surface preferences references unknown module UnknownModule"

missing_fixture_gate_path_fixture="$(new_fixture missing-fixture-gate-path)"
mutate_yaml "${missing_fixture_gate_path_fixture}/docs/compatibility/surfaces.yml" '
    surface = data["surfaces"].find { |item| item["id"] == "sqlite_schema" }
    surface["implementation"] = "implemented"
    surface["version"] = {
      "current" => {"epoch" => 1, "revision" => 0},
      "readable_epochs" => [
        {"epoch" => 1, "minimum_revision" => 0, "maximum_revision" => 0}
      ],
      "additive_compatibility" => "declared_ranges_only"
    }
    surface["product_compatibility"] = {
      "minimum_reader" => "0.1.0",
      "minimum_writer" => "0.1.0",
      "rollback_readers" => [],
      "rollback_fixture_paths" => []
    }
    surface["fixture_gate"] = {
      "status" => "passing",
      "paths" => ["Fixtures/Compatibility/sqlite-v1.yml"]
    }
'
expect_failure "missing implemented fixture path" "${missing_fixture_gate_path_fixture}" "fixture path does not exist"

missing_reciprocal_adr_fixture="$(new_fixture missing-reciprocal-adr)"
replace_text \
    "${missing_reciprocal_adr_fixture}/docs/adr/0004-engine-owned-use-cases.md" \
    "- supersedes: 0001
" \
    ""
expect_failure "missing reciprocal ADR supersedes" "${missing_reciprocal_adr_fixture}" "ADR 0001 superseded_by 0004 is not reciprocated"

mismatched_adr_scope_fixture="$(new_fixture mismatched-adr-scope)"
replace_text \
    "${mismatched_adr_scope_fixture}/docs/adr/0004-engine-owned-use-cases.md" \
    "shared_core_clause,transcoder_host_ambiguity,main_app_authority_fallback" \
    "shared_core_clause,transcoder_host_ambiguity"
expect_failure "mismatched ADR supersession scope" "${mismatched_adr_scope_fixture}" "supersession scope mismatch between ADR 0001 and ADR 0004"

project_owner_adr_fixture="$(new_fixture project-owner-adr-reciprocity)"
replace_text "${project_owner_adr_fixture}/docs/adr/0001-process-topology.md" \
    "accepted_by: project_owner_delegation" "accepted_by: project_owner"
replace_text "${project_owner_adr_fixture}/docs/adr/0004-engine-owned-use-cases.md" \
    "accepted_by: project_owner_delegation" "accepted_by: project_owner"
replace_text "${project_owner_adr_fixture}/docs/adr/0004-engine-owned-use-cases.md" \
    "- supersedes: 0001
" ""
expect_failure "project owner ADR reciprocity" "${project_owner_adr_fixture}" "ADR 0001 superseded_by 0004 is not reciprocated"

architecture_maintainer_adr_fixture="$(new_fixture architecture-maintainer-adr-scope)"
replace_text "${architecture_maintainer_adr_fixture}/docs/adr/0001-process-topology.md" \
    "accepted_by: project_owner_delegation" "accepted_by: architecture_maintainer"
replace_text "${architecture_maintainer_adr_fixture}/docs/adr/0004-engine-owned-use-cases.md" \
    "accepted_by: project_owner_delegation" "accepted_by: architecture_maintainer"
replace_text "${architecture_maintainer_adr_fixture}/docs/adr/0004-engine-owned-use-cases.md" \
    "shared_core_clause,transcoder_host_ambiguity,main_app_authority_fallback" \
    "shared_core_clause,transcoder_host_ambiguity"
expect_failure "architecture maintainer ADR scope" "${architecture_maintainer_adr_fixture}" "supersession scope mismatch between ADR 0001 and ADR 0004"

long_rule_fixture="$(new_fixture long-rule)"
while (( $(wc -l < "${long_rule_fixture}/.cursor/rules/example.mdc") < 50 )); do
    printf -- '- Boundary rule\n' >> "${long_rule_fixture}/.cursor/rules/example.mdc"
done
expect_failure "fifty-line rule" "${long_rule_fixture}" "must stay under 50 lines"

invalid_frontmatter_fixture="$(new_fixture invalid-frontmatter)"
cat > "${invalid_frontmatter_fixture}/.cursor/rules/example.mdc" <<'EOF'
---
description: Fixture rule
alwaysApply: true

# Fixture
EOF
expect_failure "invalid rule frontmatter" "${invalid_frontmatter_fixture}" "has invalid YAML frontmatter"

marketplace_clean_fixture="$(new_marketplace_fixture clean)"
expect_marketplace_success "clean marketplace contracts" "${marketplace_clean_fixture}"

marketplace_unaccepted_adr_fixture="$(new_marketplace_fixture unaccepted-adr)"
replace_text \
    "${marketplace_unaccepted_adr_fixture}/docs/adr/0012-signed-remote-catalog-releases.md" \
    "- status: accepted" \
    "- status: proposed"
expect_marketplace_failure \
    "marketplace requires accepted ADR" \
    "${marketplace_unaccepted_adr_fixture}" \
    "[MKT-ADR-GATE]"

marketplace_missing_compatibility_fixture="$(new_marketplace_fixture missing-compatibility)"
mutate_yaml \
    "${marketplace_missing_compatibility_fixture}/docs/compatibility/surfaces.yml" \
    'data["surfaces"].reject! { |surface| surface["id"] == "catalog_signing_keys" }'
expect_marketplace_failure \
    "marketplace requires compatibility entry" \
    "${marketplace_missing_compatibility_fixture}" \
    "[MKT-COMPATIBILITY-MISSING]"

marketplace_exposed_table_fixture="$(new_marketplace_fixture exposed-table)"
mkdir -p "${marketplace_exposed_table_fixture}/supabase/migrations"
printf '%s\n' \
    'create table public.secret_uploads (id uuid primary key);' \
    > "${marketplace_exposed_table_fixture}/supabase/migrations/001_invalid.sql"
expect_marketplace_failure \
    "marketplace rejects exposed table" \
    "${marketplace_exposed_table_fixture}" \
    "[MKT-EXPOSED-TABLE]"

marketplace_helper_import_fixture="$(new_marketplace_fixture helper-import)"
mkdir -p "${marketplace_helper_import_fixture}/Sources/WALILockScreenHelperRuntime"
printf '%s\n' \
    'import AVFoundation' \
    'struct UnsafeHelper {}' \
    > "${marketplace_helper_import_fixture}/Sources/WALILockScreenHelperRuntime/Unsafe.swift"
expect_marketplace_failure \
    "marketplace rejects helper media import" \
    "${marketplace_helper_import_fixture}" \
    "[MKT-HELPER-FORBIDDEN-IMPORT]"

marketplace_helper_api_fixture="$(new_marketplace_fixture helper-api)"
mkdir -p "${marketplace_helper_api_fixture}/Sources/WALILockScreenHelperRuntime"
printf '%s\n' \
    'import Foundation' \
    'let forbiddenLauncher = Process()' \
    > "${marketplace_helper_api_fixture}/Sources/WALILockScreenHelperRuntime/Unsafe.swift"
expect_marketplace_failure \
    "marketplace rejects helper process API" \
    "${marketplace_helper_api_fixture}" \
    "[MKT-HELPER-FORBIDDEN-API]"

marketplace_unpinned_dependency_fixture="$(new_marketplace_fixture unpinned-dependency)"
mutate_yaml \
    "${marketplace_unpinned_dependency_fixture}/project.yml" \
    'data["packages"]["Unsafe"] = {"url" => "https://example.invalid/unsafe.git", "branch" => "main"}'
expect_marketplace_failure \
    "marketplace rejects unpinned dependency" \
    "${marketplace_unpinned_dependency_fixture}" \
    "[MKT-DEPENDENCY-UNPINNED]"

marketplace_media_policy_fixture="$(new_marketplace_fixture media-policy-drift)"
mutate_yaml \
    "${marketplace_media_policy_fixture}/docs/security/media-policy.yml" \
    'data["processing"]["network"] = "host"'
expect_marketplace_failure \
    "marketplace rejects media policy drift" \
    "${marketplace_media_policy_fixture}" \
    "[MKT-MEDIA-POLICY]"

marketplace_data_inventory_fixture="$(new_marketplace_fixture data-inventory-drift)"
mutate_yaml \
    "${marketplace_data_inventory_fixture}/docs/security/data-inventory.yml" \
    'data["stores"].reject! { |store| store["id"] == "wali.rights_declarations" }'
expect_marketplace_failure \
    "marketplace rejects undocumented data store" \
    "${marketplace_data_inventory_fixture}" \
    "[MKT-DATA-INVENTORY]"

marketplace_new_table_inventory_fixture="$(new_marketplace_fixture new-table-without-inventory)"
mkdir -p "${marketplace_new_table_inventory_fixture}/supabase/migrations"
printf '%s\n' \
    'create table wali.undocumented_security_state (id uuid primary key);' \
    > "${marketplace_new_table_inventory_fixture}/supabase/migrations/001_invalid.sql"
expect_marketplace_failure \
    "marketplace rejects migration table absent from inventory" \
    "${marketplace_new_table_inventory_fixture}" \
    "[MKT-DATA-INVENTORY]"

if (( failure_count > 0 )); then
    printf 'Architecture policy fixture failures: %s; passes: %s\n' "${failure_count}" "${pass_count}" >&2
    exit 1
fi

printf 'Architecture policy tests passed: %s\n' "${pass_count}"
