#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "pathname"
require "psych"
require "rexml/document"
require "rexml/xpath"
require "set"
require_relative "check-store-graph"

class ArchitectureChecker
  REQUIRED_MODULE_IDS = %w[
    WALICore WALIModel WALIWire WALILockScreenWire WALIEngine WALIUI WALIAppRuntime
    WALICatalog WALICatalogRuntime WALIAgentRuntime WALITranscoderRuntime
    WALI WALIAgent WALITranscoder WALILockScreenHelperRuntime WALILockScreenHelper
  ].freeze

  REQUIRED_SURFACES = {
    "store_distribution" => "distribution_identity",
    "store_wire_contracts" => "wire_channel",
    "sqlite_schema" => "sqlite_schema",
    "artifact_manifest" => "artifact_manifest",
    "model_records" => "model_records",
    "app_agent_wire" => "wire_channel",
    "agent_worker_wire" => "wire_channel",
    "bundle_identifiers" => "bundle_identity",
    "application_group_containers" => "container_identity",
    "app_agent_service_names" => "service_identity",
    "agent_lock_screen_helper_service_names" => "service_identity",
    "agent_worker_service_names" => "service_identity",
    "content_store" => "content_store",
    "preferences" => "preferences",
    "url_schemes" => "url_scheme",
    "catalog_manifest" => "catalog_manifest",
    "catalog_revocations" => "catalog_revocations",
    "marketplace_server_schema" => "server_schema",
    "catalog_public_api" => "public_api",
    "creator_public_api" => "public_api",
    "moderation_public_api" => "public_api",
    "catalog_signing_keys" => "signing_key_registry",
    "classifier_model_registry" => "model_registry",
    "marketplace_storage_paths" => "storage_paths",
    "lock_screen_helper_wire" => "wire_channel",
    "lock_screen_manifest" => "lock_screen_manifest",
    "diagnostic_export" => "diagnostic_export"
  }.freeze

  ROLE_IDS = %w[
    project_owner architecture_maintainer module_maintainer domain_maintainer
    ipc_maintainer engine_maintainer presentation_maintainer
    foreground_runtime_maintainer agent_runtime_maintainer media_worker_maintainer
    storage_maintainer compatibility_maintainer diagnostics_maintainer
    catalog_maintainer security_responder
  ].freeze

  MODULE_FIELDS = %w[
    presence source_path owner_role stability current_capabilities
    target_responsibility current_target target_target
    current_allowed_internal_imports target_allowed_internal_imports
    current_allowed_internal_reexports target_allowed_internal_reexports
    forbidden_frameworks
  ].freeze

  SURFACE_FIELDS = %w[
    id kind owner_role implementation version product_compatibility
    module_access fixture_gate details
  ].freeze

  TARGET_FIELDS = %w[build_system name type].freeze
  SWIFT_PACKAGE_TARGET_FIELDS = %w[package_reference product target].freeze
  PACKAGE_PRODUCT_FIELDS = %w[kind linkage targets].freeze
  PACKAGE_TARGET_FIELDS = %w[kind path dependencies].freeze
  XCODE_TEST_TARGET_FIELDS = %w[
    type source_path build_dependencies package_dependencies
  ].freeze
  EDGE_KINDS = %w[build package embed_only].freeze
  CONFIGURATIONS = %w[Debug Development Release].freeze
  IDENTITY_BUILD_SETTINGS = {
    "WALI" => "WALI_APP_BUNDLE_IDENTIFIER",
    "WALIAgent" => "WALI_AGENT_BUNDLE_IDENTIFIER",
    "WALITranscoder" => "WALI_TRANSCODER_BUNDLE_IDENTIFIER",
    "WALILockScreenHelper" => "WALI_LOCK_SCREEN_HELPER_BUNDLE_IDENTIFIER"
  }.freeze
  EXPECTED_BUNDLE_IDENTIFIERS = {
    "Debug" => {
      "WALI" => "com.wali.debug.WALI",
      "WALIAgent" => "com.wali.debug.WALIAgent",
      "WALITranscoder" => "com.wali.debug.WALITranscoder",
      "WALILockScreenHelper" => "com.wali.debug.WALILockScreenHelper"
    },
    "Development" => {
      "WALI" => "com.wali.development.WALI",
      "WALIAgent" => "com.wali.development.WALIAgent",
      "WALITranscoder" => "com.wali.development.WALITranscoder",
      "WALILockScreenHelper" => "com.wali.development.WALILockScreenHelper"
    },
    "Release" => {
      "WALI" => "io.github.codewithinferno.wali.WALI",
      "WALIAgent" => "io.github.codewithinferno.wali.WALIAgent",
      "WALITranscoder" => "io.github.codewithinferno.wali.WALITranscoder",
      "WALILockScreenHelper" => "io.github.codewithinferno.wali.WALILockScreenHelper"
    }
  }.freeze
  EXPECTED_APPLICATION_GROUPS = {
    "Debug" => [],
    "Development" => ["group.com.wali.development.shared"],
    "Release" => ["group.com.wali.shared"]
  }.freeze
  EXPECTED_CONTROL_SERVICES = {
    "Debug" => "com.wali.debug.WALIAgent.control",
    "Development" => "com.wali.development.WALIAgent.control",
    "Release" => "io.github.codewithinferno.wali.WALIAgent.control"
  }.freeze
  REQUIRED_EMBED_ONLY_EDGES = Set.new([
    ["WALI", "WALIAgent"],
    ["WALIAgent", "WALITranscoder"],
    ["WALI", "WALILockScreenHelper"]
  ]).freeze
  REQUIRED_BUILD_EDGES = Set.new([
    ["WALI", "WALIAppRuntime"],
    ["WALIAppRuntime", "WALIUI"],
    ["WALIAppRuntime", "WALICatalogRuntime"],
    ["WALIAgent", "WALIAgentRuntime"],
    ["WALIAgentRuntime", "WALIUI"],
    ["WALITranscoder", "WALITranscoderRuntime"],
    ["WALILockScreenHelper", "WALILockScreenHelperRuntime"]
  ]).freeze
  TARGET_BUILD_EDGES = REQUIRED_BUILD_EDGES
  REQUIRED_PACKAGE_EDGES = Set.new([
    ["WALIAppRuntime", "WALIModel"],
    ["WALIAppRuntime", "WALIWire"],
    ["WALIAgentRuntime", "WALIModel"],
    ["WALIAgentRuntime", "WALIWire"],
    ["WALIAgentRuntime", "WALIEngine"],
    ["WALIAgentRuntime", "WALICatalog"],
    ["WALITranscoderRuntime", "WALIModel"],
    ["WALITranscoderRuntime", "WALIWire"],
    ["WALIUI", "WALIModel"],
    ["WALICatalogRuntime", "WALICatalog"],
    ["WALILockScreenHelperRuntime", "WALILockScreenWire"],
    ["WALIAgentRuntime", "WALILockScreenWire"]
  ]).freeze
  TARGET_PACKAGE_EDGES = (REQUIRED_PACKAGE_EDGES + Set.new([
    ["WALICatalogRuntime", "WALIModel"]
  ])).freeze
  TARGET_EMBED_ONLY_EDGES = REQUIRED_EMBED_ONLY_EDGES
  REQUIRED_PACKAGE_PRODUCTS = {
    "WALILockScreenWire" => {"kind" => "library", "linkage" => "static", "targets" => ["WALILockScreenWire"]},
    "WALIModel" => {
      "kind" => "library", "linkage" => "static", "targets" => ["WALIModel"]
    },
    "WALIWire" => {
      "kind" => "library", "linkage" => "static", "targets" => ["WALIWire"]
    },
    "WALIEngine" => {
      "kind" => "library", "linkage" => "static", "targets" => ["WALIEngine"]
    },
    "WALICatalog" => {
      "kind" => "library", "linkage" => "static", "targets" => ["WALICatalog"]
    }
  }.freeze
  REQUIRED_PACKAGE_TARGETS = {
    "WALILockScreenWire" => {"kind" => "regular", "path" => "Sources/WALILockScreenWire", "dependencies" => []},
    "WALILockScreenWireTests" => {"kind" => "test", "path" => "Tests/WALILockScreenWireTests", "dependencies" => ["WALILockScreenWire"]},
    "WALIModel" => {
      "kind" => "regular", "path" => "Sources/WALIModel", "dependencies" => []
    },
    "WALIWire" => {
      "kind" => "regular", "path" => "Sources/WALIWire",
      "dependencies" => ["WALIModel"]
    },
    "WALIEngine" => {
      "kind" => "regular", "path" => "Sources/WALIEngine",
      "dependencies" => ["WALIModel"]
    },
    "WALIModelTests" => {
      "kind" => "test", "path" => "Tests/WALIModelTests",
      "dependencies" => ["WALIModel"]
    },
    "WALIWireTests" => {
      "kind" => "test", "path" => "Tests/WALIWireTests",
      "dependencies" => ["WALIWire"]
    },
    "WALIEngineTests" => {
      "kind" => "test", "path" => "Tests/WALIEngineTests",
      "dependencies" => ["WALIEngine"]
    },
    "WALICatalog" => {
      "kind" => "regular", "path" => "Sources/WALICatalog",
      "dependencies" => ["WALIModel"]
    },
    "WALICatalogTests" => {
      "kind" => "test", "path" => "Tests/WALICatalogTests",
      "dependencies" => ["WALICatalog"]
    }
  }.freeze
  APPROVED_EXTERNAL_PACKAGES = {
    "Supabase" => {
      "url" => "https://github.com/supabase/supabase-swift.git",
      "exactVersion" => "2.54.1"
    }
  }.freeze
  PRESENCE_VALUES = %w[current planned absent].freeze
  IMPLEMENTATION_VALUES = %w[unimplemented configured implemented deferred].freeze
  STABILITY_VALUES = %w[stable_contract stable_interface adapter transitional].freeze
  ADR_STATUS_VALUES = %w[
    proposed accepted partially_superseded superseded deprecated
  ].freeze
  ACCEPTED_BY_VALUES = %w[
    pending project_owner architecture_maintainer project_owner_delegation
  ].freeze
  REQUIRED_ENVELOPE_FIELDS = %w[
    protocol_version message_type message_version request_id idempotency_key
    expected_revision payload_length
  ].freeze

  def initialize(root)
    @root = File.expand_path(root)
    @errors = []
    @modules = {}
    @swift_packages = {}
    @xcode_test_targets = {}
    @project = {}
    @configuration_settings = {}
    @target_build_settings = {}
    @resolved_build_settings = {}
    @xcconfig_settings = {}
  end

  def run
    modules_document = load_yaml(
      "docs/architecture/modules.yml",
      "missing docs/architecture/modules.yml"
    )
    surfaces_document = load_yaml(
      "docs/compatibility/surfaces.yml",
      "missing docs/compatibility/surfaces.yml"
    )
    @project = load_yaml("project.yml", "missing project.yml") || {}
    if @project.key?("include") || @project.key?("targetTemplates")
      Array(@project["include"]).each do |included|
        if included.is_a?(String) && included == "project-common.yml"
          load_yaml(included, "missing #{included}")
        else
          error("project.yml may only include the shared project-common.yml")
        end
      end
      begin
        @project = WALIProjectSpec.load(@root, "project.yml")
      rescue StandardError => exception
        error("project.yml template resolution failed: #{exception.message}")
      end
    end

    validate_modules(modules_document) if modules_document
    validate_project if modules_document && @project.is_a?(Hash)
    validate_swift_package_dumps if modules_document
    validate_imports if modules_document
    validate_surfaces(surfaces_document) if surfaces_document
    validate_rules
    validate_adrs
    validate_distribution_graphs(modules_document) if modules_document
    validate_generated_project_ignore

    @errors.each { |message| warn "Architecture violation: #{message}" }
    if @errors.empty?
      puts "Architecture checks passed"
      0
    else
      warn "Architecture checks failed: #{@errors.length} violation(s)"
      1
    end
  end

  private

  def error(message)
    @errors << message
  end

  def repository_path(relative)
    File.join(@root, relative)
  end

  def load_yaml(relative, missing_message)
    path = repository_path(relative)
    unless File.file?(path)
      error(missing_message)
      return nil
    end

    content = File.read(path)
    stream = Psych.parse_stream(content, relative)
    detect_duplicate_keys(stream, File.basename(relative))
    value = Psych.safe_load(
      content,
      permitted_classes: [],
      permitted_symbols: [],
      aliases: false,
      filename: relative
    )
    unless value.is_a?(Hash)
      error("#{File.basename(relative)} root must be a mapping")
      return nil
    end
    value
  rescue Psych::SyntaxError, Psych::BadAlias => exception
    error("#{File.basename(relative)} is invalid YAML: #{exception.message.lines.first.to_s.strip}")
    nil
  end

  def detect_duplicate_keys(node, basename)
    case node
    when Psych::Nodes::Mapping
      seen = {}
      node.children.each_slice(2) do |key_node, value_node|
        if key_node.is_a?(Psych::Nodes::Scalar)
          key = key_node.value
          error(%(#{basename} contains duplicate key "#{key}")) if seen[key]
          seen[key] = true
        end
        detect_duplicate_keys(value_node, basename)
      end
    when Psych::Nodes::Sequence, Psych::Nodes::Document, Psych::Nodes::Stream
      node.children.each { |child| detect_duplicate_keys(child, basename) }
    end
  end

  def validate_modules(document)
    @loaded_modules_document = document
    error("modules.yml schema_version must be 3") unless document["schema_version"] == 3
    validate_schema_document(document, "docs/architecture/modules-schema.md", "modules.yml")

    modules = document["modules"]
    unless modules.is_a?(Hash)
      error("modules.yml modules must be a mapping")
      return
    end
    @modules = modules
    @swift_packages = document["swift_packages"]
    unless @swift_packages.is_a?(Hash)
      error("modules.yml swift_packages must be a mapping")
      @swift_packages = {}
    end
    @xcode_test_targets = document["xcode_test_targets"]
    unless @xcode_test_targets.is_a?(Hash)
      error("modules.yml xcode_test_targets must be a mapping")
      @xcode_test_targets = {}
    end

    REQUIRED_MODULE_IDS.each do |id|
      error("modules.yml missing required module #{id}") unless modules.key?(id)
    end

    modules.each do |id, value|
      unless id.is_a?(String) && !id.empty?
        error("modules.yml module IDs must be non-empty strings")
        next
      end
      validate_module(id, value)
    end
    validate_xcode_test_target_registry

    edges = document["edges"]
    unless edges.is_a?(Hash)
      error("modules.yml edges must be a mapping")
      return
    end
    %w[current target].each do |phase|
      phase_edges = edges[phase]
      unless phase_edges.is_a?(Hash)
        error("modules.yml edges.#{phase} must be a mapping")
        next
      end
      EDGE_KINDS.each do |kind|
        validate_edge_list(phase, kind, phase_edges[kind])
      end
      validate_acyclic_edges(phase, phase_edges)
    end
    validate_swift_package_registry
    validate_task_three_graph(document)
  end

  def validate_schema_document(document, expected, basename)
    actual = document["schema_document"]
    error("#{basename} schema_document must be #{expected}") unless actual == expected
    return unless actual.is_a?(String)

    path = safe_relative_path(actual, "#{basename} schema_document")
    error("#{basename} schema document does not exist: #{actual}") if path && !File.file?(path)
  end

  def validate_module(id, value)
    unless value.is_a?(Hash)
      error("#{id} module entry must be a mapping")
      return
    end
    require_fields(value, MODULE_FIELDS, id)

    presence = value["presence"]
    error("#{id} presence must be current, planned, or absent") unless PRESENCE_VALUES.include?(presence)

    source_path = value["source_path"]
    source_full_path = safe_relative_path(source_path, "#{id} source_path")
    owner = value["owner_role"]
    error("#{id} uses unknown owner_role #{owner}") unless ROLE_IDS.include?(owner)
    error("#{id} stability is invalid") unless STABILITY_VALUES.include?(value["stability"])
    error("#{id} target_responsibility must be a non-empty string") unless nonempty_string?(value["target_responsibility"])

    current_capabilities = string_array(value["current_capabilities"], "#{id} current_capabilities")
    current_imports = string_array(
      value["current_allowed_internal_imports"],
      "#{id} current_allowed_internal_imports"
    )
    target_imports = string_array(
      value["target_allowed_internal_imports"],
      "#{id} target_allowed_internal_imports"
    )
    current_reexports = string_array(
      value["current_allowed_internal_reexports"],
      "#{id} current_allowed_internal_reexports"
    )
    target_reexports = string_array(
      value["target_allowed_internal_reexports"],
      "#{id} target_allowed_internal_reexports"
    )
    forbidden_frameworks = string_array(value["forbidden_frameworks"], "#{id} forbidden_frameworks")
    if forbidden_frameworks.include?("SQLite3")
      missing_persistence = %w[CoreData SwiftData] - forbidden_frameworks
      error("#{id} persistence policy is missing #{missing_persistence.join(', ')}") if missing_persistence.any?
    end

    if presence == "current"
      error("current module #{id} must declare current_capabilities") if current_capabilities.empty?
      error("current module #{id} source_path does not exist") if source_full_path && !Dir.exist?(source_full_path)
      validate_target(id, value["current_target"], "current_target", required: true)
    elsif presence == "planned"
      error("planned module #{id} must have empty current_capabilities") unless current_capabilities.empty?
      error("planned module #{id} must have empty current_allowed_internal_imports") unless current_imports.empty?
      error("planned module #{id} must have empty current_allowed_internal_reexports") unless current_reexports.empty?
      error("planned module #{id} must have null current_target") unless value["current_target"].nil?
      error("planned module #{id} source_path already exists; mark it current") if source_full_path && Dir.exist?(source_full_path)
    elsif presence == "absent"
      error("absent module #{id} must have empty current_capabilities") unless current_capabilities.empty?
      error("absent module #{id} must have empty current_allowed_internal_imports") unless current_imports.empty?
      error("absent module #{id} must have empty target_allowed_internal_imports") unless target_imports.empty?
      error("absent module #{id} must have empty current_allowed_internal_reexports") unless current_reexports.empty?
      error("absent module #{id} must have empty target_allowed_internal_reexports") unless target_reexports.empty?
      error("absent module #{id} must have null current_target") unless value["current_target"].nil?
      error("absent module #{id} must have null target_target") unless value["target_target"].nil?
      error("absent module #{id} source_path still exists") if source_full_path && Dir.exist?(source_full_path)
    end

    validate_target(id, value["target_target"], "target_target", required: presence == "planned")
    validate_module_references(id, current_imports, "current", "imports", require_current: true)
    validate_module_references(id, target_imports, "target", "imports", require_current: false)
    validate_module_references(id, current_reexports, "current", "reexports", require_current: true)
    validate_module_references(id, target_reexports, "target", "reexports", require_current: false)
    unless (current_reexports - current_imports).empty?
      error("#{id} current re-export allowlist must be a subset of its import allowlist")
    end
    unless (target_reexports - target_imports).empty?
      error("#{id} target re-export allowlist must be a subset of its import allowlist")
    end
  end

  def validate_xcode_test_target_registry
    @xcode_test_targets.each do |target_name, definition|
      unless nonempty_string?(target_name) && definition.is_a?(Hash)
        error("Xcode test target declarations must use non-empty names and mappings")
        next
      end
      require_exact_fields(
        definition,
        XCODE_TEST_TARGET_FIELDS,
        "Xcode test target #{target_name}"
      )
      unless %w[bundle.unit-test bundle.ui-testing].include?(definition["type"])
        error("Xcode test target #{target_name} type is invalid")
      end
      source_path = safe_relative_path(
        definition["source_path"],
        "Xcode test target #{target_name} source_path"
      )
      unless source_path && Dir.exist?(source_path)
        error("Xcode test target #{target_name} source_path does not exist")
      end

      build_dependencies = string_array(
        definition["build_dependencies"],
        "Xcode test target #{target_name} build_dependencies"
      )
      package_dependencies = string_array(
        definition["package_dependencies"],
        "Xcode test target #{target_name} package_dependencies"
      )
      build_dependencies.each do |module_id|
        descriptor = @modules.dig(module_id, "current_target")
        unless @modules.dig(module_id, "presence") == "current" &&
               descriptor.is_a?(Hash) &&
               descriptor["build_system"] == "xcode"
          error("Xcode test target #{target_name} references non-Xcode module #{module_id}")
        end
      end
      package_dependencies.each do |module_id|
        descriptor = @modules.dig(module_id, "current_target")
        unless @modules.dig(module_id, "presence") == "current" &&
               descriptor.is_a?(Hash) &&
               descriptor["build_system"] == "swift_package"
          error("Xcode test target #{target_name} references non-package module #{module_id}")
        end
      end
      if definition["type"] == "bundle.unit-test" && source_path && Dir.exist?(source_path)
        validate_unit_test_import_contract(
          target_name,
          source_path,
          build_dependencies,
          package_dependencies
        )
      end
    end
  end

  def validate_unit_test_import_contract(target_name, source_path, build_dependencies, package_dependencies)
    imported_modules = parsed_swift_import_roots(
      source_path,
      "Xcode test target #{target_name}"
    ).select do |module_id|
      @modules.dig(module_id, "presence") == "current"
    end
    imported_build = imported_modules.select do |module_id|
      @modules.dig(module_id, "current_target", "build_system") == "xcode"
    end
    imported_packages = imported_modules.select do |module_id|
      @modules.dig(module_id, "current_target", "build_system") == "swift_package"
    end

    unless imported_build.sort == build_dependencies.sort
      error("#{target_name} build dependencies must match its direct source imports")
    end
    unless imported_packages.sort == package_dependencies.sort
      error("#{target_name} package dependencies must match its direct source imports")
    end
  end

  def parsed_swift_import_roots(source_path, label)
    imports = Set.new
    Dir.glob(File.join(source_path, "**", "*.swift")).sort.each do |swift_file|
      stdout, stderr, status = Open3.capture3(
        "xcrun", "swiftc", "-frontend", "-dump-parse", swift_file
      )
      unless status.success?
        detail = stderr.lines.find { |line| !line.strip.empty? }.to_s.strip
        relative = Pathname.new(swift_file).relative_path_from(Pathname.new(@root))
        error("Swift parser failed for #{label} source #{relative}: #{detail}")
        next
      end
      stdout.scan(/\(import_decl\b[^\n]*\bmodule="([^"]+)"/).flatten.each do |parsed_import|
        imports << parsed_import.split(".", 2).first
      end
    end
    imports
  rescue Errno::ENOENT => exception
    error("Swift parser is unavailable for #{label}: #{exception.message}")
    imports
  end

  def validate_target(id, value, field, required:)
    if value.nil?
      error("#{id} #{field} must be a mapping") if required
      return
    end
    unless value.is_a?(Hash)
      error("#{id} #{field} must be a mapping")
      return
    end
    require_fields(value, TARGET_FIELDS, "#{id} #{field}")
    error("#{id} #{field} build_system is invalid") unless %w[xcode swift_package].include?(value["build_system"])
    error("#{id} #{field} name must equal module ID") unless value["name"] == id
    error("#{id} #{field} type must be a non-empty string") unless nonempty_string?(value["type"])
    if value["build_system"] == "swift_package"
      require_fields(value, SWIFT_PACKAGE_TARGET_FIELDS, "#{id} #{field}")
      phase = field == "current_target" ? "current" : "target"
      package = @swift_packages[value["package_reference"]]
      unless package.is_a?(Hash)
        error("#{id} #{field} references unknown Swift package #{value['package_reference']}")
        return
      end
      unless package.dig(phase, "products", value["product"])
        error("#{id} #{field} references unknown #{phase} Swift package product #{value['product']}")
      end
      unless package.dig(phase, "targets", value["target"])
        error("#{id} #{field} references unknown #{phase} Swift package target #{value['target']}")
      end
      product = package.dig(phase, "products", value["product"])
      if product.is_a?(Hash) && !Array(product["targets"]).include?(value["target"])
        error(
          "#{id} #{field} product #{value['product']} " \
          "does not export target #{value['target']}"
        )
      end
      unless value["target"] == id
        error("#{id} #{field} target #{value['target']} must equal the module ID")
      end
    end
  end

  def validate_module_references(id, references, phase, kind, require_current:)
    field = "#{phase}_allowed_internal_#{kind}"
    references.each do |reference|
      unless @modules.key?(reference)
        error("#{id} #{field} references unknown module #{reference}")
        next
      end
      if @modules.dig(reference, "presence") == "absent"
        error("#{id} #{field} references absent module #{reference}")
      end
      if require_current && @modules.dig(reference, "presence") != "current"
        error("#{id} #{field} references non-current module #{reference}")
      end
      error("#{id} cannot #{kind == 'imports' ? 'import' : 're-export'} itself") if reference == id
    end
  end

  def validate_edge_list(phase, kind, value)
    unless value.is_a?(Array)
      error("modules.yml edges.#{phase}.#{kind} must be an array")
      return
    end
    seen = Set.new
    value.each do |edge|
      unless edge.is_a?(Hash) && edge.keys.sort == %w[from to]
        error("#{phase} #{kind} edge must contain only from and to")
        next
      end
      from = edge["from"]
      to = edge["to"]
      unless @modules.key?(from) && @modules.key?(to)
        error("#{phase} #{kind} edge references unknown module #{from} -> #{to}")
        next
      end
      if phase == "current" &&
         (@modules.dig(from, "presence") != "current" || @modules.dig(to, "presence") != "current")
        error("current #{kind} edge references non-current module #{from} -> #{to}")
      elsif phase == "target" &&
            (@modules.dig(from, "presence") == "absent" || @modules.dig(to, "presence") == "absent")
        error("target #{kind} edge references absent module #{from} -> #{to}")
      end
      if kind == "package" && package_target_module?(from, phase) && package_target_module?(to, phase)
        error("#{phase} package edge #{from} -> #{to} duplicates canonical Swift package target dependencies")
      end
      key = [from, to]
      error("duplicate #{phase} #{kind} edge #{from} -> #{to}") if seen.include?(key)
      seen << key
    end
  end

  def validate_acyclic_edges(phase, phase_edges)
    graph = Hash.new { |hash, key| hash[key] = [] }
    EDGE_KINDS.each do |kind|
      Array(phase_edges[kind]).each do |edge|
        next unless edge.is_a?(Hash)
        next unless @modules.key?(edge["from"]) && @modules.key?(edge["to"])

        graph[edge["from"]] << edge["to"]
      end
    end
    error("#{phase} module dependency graph contains a cycle") if cyclic_graph?(graph)
  end

  def validate_swift_package_registry
    if @swift_packages.empty?
      error("modules.yml must declare at least one Swift package")
      return
    end

    @swift_packages.each do |reference_id, package|
      unless package.is_a?(Hash)
        error("Swift package #{reference_id} must be a mapping")
        next
      end
      require_exact_fields(
        package,
        %w[xcodegen_reference current target],
        "Swift package #{reference_id}"
      )
      reference = package["xcodegen_reference"]
      unless reference.is_a?(Hash)
        error("Swift package #{reference_id} xcodegen_reference must be a mapping")
        next
      end
      require_exact_fields(reference, %w[name path], "Swift package #{reference_id} xcodegen_reference")
      error("Swift package reference name must equal #{reference_id}") unless reference["name"] == reference_id
      safe_relative_path(reference["path"], "Swift package #{reference_id} path")

      %w[current target].each do |phase|
        validate_package_phase(reference_id, phase, package[phase])
      end
    end
  end

  def validate_task_three_graph(document)
    unless @modules.dig("WALICore", "presence") == "absent"
      error("WALICore imported module must be absent after the package split")
    end
    %w[WALIModel WALIWire WALIEngine WALICatalog WALICatalogRuntime].each do |module_id|
      unless @modules.dig(module_id, "presence") == "current"
        error("#{module_id} must be current after the package split")
      end
    end

    unless @swift_packages.keys == ["WALICore"]
      error("Swift package registry must contain exactly the WALICore package reference")
      return
    end

    reference = @swift_packages.dig("WALICore", "xcodegen_reference")
    unless reference == {"name" => "WALICore", "path" => "Packages/WALICore"}
      error("WALICore package reference must remain at Packages/WALICore")
    end

    %w[current target].each do |phase|
      products = @swift_packages.dig("WALICore", phase, "products")
      targets = @swift_packages.dig("WALICore", phase, "targets")
      unless products == REQUIRED_PACKAGE_PRODUCTS
        error("#{phase} WALICore package products do not match the governed product graph")
      end
      unless targets == REQUIRED_PACKAGE_TARGETS
        error("#{phase} WALICore package targets do not match the governed target graph")
      end
    end

    {
      "current" => {
        "build" => REQUIRED_BUILD_EDGES,
        "package" => REQUIRED_PACKAGE_EDGES,
        "embed_only" => REQUIRED_EMBED_ONLY_EDGES
      },
      "target" => {
        "build" => TARGET_BUILD_EDGES,
        "package" => TARGET_PACKAGE_EDGES,
        "embed_only" => TARGET_EMBED_ONLY_EDGES
      }
    }.each do |phase, expected_by_kind|
      expected_by_kind.each do |kind, expected|
        actual = Array(document.dig("edges", phase, kind)).each_with_object(Set.new) do |edge, result|
          result << [edge["from"], edge["to"]] if edge.is_a?(Hash)
        end
        unless actual == expected
          error("#{phase} #{kind} graph does not match the Task 3 architecture")
        end
      end
    end
  end

  def validate_package_phase(reference_id, phase, value)
    unless value.is_a?(Hash)
      error("Swift package #{reference_id} #{phase} must be a mapping")
      return
    end
    require_exact_fields(value, %w[products targets], "Swift package #{reference_id} #{phase}")
    products = value["products"]
    targets = value["targets"]
    unless products.is_a?(Hash)
      error("Swift package #{reference_id} #{phase} products must be a mapping")
      products = {}
    end
    unless targets.is_a?(Hash)
      error("Swift package #{reference_id} #{phase} targets must be a mapping")
      targets = {}
    end

    targets.each do |target_name, target|
      unless target.is_a?(Hash)
        error("#{phase} Swift package target #{target_name} must be a mapping")
        next
      end
      require_exact_fields(target, PACKAGE_TARGET_FIELDS, "#{phase} Swift package target #{target_name}")
      error("#{phase} Swift package target #{target_name} kind is invalid") unless %w[regular executable test].include?(target["kind"])
      target_path = safe_package_relative_path(target["path"], "#{phase} Swift package target #{target_name} path")
      if phase == "current" && target_path
        package_root = @swift_packages.dig(reference_id, "xcodegen_reference", "path")
        full_path = package_root && repository_path(File.join(package_root, target["path"]))
        error("current Swift package target #{target_name} path does not exist") unless full_path && Dir.exist?(full_path)
      end
      dependencies = string_array(target["dependencies"], "#{phase} Swift package target #{target_name} dependencies")
      dependencies.each do |dependency|
        error("#{phase} Swift package target #{target_name} references unknown target #{dependency}") unless targets.key?(dependency)
      end
    end

    products.each do |product_name, product|
      unless product.is_a?(Hash)
        error("#{phase} Swift package product #{product_name} must be a mapping")
        next
      end
      require_exact_fields(product, PACKAGE_PRODUCT_FIELDS, "#{phase} Swift package product #{product_name}")
      unless product["kind"] == "library" && product["linkage"] == "static"
        error("#{phase} Swift package product #{product_name} must be a static library")
      end
      product_targets = string_array(product["targets"], "#{phase} Swift package product #{product_name} targets")
      error("#{phase} Swift package product #{product_name} must contain a target") if product_targets.empty?
      product_targets.each do |target_name|
        error("#{phase} Swift package product #{product_name} references unknown target #{target_name}") unless targets.key?(target_name)
      end
    end

    validate_package_product_target_mapping(phase, products, targets)
    validate_package_target_import_contracts(reference_id, phase, products, targets)

    graph = targets.each_with_object({}) do |(target_name, target), result|
      result[target_name] = target.is_a?(Hash) ? Array(target["dependencies"]) : []
    end
    if cyclic_graph?(graph)
      error("#{phase} Swift package target graph contains a cycle")
    end
  end

  def validate_package_product_target_mapping(phase, products, targets)
    production_targets = targets.each_with_object(Set.new) do |(target_name, target), result|
      if target.is_a?(Hash) && %w[regular executable].include?(target["kind"])
        result << target_name
      end
    end
    export_counts = Hash.new(0)

    products.each do |product_name, product|
      next unless product.is_a?(Hash)

      exported_targets = Array(product["targets"])
      valid_targets = exported_targets.select { |target_name| production_targets.include?(target_name) }
      unless exported_targets.length == 1 && valid_targets.length == 1
        error(
          "#{phase} Swift package product #{product_name} " \
          "must export exactly one production target"
        )
      end
      valid_targets.each { |target_name| export_counts[target_name] += 1 }
    end

    production_targets.each do |target_name|
      unless export_counts[target_name] == 1
        error(
          "#{phase} Swift package target #{target_name} " \
          "must be exported by exactly one product"
        )
      end
    end
  end

  def validate_package_target_import_contracts(reference_id, phase, products, targets)
    module_by_target = package_modules_by_target(reference_id, phase)
    target_by_module = module_by_target.invert

    targets.each do |target_name, target|
      next unless target.is_a?(Hash) && %w[regular executable].include?(target["kind"])

      unless module_by_target.key?(target_name)
        error("#{phase} Swift package target #{target_name} has no module import policy")
      end
    end

    module_by_target.each do |target_name, module_id|
      target = targets[target_name]
      next unless target.is_a?(Hash)

      import_field =
        phase == "current" ? "current_allowed_internal_imports" : "target_allowed_internal_imports"
      imported_modules = Array(@modules.dig(module_id, import_field))
      canonical_dependencies = Array(target["dependencies"])
      expected_dependencies = imported_modules.each_with_object([]) do |imported_module, result|
        target_name = target_by_module[imported_module]
        result << target_name if target_name
      end
      if expected_dependencies.length != imported_modules.length ||
         expected_dependencies.sort != canonical_dependencies.sort
        error(
          "#{phase} Swift package target #{target_name} dependencies do not match " \
          "#{module_id} permitted internal imports"
        )
      end
    end

    targets.each do |target_name, target|
      next unless target.is_a?(Hash) && target["kind"] == "test"

      subject = target_name.delete_suffix("Tests")
      expected_path = File.join("Tests", target_name)
      unless target_name.end_with?("Tests") &&
             targets.dig(subject, "kind") == "regular" &&
             Array(target["dependencies"]) == [subject]
        error("#{phase} Swift package test target #{target_name} must depend exactly on #{subject}")
      end
      unless target["path"] == expected_path
        error("#{phase} Swift package test target #{target_name} path must be #{expected_path}")
      end
    end

    products.each_value do |product|
      next unless product.is_a?(Hash)

      Array(product["targets"]).each do |subject|
        next unless targets.dig(subject, "kind") == "regular"

        test_target = "#{subject}Tests"
        unless targets.dig(test_target, "kind") == "test"
          error("#{phase} Swift package target #{subject} is missing test target #{test_target}")
        end
      end
    end
  end

  def package_modules_by_target(reference_id, phase)
    target_field = phase == "current" ? "current_target" : "target_target"
    @modules.each_with_object({}) do |(module_id, definition), result|
      descriptor = definition.is_a?(Hash) ? definition[target_field] : nil
      next unless descriptor.is_a?(Hash)
      next unless descriptor["build_system"] == "swift_package"
      next unless descriptor["package_reference"] == reference_id

      result[descriptor["target"]] = module_id
    end
  end

  def package_target_module?(module_id, phase)
    target_field = phase == "current" ? "current_target" : "target_target"
    descriptor = @modules.dig(module_id, target_field)
    descriptor.is_a?(Hash) && descriptor["build_system"] == "swift_package"
  end

  def validate_swift_package_dumps
    @swift_packages.each do |reference_id, package|
      next unless package.is_a?(Hash)
      package_path = package.dig("xcodegen_reference", "path")
      full_path = safe_relative_path(package_path, "Swift package #{reference_id} path")
      next unless full_path && Dir.exist?(full_path)

      stdout, stderr, status = Open3.capture3(
        "swift", "package", "dump-package", "--package-path", full_path
      )
      unless status.success?
        detail = stderr.lines.find { |line| !line.strip.empty? }.to_s.strip
        error("swift package dump-package failed for #{reference_id}: #{detail}")
        next
      end
      begin
        dump = JSON.parse(stdout)
      rescue JSON::ParserError => exception
        error("swift package dump-package returned invalid JSON for #{reference_id}: #{exception.message}")
        next
      end
      validate_package_dump(reference_id, package["current"], dump)
    end
  rescue Errno::ENOENT => exception
    error("swift package dump-package is unavailable: #{exception.message}")
  end

  def validate_package_dump(reference_id, declared, dump)
    declared_products = declared.is_a?(Hash) && declared["products"].is_a?(Hash) ? declared["products"] : {}
    declared_targets = declared.is_a?(Hash) && declared["targets"].is_a?(Hash) ? declared["targets"] : {}
    actual_products = Array(dump["products"]).to_h { |product| [product["name"], product] }
    actual_targets = Array(dump["targets"]).to_h { |target| [target["name"], target] }

    (actual_products.keys - declared_products.keys).sort.each do |name|
      error("undeclared current Swift package product #{name}")
    end
    (declared_products.keys - actual_products.keys).sort.each do |name|
      error("declared current Swift package product #{name} is missing")
    end
    (actual_targets.keys - declared_targets.keys).sort.each do |name|
      error("undeclared current Swift package target #{name}")
    end
    (declared_targets.keys - actual_targets.keys).sort.each do |name|
      error("declared current Swift package target #{name} is missing")
    end

    (actual_products.keys & declared_products.keys).each do |name|
      actual = actual_products[name]
      declaration = declared_products[name]
      library_linkage = Array(actual.dig("type", "library")).first
      unless declaration["kind"] == "library" &&
             declaration["linkage"] == "static" &&
             library_linkage == "static"
        error("Swift package product #{name} must be a static library")
      end
      unless Array(declaration["targets"]).sort == Array(actual["targets"]).sort
        error("Swift package product #{name} targets do not match")
      end
    end

    (actual_targets.keys & declared_targets.keys).each do |name|
      actual = actual_targets[name]
      declaration = declared_targets[name]
      error("Swift package target #{name} kind does not match") unless declaration["kind"] == actual["type"]
      actual_path = actual["path"] || default_package_target_path(actual["type"], name)
      error("Swift package target #{name} path does not match") unless declaration["path"] == actual_path
      actual_dependencies = package_dump_dependencies(actual["dependencies"])
      unless Array(declaration["dependencies"]).sort == actual_dependencies.sort
        error("Swift package target #{name} dependencies do not match")
      end
    end
  end

  def package_dump_dependencies(dependencies)
    Array(dependencies).map do |dependency|
      if dependency["byName"]
        Array(dependency["byName"]).first
      elsif dependency["target"]
        Array(dependency["target"]).first
      elsif dependency["product"]
        values = Array(dependency["product"])
        values[1] ? "product:#{values[1]}:#{values[0]}" : "product:#{values[0]}"
      end
    end.compact
  end

  def default_package_target_path(kind, name)
    kind == "test" ? File.join("Tests", name) : File.join("Sources", name)
  end

  def cyclic_graph?(graph)
    visiting = Set.new
    visited = Set.new
    visit = lambda do |node|
      return true if visiting.include?(node)
      return false if visited.include?(node)

      visiting << node
      cycle = Array(graph[node]).any? { |neighbor| visit.call(neighbor) }
      visiting.delete(node)
      visited << node
      cycle
    end
    graph.keys.any? { |node| visit.call(node) }
  end

  def validate_project
    targets = @project["targets"]
    unless targets.is_a?(Hash)
      error("project.yml targets must be a mapping")
      return
    end
    validate_project_configuration_files
    validate_project_package_references
    validate_project_target_registry(targets)
    validate_project_test_targets(targets)
    validate_duplicate_project_dependencies(targets)

    @modules.each do |id, definition|
      next unless definition.is_a?(Hash)
      next unless definition["presence"] == "current"
      current_target = definition["current_target"]
      next unless current_target.is_a?(Hash)
      if current_target["build_system"] == "swift_package"
        validate_project_package(id, definition, current_target)
        next
      end
      next unless current_target["build_system"] == "xcode"

      target = targets[current_target["name"]]
      unless target.is_a?(Hash)
        error("#{id} current target is missing from project.yml")
        next
      end
      if target["type"] != current_target["type"]
        error("#{id} target type mismatch: manifest #{current_target['type']}, project.yml #{target['type']}")
      end
      source_paths = Array(target["sources"]).map do |source|
        source.is_a?(Hash) ? source["path"] : source
      end.compact
      unless source_paths.include?(definition["source_path"])
        error("#{id} source_path does not match project.yml")
      end
    end

    actual_edges = project_edges(targets)
    EDGE_KINDS.each do |kind|
      declared = manifest_edge_set("current", kind)
      actual = actual_edges.fetch(kind)
      next if declared == actual

      error(
        "current #{kind} edges do not match project.yml " \
        "(declared: #{format_edges(declared)}; actual: #{format_edges(actual)})"
      )
    end
    validate_required_embed_topology(targets, actual_edges)
    validate_identity_build_settings(targets)
    validate_direct_service_metadata(targets)
  end

  def validate_project_target_registry(targets)
    production_targets = current_xcode_target_modules.keys.to_set
    declared_tests = @xcode_test_targets.keys.to_set

    targets.each do |target_name, target|
      next if production_targets.include?(target_name) || declared_tests.include?(target_name)

      type = target.is_a?(Hash) ? target["type"] : nil
      if %w[bundle.unit-test bundle.ui-testing].include?(type)
        error("project.yml contains undeclared test target #{target_name}")
      else
        error("project.yml contains unregistered production target #{target_name}")
      end
    end
  end

  def validate_project_test_targets(targets)
    package_modules = current_package_dependency_modules
    xcode_modules = current_xcode_target_modules

    @xcode_test_targets.each do |target_name, definition|
      next unless definition.is_a?(Hash)

      target = targets[target_name]
      unless target.is_a?(Hash)
        error("declared Xcode test target #{target_name} is missing from project.yml")
        next
      end
      unless target["type"] == definition["type"]
        error("Xcode test target #{target_name} type does not match project.yml")
      end
      source_paths = Array(target["sources"]).map do |source|
        source.is_a?(Hash) ? source["path"] : source
      end.compact
      unless source_paths.include?(definition["source_path"])
        error("Xcode test target #{target_name} source_path does not match project.yml")
      end

      actual_build = []
      actual_package = []
      Array(target["dependencies"]).each do |dependency|
        next unless dependency.is_a?(Hash)

        if dependency["package"]
          reference = dependency["package"]
          product = dependency["product"] || reference
          module_id = package_modules[[reference, product]]
          if module_id
            actual_package << module_id
          else
            error("#{target_name} project.yml dependency references unregistered package #{reference}")
          end
        elsif dependency["target"]
          module_id = xcode_modules[dependency["target"]]
          if module_id
            actual_build << module_id
          else
            error("#{target_name} project.yml dependency references unregistered target #{dependency['target']}")
          end
        end
      end

      unless actual_build.sort == Array(definition["build_dependencies"]).sort
        error("Xcode test target #{target_name} build dependencies do not match project.yml")
      end
      unless actual_package.sort == Array(definition["package_dependencies"]).sort
        error("Xcode test target #{target_name} package dependencies do not match project.yml")
      end
    end
  end

  def validate_duplicate_project_dependencies(targets)
    targets.each do |target_name, target|
      next unless target.is_a?(Hash)

      seen = Set.new
      Array(target["dependencies"]).each do |dependency|
        next unless dependency.is_a?(Hash)

        if dependency["package"]
          kind = "package"
          unless nonempty_string?(dependency["product"])
            error(
              "#{target_name} package dependency #{dependency['package']} " \
              "must name an explicit product"
            )
          end
          destination = dependency["product"] || dependency["package"]
        elsif dependency["target"]
          kind =
            dependency["embed"] == true && dependency["link"] == false ?
              "embed_only" : "build"
          destination = dependency["target"]
        else
          next
        end
        key = [kind, destination]
        error("#{target_name} has duplicate #{kind} dependency #{destination}") if seen.include?(key)
        seen << key
      end
    end
  end

  def current_xcode_target_modules
    @current_xcode_target_modules ||= @modules.each_with_object({}) do |(module_id, definition), result|
      descriptor = definition.is_a?(Hash) ? definition["current_target"] : nil
      next unless definition.is_a?(Hash) && definition["presence"] == "current"
      next unless descriptor.is_a?(Hash) && descriptor["build_system"] == "xcode"

      result[descriptor["name"]] = module_id
    end
  end

  def current_package_dependency_modules
    @current_package_dependency_modules ||= @modules.each_with_object({}) do |(module_id, definition), result|
      descriptor = definition.is_a?(Hash) ? definition["current_target"] : nil
      next unless definition.is_a?(Hash) && definition["presence"] == "current"
      next unless descriptor.is_a?(Hash) && descriptor["build_system"] == "swift_package"

      result[[descriptor["package_reference"], descriptor["product"]]] = module_id
    end
  end

  def validate_project_configuration_files
    configs = @project["configs"]
    unless configs.is_a?(Hash) && configs.keys.sort == CONFIGURATIONS.sort
      error("project.yml configs must contain exactly Debug, Development, Release")
    end

    config_files = @project["configFiles"]
    unless config_files.is_a?(Hash)
      error("project.yml configFiles must be a mapping")
      return
    end
    unless config_files.keys.sort == CONFIGURATIONS.sort
      error("project.yml configFiles must contain exactly Debug, Development, Release")
    end

    CONFIGURATIONS.each do |configuration|
      relative = config_files[configuration]
      path = safe_relative_path(relative, "project.yml #{configuration} config file")
      if path && File.file?(path)
        configuration_file_settings(configuration)
      elsif path
        error("project.yml #{configuration} config file does not exist")
      end
    end

    marketplace_flag = @project.dig(
      "targets", "WALI", "info", "properties", "WALIMarketplaceEnabled"
    )
    unless marketplace_flag == "$(WALI_MARKETPLACE_ENABLED)"
      error("WALI WALIMarketplaceEnabled must reference $(WALI_MARKETPLACE_ENABLED)")
    end
    release_value = resolved_target_build_setting(
      "WALI", "Release", "WALI_MARKETPLACE_ENABLED"
    )
    release_settings = target_build_settings("WALI", "Release")
    if release_value != "NO" || conditional_build_setting?("WALI_MARKETPLACE_ENABLED", release_settings)
      error("Release WALI_MARKETPLACE_ENABLED must resolve to exactly NO without conditional overrides")
    end
  end

  def configuration_file_settings(configuration)
    @configuration_settings[configuration] ||= begin
      relative = @project.dig("configFiles", configuration)
      path = safe_relative_path(relative, "project.yml #{configuration} config file")
      path && File.file?(path) ? parse_xcconfig(path) : {}
    end
  end

  def parse_xcconfig(path, include_stack = [])
    cached = @xcconfig_settings[path]
    return cached.dup if cached

    if include_stack.include?(path)
      error("xcconfig include cycle: #{(include_stack + [path]).map { |item| File.basename(item) }.join(' -> ')}")
      return {}
    end

    settings = {}
    File.readlines(path, chomp: true).each do |line|
      if (include_match = line.match(/\A\s*#include(\?)?\s+"([^"]+)"\s*\z/))
        optional = !include_match[1].nil?
        included_path = File.expand_path(include_match[2], File.dirname(path))
        root_prefix = "#{@root}#{File::SEPARATOR}"
        unless included_path.start_with?(root_prefix)
          error("xcconfig include must stay within the repository: #{include_match[2]}")
          next
        end
        unless File.file?(included_path)
          error("xcconfig include does not exist: #{include_match[2]}") unless optional
          next
        end
        settings.merge!(parse_xcconfig(included_path, include_stack + [path]))
        next
      end

      assignment = line.sub(/\s+\/\/.*\z/, "").strip
      next if assignment.empty? || assignment.start_with?("#")

      match = assignment.match(/\A([A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]+\])*)\s*(\?=|\+=|=)\s*(.*?)\s*\z/)
      next unless match

      key = match[1]
      operator = match[2]
      value = match[3]
      case operator
      when "="
        settings[key] = value
      when "?="
        settings[key] = value unless settings.key?(key)
      when "+="
        settings[key] = [settings[key], value].compact.reject(&:empty?).join(" ")
      end
    end
    @xcconfig_settings[path] = settings.dup
    settings
  rescue Errno::ENOENT => exception
    error("could not read xcconfig #{path}: #{exception.message}")
    {}
  end

  def target_build_settings(target_name, configuration)
    cache_key = [target_name, configuration]
    @target_build_settings[cache_key] ||= begin
      settings = configuration_file_settings(configuration).dup
      merge_build_setting_scope(settings, @project["settings"], configuration)
      target = @project.dig("targets", target_name)
      merge_build_setting_scope(settings, target && target["settings"], configuration)
      settings
    end
  end

  def merge_build_setting_scope(destination, scope, configuration)
    return unless scope.is_a?(Hash)

    [scope["base"], scope.dig("configs", configuration)].each do |values|
      next unless values.is_a?(Hash)

      values.each do |key, value|
        destination[key] = value.is_a?(String) ? value : value.to_s
      end
    end
  end

  def resolved_target_build_setting(target_name, configuration, key)
    cache_key = [target_name, configuration, key]
    return @resolved_build_settings[cache_key] if @resolved_build_settings.key?(cache_key)

    settings = target_build_settings(target_name, configuration)
    raw = settings[key]
    @resolved_build_settings[cache_key] =
      raw.nil? ? nil : expand_build_setting(raw, settings, "#{target_name} #{configuration} #{key}", [key])
  end

  def conditional_build_setting?(key, settings, visited = Set.new)
    return false unless visited.add?(key)
    return true if settings.keys.any? { |candidate| candidate.start_with?("#{key}[") }

    settings[key].to_s.scan(/\$\(([^)]+)\)|\$\{([^}]+)\}/).any? do |parenthesized, braced|
      conditional_build_setting?(parenthesized || braced, settings, visited)
    end
  end

  def expand_build_setting(value, settings, label, stack)
    value.to_s.gsub(/\$\(([^)]+)\)|\$\{([^}]+)\}/) do |reference|
      variable = Regexp.last_match(1) || Regexp.last_match(2)
      if variable == "inherited"
        ""
      elsif stack.include?(variable)
        error("#{label} contains a build-setting reference cycle through #{variable}")
        reference
      elsif !settings.key?(variable)
        error("#{label} references undefined build setting #{variable}")
        reference
      else
        expand_build_setting(settings[variable], settings, label, stack + [variable])
      end
    end
  end

  def validate_required_embed_topology(targets, actual_edges)
    embed_edges = actual_edges.fetch("embed_only")
    unless embed_edges.include?(["WALIAgent", "WALITranscoder"])
      error("WALITranscoder embed owner must be WALIAgent")
    end
    if embed_edges.include?(["WALI", "WALITranscoder"])
      error("WALI must not embed WALITranscoder")
    end
    unless embed_edges == REQUIRED_EMBED_ONLY_EDGES
      error(
        "current embed-only topology must be " \
        "#{format_edges(REQUIRED_EMBED_ONLY_EDGES)}"
      )
    end

    validate_embed_copy(
      targets,
      "WALI",
      "WALIAgent",
      "Contents/Library/LoginItems"
    )
    validate_embed_copy(
      targets,
      "WALIAgent",
      "WALITranscoder",
      "Contents/XPCServices"
    )
  end

  def validate_embed_copy(targets, owner, embedded, subpath)
    dependencies = Array(targets.dig(owner, "dependencies")).select do |dependency|
      dependency.is_a?(Hash) && dependency["target"] == embedded
    end
    expected_copy = {"destination" => "wrapper", "subpath" => subpath}
    valid = dependencies.length == 1 &&
            dependencies.first["embed"] == true &&
            dependencies.first["link"] == false &&
            dependencies.first["codeSign"] == true &&
            dependencies.first["copy"] == expected_copy
    return if valid

    error("#{owner} must embed-only #{embedded} at #{subpath} with code signing")
  end

  def validate_identity_build_settings(targets)
    IDENTITY_BUILD_SETTINGS.each do |target_name, variable|
      target = targets[target_name]
      next unless target.is_a?(Hash)

      raw_identifier = target.dig("settings", "base", "PRODUCT_BUNDLE_IDENTIFIER")
      expected_reference = "$(#{variable})"
      unless raw_identifier == expected_reference
        error("#{target_name} PRODUCT_BUNDLE_IDENTIFIER must reference #{expected_reference}")
      end
      if target.dig("info", "properties").is_a?(Hash) &&
         target.dig("info", "properties").key?("CFBundleIdentifier")
        error("#{target_name} Info.plist must inherit PRODUCT_BUNDLE_IDENTIFIER")
      end
    end

    identity_variables = IDENTITY_BUILD_SETTINGS.values +
                         %w[WALI_APP_GROUP_IDENTIFIER WALI_AGENT_CONTROL_SERVICE_NAME WALI_LOCK_SCREEN_HELPER_SERVICE_NAME]
    CONFIGURATIONS.each do |configuration|
      config_settings = configuration_file_settings(configuration)
      identity_variables.each do |variable|
        unless config_settings.key?(variable)
          error("#{configuration} xcconfig is missing identity setting #{variable}")
        end
      end

      IDENTITY_BUILD_SETTINGS.each_key do |target_name|
        validate_runtime_build_policy(target_name, configuration)
      end
      validate_entitlement_build_policy(targets, configuration)
    end
  end

  # Every direct channel keeps its exact peer identities and selected launchd path.
  # These are security-relevant runtime inputs, not just Xcode bundle labels.
  def validate_direct_service_metadata(targets)
    info = {
      "WALI" => {
        "WALIControlServiceName" => "$(WALI_AGENT_CONTROL_SERVICE_NAME)",
        "WALIAgentLaunchAgentPlistName" => "$(WALI_AGENT_BUNDLE_IDENTIFIER).plist",
        "WALILockScreenHelperLaunchAgentPlistName" => "$(WALI_LOCK_SCREEN_HELPER_BUNDLE_IDENTIFIER).plist"
      },
      "WALIAgent" => {
        "WALIControlServiceName" => "$(WALI_AGENT_CONTROL_SERVICE_NAME)",
        "WALITranscoderServiceName" => "$(WALI_TRANSCODER_BUNDLE_IDENTIFIER)",
        "WALILockScreenHelperServiceName" => "$(WALI_LOCK_SCREEN_HELPER_SERVICE_NAME)",
        "WALILockScreenHelperBundleIdentifier" => "$(WALI_LOCK_SCREEN_HELPER_BUNDLE_IDENTIFIER)"
      },
      "WALITranscoder" => {
        "WALIExpectedClientBundleIdentifier" => "$(WALI_AGENT_BUNDLE_IDENTIFIER)"
      },
      "WALILockScreenHelper" => {
        "WALILockScreenHelperServiceName" => "$(WALI_LOCK_SCREEN_HELPER_SERVICE_NAME)",
        "WALIExpectedAgentBundleIdentifier" => "$(WALI_AGENT_BUNDLE_IDENTIFIER)"
      }
    }
    info.each do |target, properties|
      properties.each do |key, expected|
        error("#{target} #{key} must reference #{expected}") unless targets.dig(target, "info", "properties", key) == expected
      end
    end
    directory = repository_path("Config/LaunchAgents")
    expected_names = []
    CONFIGURATIONS.each do |configuration|
      %w[WALIAgent WALILockScreenHelper].each do |role|
        identifier = EXPECTED_BUNDLE_IDENTIFIERS.fetch(configuration).fetch(role)
        name = "#{identifier}.plist"
        expected_names << name
        path = File.join(directory, name)
        if File.symlink?(path) || !File.file?(path)
          error("#{configuration} #{role} launch plist must exist at Config/LaunchAgents/#{name}")
          next
        end
        output, _errors, status = Open3.capture3("/usr/bin/plutil", "-convert", "json", "-o", "-", path)
        begin
          plist = status.success? ? JSON.parse(output) : nil
        rescue JSON::ParserError
          plist = nil
        end
        expected = {
          "Label" => identifier,
          "BundleProgram" => "Contents/Library/LoginItems/#{role}.app/Contents/MacOS/#{role}",
          "MachServices" => {"#{identifier}.control" => true},
          "ProcessType" => "Interactive", "RunAtLoad" => true, "KeepAlive" => {"Crashed" => true}
        }
        error("#{configuration} #{role} launch plist must match exact identity, executable, service, and lifecycle policy") unless plist == expected
      end
    end
    actual_names = Dir.children(directory).sort if File.directory?(directory)
    error("direct launch plist inventory must contain exactly the six configured agent/helper identities") unless actual_names == expected_names.sort
  end

  def validate_runtime_build_policy(target_name, configuration)
    expected_hardened = configuration == "Debug" ? "NO" : "YES"
    hardened = resolved_target_build_setting(
      target_name,
      configuration,
      "ENABLE_HARDENED_RUNTIME"
    )
    unless hardened == expected_hardened
      error("#{target_name} #{configuration} ENABLE_HARDENED_RUNTIME must be #{expected_hardened}")
    end

    marketing = resolved_target_build_setting(target_name, configuration, "MARKETING_VERSION")
    build = resolved_target_build_setting(target_name, configuration, "CURRENT_PROJECT_VERSION")
    error("#{target_name} #{configuration} MARKETING_VERSION must be 0.1.0") unless marketing == "0.1.0"
    error("#{target_name} #{configuration} CURRENT_PROJECT_VERSION must be 1") unless build == "1"

    return unless configuration == "Development"

    style = resolved_target_build_setting(target_name, configuration, "CODE_SIGN_STYLE")
    identity = resolved_target_build_setting(target_name, configuration, "CODE_SIGN_IDENTITY")
    error("#{target_name} Development CODE_SIGN_STYLE must be Automatic") unless style == "Automatic"
    unless identity == "Apple Development"
      error("#{target_name} Development CODE_SIGN_IDENTITY must be Apple Development")
    end
  end

  def validate_entitlement_build_policy(targets, configuration)
    %w[WALI WALIAgent WALILockScreenHelper].each do |target_name|
      settings = target_build_settings(target_name, configuration)
      entitlements = settings["CODE_SIGN_ENTITLEMENTS"]
      if configuration == "Debug"
        if nonempty_string?(entitlements) || conditional_build_setting?("CODE_SIGN_ENTITLEMENTS", settings)
          error("#{target_name} Debug must not use entitlements")
        end
        next
      end

      expected_path = if target_name == "WALI" && configuration == "Release"
        "Config/WALI-Release.entitlements"
      else
        "Config/#{target_name}.entitlements"
      end
      if entitlements != expected_path || conditional_build_setting?("CODE_SIGN_ENTITLEMENTS", settings)
        error("#{target_name} #{configuration} must use #{expected_path}")
        next
      end
      validate_foreground_entitlement_contents(entitlements, configuration) if target_name == "WALI"
      raw_groups = entitlement_application_groups(entitlements, target_name, configuration, resolve: false)
      unless raw_groups == ["$(WALI_APP_GROUP_IDENTIFIER)"]
        error("#{target_name} entitlements must reference $(WALI_APP_GROUP_IDENTIFIER)")
      end
    end

    CONFIGURATIONS.each do |candidate|
      settings = target_build_settings("WALITranscoder", candidate)
      entitlements = settings["CODE_SIGN_ENTITLEMENTS"]
      if nonempty_string?(entitlements) || conditional_build_setting?("CODE_SIGN_ENTITLEMENTS", settings)
        error("WALITranscoder #{candidate} must not use application-group entitlements")
      end
    end
  end

  def validate_foreground_entitlement_contents(relative, configuration)
    expected = {"com.apple.security.application-groups" => ["$(WALI_APP_GROUP_IDENTIFIER)"]}
    if configuration == "Development"
      expected["com.apple.developer.applesignin"] = ["Default"]
    end
    label = "WALI #{configuration} entitlements must contain exactly the approved application group"
    label += " and native Sign in with Apple" if configuration == "Development"
    path = safe_relative_path(relative, "WALI #{configuration} entitlements")
    unless path && File.file?(path)
      error(label)
      return
    end

    document = REXML::Document.new(File.read(path))
    dictionary = REXML::XPath.first(document, "/plist/dict")
    entries = dictionary && dictionary.elements.to_a
    actual = {}
    valid = entries && entries.length.even? && document.root.elements.to_a == [dictionary]
    if valid
      entries.each_slice(2) do |key, value|
        unless key.name == "key" && key.elements.to_a.empty? && !actual.key?(key.text) &&
            value.name == "array" && value.elements.to_a.all? { |item| item.name == "string" && item.elements.to_a.empty? }
          valid = false
          break
        end
        actual[key.text] = value.elements.to_a.map { |item| item.text.to_s }
      end
    end
    error(label) unless valid && actual == expected
  rescue REXML::ParseException
    error(label)
  end

  def validate_project_package_references
    project_packages = @project["packages"]
    unless project_packages.is_a?(Hash)
      error("project.yml packages must be a mapping")
      return
    end
    internal_references = @swift_packages.keys
    external_references = APPROVED_EXTERNAL_PACKAGES.keys
    (project_packages.keys - internal_references - external_references).sort.each do |reference|
      error("project.yml contains undeclared XcodeGen package reference #{reference}")
    end
    (internal_references - project_packages.keys).sort.each do |reference|
      error("project.yml is missing XcodeGen package reference #{reference}")
    end
    (internal_references & project_packages.keys).each do |reference|
      declared_path = @swift_packages.dig(reference, "xcodegen_reference", "path")
      actual_path = project_packages.dig(reference, "path")
      error("#{reference} XcodeGen package path does not match project.yml") unless declared_path == actual_path
    end
    APPROVED_EXTERNAL_PACKAGES.each do |reference, expected|
      actual = project_packages[reference]
      unless actual == expected
        error("#{reference} external package must use its reviewed URL and exact version")
      end
    end
  end

  def validate_project_package(id, definition, current_target)
    packages = @project["packages"]
    reference_id = current_target["package_reference"]
    package = packages.is_a?(Hash) ? packages[reference_id] : nil
    unless package.is_a?(Hash) && nonempty_string?(package["path"])
      error("#{id} current package is missing from project.yml")
      return
    end
    declared_path = @swift_packages.dig(reference_id, "xcodegen_reference", "path")
    error("#{reference_id} XcodeGen package path does not match project.yml") unless package["path"] == declared_path
    package_target_path = @swift_packages.dig(reference_id, "current", "targets", current_target["target"], "path")
    expected_source = package_target_path && File.join(package["path"], package_target_path)
    unless definition["source_path"] == expected_source
      error("#{id} source_path does not match project.yml package path")
    end
  end

  def project_edges(targets)
    result = EDGE_KINDS.to_h { |kind| [kind, Set.new] }
    target_to_module = {}
    package_product_to_module = {}
    @modules.each do |id, definition|
      target = definition.is_a?(Hash) ? definition["current_target"] : nil
      next unless definition.is_a?(Hash) && definition["presence"] == "current"
      next unless target.is_a?(Hash)
      if target["build_system"] == "xcode"
        target_to_module[target["name"]] = id
      elsif target["build_system"] == "swift_package"
        package_product_to_module[[target["package_reference"], target["product"]]] = id
      end
    end

    target_to_module.each do |target_name, module_id|
      target = targets[target_name]
      next unless target.is_a?(Hash)

      Array(target["dependencies"]).each do |dependency|
        next unless dependency.is_a?(Hash)

        if dependency["package"]
          reference = dependency["package"]
          product = dependency["product"] || reference
          destination = package_product_to_module[[reference, product]]
          unless destination
            next if APPROVED_EXTERNAL_PACKAGES.key?(reference)

            error("#{module_id} project.yml dependency references unregistered package #{dependency['package']}")
            next
          end
          result["package"] << [module_id, destination]
        elsif dependency["target"]
          destination = target_to_module[dependency["target"]]
          unless destination
            error("#{module_id} project.yml dependency references unregistered target #{dependency['target']}")
            next
          end

          kind = dependency["embed"] == true && dependency["link"] == false ? "embed_only" : "build"
          result[kind] << [module_id, destination]
        end
      end
    end
    result
  end

  def manifest_edge_set(phase, kind)
    values = @modules_document_edges ||= {}
    values[[phase, kind]] ||= begin
      document = load_manifest_without_reparse
      edges = document.dig("edges", phase, kind)
      Set.new(Array(edges).select { |edge| edge.is_a?(Hash) }.map { |edge| [edge["from"], edge["to"]] })
    end
  end

  def load_manifest_without_reparse
    @loaded_modules_document
  end

  def validate_imports
    internal_modules = @modules.keys.to_set
    @modules.each do |id, definition|
      next unless definition.is_a?(Hash) && definition["presence"] == "current"

      source_path = definition["source_path"]
      full_path = safe_relative_path(source_path, "#{id} source_path")
      next unless full_path && Dir.exist?(full_path)

      allowed = Set.new(Array(definition["current_allowed_internal_imports"]))
      allowed_reexports = Set.new(Array(definition["current_allowed_internal_reexports"]))
      forbidden = Set.new(Array(definition["forbidden_frameworks"]))
      reported = Set.new
      observed_internal = Set.new
      observed_reexports = Set.new
      Dir.glob(File.join(full_path, "**", "*.swift")).sort.each do |swift_file|
        stdout, stderr, status = Open3.capture3(
          "xcrun", "swiftc", "-frontend", "-dump-parse", swift_file
        )
        unless status.success?
          detail = stderr.lines.find { |line| !line.strip.empty? }.to_s.strip
          relative = Pathname.new(swift_file).relative_path_from(Pathname.new(@root))
          error("Swift parser failed for #{relative}: #{detail}")
          next
        end
        stdout.each_line do |parse_line|
          next unless parse_line.include?("(import_decl")

          module_match = parse_line.match(/\bmodule="([^"]+)"/)
          next unless module_match

          parsed_import = module_match[1]
          imported = parsed_import.split(".", 2).first
          exported = parse_line.match?(/\bexported\b/)
          diagnostic_suffix =
            parsed_import == imported ? "" : " (parsed import #{parsed_import})"
          if internal_modules.include?(imported)
            observed_internal << imported
            if exported
              observed_reexports << imported
              unless allowed_reexports.include?(imported)
                key = ["reexport", parsed_import]
                unless reported.include?(key)
                  error("#{id} re-exports internal module #{imported} without permission#{diagnostic_suffix}")
                  reported << key
                end
              end
            end
            unless allowed.include?(imported)
              key = ["internal", parsed_import]
              unless reported.include?(key)
                error("#{id} imports unauthorized internal module #{imported}#{diagnostic_suffix}")
                reported << key
              end
            end
          elsif forbidden.include?(imported)
            key = ["framework", parsed_import]
            unless reported.include?(key)
              error("#{id} imports forbidden framework #{imported}#{diagnostic_suffix}")
              reported << key
            end
          end
        end
      end
      unless observed_internal == allowed
        error(
          "#{id} current internal imports do not match manifest " \
          "(declared: #{allowed.to_a.sort.join(', ')}; " \
          "actual: #{observed_internal.to_a.sort.join(', ')})"
        )
      end
      unknown_reexports = observed_reexports - allowed_reexports
      unless unknown_reexports.empty?
        error(
          "#{id} current internal re-exports exceed manifest allowlist " \
          "(allowed: #{allowed_reexports.to_a.sort.join(', ')}; " \
          "actual: #{observed_reexports.to_a.sort.join(', ')})"
        )
      end
    end
  rescue Errno::ENOENT => exception
    error("Swift parser is unavailable: #{exception.message}")
  end

  def validate_surfaces(document)
    error("surfaces.yml schema_version must be 3") unless document["schema_version"] == 3
    validate_schema_document(document, "docs/compatibility/surfaces-schema.md", "surfaces.yml")

    surfaces = document["surfaces"]
    unless surfaces.is_a?(Array)
      error("surfaces.yml surfaces must be an array")
      return
    end

    seen = Set.new
    surfaces.each do |surface|
      unless surface.is_a?(Hash)
        error("compatibility surface must be a mapping")
        next
      end
      id = surface["id"]
      if seen.include?(id)
        error("duplicate compatibility surface id #{id}")
      else
        seen << id
      end
      validate_surface(id, surface)
    end
    REQUIRED_SURFACES.each_key do |id|
      error("missing required compatibility surface #{id}") unless seen.include?(id)
    end
  end

  def validate_surface(id, surface)
    require_exact_fields(surface, SURFACE_FIELDS, "surface #{id || '<missing>'}")
    return unless nonempty_string?(id)

    expected_kind = REQUIRED_SURFACES[id]
    error("surface #{id} has unknown kind #{surface['kind']}") unless expected_kind && surface["kind"] == expected_kind
    owner = surface["owner_role"]
    error("surface #{id} uses unknown owner_role #{owner}") unless ROLE_IDS.include?(owner)
    implementation = surface["implementation"]
    error("surface #{id} implementation is invalid") unless IMPLEMENTATION_VALUES.include?(implementation)

    validate_surface_versions(id, implementation, surface["version"], surface["product_compatibility"])
    validate_surface_modules(id, surface["module_access"])
    validate_fixture_gate(id, implementation, surface["fixture_gate"])
    validate_surface_details(id, implementation, surface["details"])
    validate_model_record_fixture_alignment(surface) if id == "model_records"
    validate_lock_screen_fixture_alignment(surface) if id == "lock_screen_manifest"
  end

  def validate_surface_versions(id, implementation, version, compatibility)
    unless version.is_a?(Hash)
      error("surface #{id} version must be a mapping")
      return
    end
    unless compatibility.is_a?(Hash)
      error("surface #{id} product_compatibility must be a mapping")
      return
    end
    require_exact_fields(
      version,
      %w[current readable_epochs additive_compatibility],
      "surface #{id} version"
    )
    require_exact_fields(
      compatibility,
      %w[minimum_reader minimum_writer rollback_readers rollback_fixture_paths],
      "surface #{id} product_compatibility"
    )

    if implementation != "implemented"
      null_version = version["current"].nil? &&
                     version["readable_epochs"] == [] &&
                     version["additive_compatibility"].nil?
      null_product = compatibility["minimum_reader"].nil? &&
                     compatibility["minimum_writer"].nil? &&
                     compatibility["rollback_readers"] == [] &&
                     compatibility["rollback_fixture_paths"] == []
      unless null_version && null_product
        error("unimplemented surface #{id} must use null version and product compatibility fields")
      end
      return
    end

    current = version_pair(version["current"], "implemented surface #{id} current")
    unless version["additive_compatibility"] == "declared_ranges_only"
      error("implemented surface #{id} additive_compatibility must be declared_ranges_only")
    end
    validate_readable_epochs(id, version["readable_epochs"], current)

    %w[minimum_reader minimum_writer].each do |field|
      value = compatibility[field]
      error("implemented surface #{id} #{field} must be a product version") unless product_version?(value)
    end
    rollback_readers = string_array(
      compatibility["rollback_readers"],
      "surface #{id} rollback_readers"
    )
    rollback_paths = string_array(
      compatibility["rollback_fixture_paths"],
      "surface #{id} rollback_fixture_paths"
    )
    rollback_readers.each do |product|
      error("surface #{id} rollback reader must be a product version: #{product}") unless product_version?(product)
    end
    if rollback_readers.any? && rollback_paths.empty?
      error("surface #{id} promises rollback without old-binary fixture paths")
    elsif rollback_readers.empty? && rollback_paths.any?
      error("surface #{id} has rollback fixture paths without a rollback promise")
    end
    rollback_paths.each { |path| validate_existing_fixture_path(id, path) }
  end

  def validate_target_epoch(value, id)
    unless value == {"epoch" => 1, "revision" => 0}
      error("#{id} target must be epoch 1 revision 0")
    end
  end

  def validate_readable_epochs(id, ranges, current)
    unless ranges.is_a?(Array) && !ranges.empty?
      error("implemented surface #{id} readable_epochs must be a non-empty array")
      return
    end
    seen_epochs = Set.new
    contains_current = false
    ranges.each do |range|
      unless range.is_a?(Hash)
        error("#{id} readable epoch entry must be a mapping")
        next
      end
      require_exact_fields(
        range,
        %w[epoch minimum_revision maximum_revision],
        "#{id} readable epoch"
      )
      epoch = range["epoch"]
      minimum = range["minimum_revision"]
      maximum = range["maximum_revision"]
      if !epoch.is_a?(Integer) || epoch <= 0 ||
         !minimum.is_a?(Integer) || minimum < 0 ||
         !maximum.is_a?(Integer) || maximum < minimum
        error("#{id} readable epoch #{epoch} has invalid revision range")
        next
      end
      error("#{id} readable epoch #{epoch} is duplicated") if seen_epochs.include?(epoch)
      seen_epochs << epoch
      if current && current[0] == epoch && minimum <= current[1] && current[1] <= maximum
        contains_current = true
      end
    end
    error("#{id} readable epochs do not contain current version") if current && !contains_current
  end

  def version_pair(value, label)
    unless value.is_a?(Hash) &&
           value.keys.sort == %w[epoch revision] &&
           value["epoch"].is_a?(Integer) && value["epoch"].positive? &&
           value["revision"].is_a?(Integer) && value["revision"] >= 0
      error("#{label} must contain positive epoch and nonnegative revision")
      return nil
    end
    [value["epoch"], value["revision"]]
  end

  def validate_surface_modules(id, access)
    unless access.is_a?(Hash)
      error("surface #{id} module_access must be a mapping")
      return
    end
    require_fields(access, %w[readers writers], "surface #{id} module_access")
    %w[readers writers].each do |field|
      string_array(access[field], "surface #{id} #{field}").each do |module_id|
        error("surface #{id} references unknown module #{module_id}") unless @modules.key?(module_id)
      end
    end
  end

  def validate_fixture_gate(id, implementation, gate)
    unless gate.is_a?(Hash)
      error("surface #{id} fixture_gate must be a mapping")
      return
    end
    require_fields(gate, %w[status paths], "surface #{id} fixture_gate")
    paths = string_array(gate["paths"], "surface #{id} fixture paths")
    expected_status = {
      "unimplemented" => "planned",
      "configured" => "not_applicable",
      "implemented" => "passing",
      "deferred" => "deferred"
    }[implementation]
    if expected_status && gate["status"] != expected_status
      error("surface #{id} fixture_gate status must be #{expected_status}")
    end
    if implementation == "implemented"
      error("implemented surface #{id} must declare fixture paths") if paths.empty?
      paths.each { |path| validate_existing_fixture_path(id, path) }
    elsif paths.any?
      error("unimplemented surface #{id} must not claim fixture paths")
    end
  end

  def validate_existing_fixture_path(id, relative)
    path = safe_relative_path(relative, "surface #{id} fixture path")
    error("surface #{id} fixture path does not exist: #{relative}") if path && !File.exist?(path)
  end

  def validate_model_record_fixture_alignment(surface)
    gate = surface["fixture_gate"]
    details = surface["details"]
    return unless gate.is_a?(Hash) && details.is_a?(Hash)

    gate_paths = string_array(gate["paths"], "model_records fixture paths")
    golden_paths = string_array(
      details["golden_fixture_paths"],
      "model_records golden_fixture_paths"
    )
    invalid_paths = string_array(
      details["invalid_fixture_paths"],
      "model_records invalid_fixture_paths"
    )
    unless gate_paths.sort == (golden_paths + invalid_paths).sort
      error("model_records fixture gate must equal its golden and invalid fixture paths")
    end
  end

  def validate_lock_screen_fixture_alignment(surface)
    gate = surface["fixture_gate"]
    return unless gate.is_a?(Hash)

    paths = string_array(gate["paths"], "lock_screen_manifest fixture paths")
    expected = ["Fixtures/LockScreen/modern-aerial-v1.json"]
    unless paths == expected
      error("lock_screen_manifest must use the redacted modern Aerial v1 fixture")
      return
    end
    path = safe_relative_path(paths.first, "lock_screen_manifest fixture path")
    return unless path && File.file?(path)

    begin
      fixture = JSON.parse(File.read(path))
    rescue JSON::ParserError
      error("lock_screen_manifest fixture must be valid JSON")
      return
    end
    expected_values = {
      ["epoch"] => 1,
      ["revision"] => 1,
      ["verified_system_build"] => "25F80",
      ["manifest", "version"] => 1,
      ["wallpaper_index", "provider"] => "com.apple.wallpaper.choice.aerials"
    }
    expected_values.each do |keys, expected_value|
      actual = keys.reduce(fixture) { |value, key| value.is_a?(Hash) ? value[key] : nil }
      error("lock_screen_manifest fixture #{keys.join('.')} is invalid") unless actual == expected_value
    end
    category = fixture.dig("manifest", "categories")&.first
    subcategory = category.is_a?(Hash) ? category["subcategories"]&.first : nil
    asset = fixture.dig("manifest", "assets")&.first
    asset_id = "11111111-2222-4333-8444-555555555555"
    unless category.is_a?(Hash) &&
           category["id"] == "57414C49-0000-4000-8000-000000000001" &&
           category["representativeAssetID"] == asset_id &&
           category["previewImage"].to_s.start_with?("file:///REDACTED/") &&
           subcategory.is_a?(Hash) &&
           subcategory["id"] == "57414C49-0000-4000-8000-000000000002" &&
           subcategory["representativeAssetID"] == asset_id &&
           subcategory["previewImage"].to_s.start_with?("file:///REDACTED/")
      error("lock_screen_manifest fixture ownership category structure is invalid")
    end
    required_asset_fields = %w[
      id shotID categories subcategories localizedNameKey accessibilityLabel
      showInTopLevel includeInShuffle preferredOrder pointsOfInterest
      url-4K-SDR-240FPS previewImage
    ]
    unless asset.is_a?(Hash) && (required_asset_fields - asset.keys).empty? &&
           asset["id"] == asset_id &&
           asset["categories"] == ["57414C49-0000-4000-8000-000000000001"] &&
           asset["subcategories"] == ["57414C49-0000-4000-8000-000000000002"] &&
           asset["shotID"] == "CUSTOM_WALI_11111111_2222_4333_8444_555555555555" &&
           asset["url-4K-SDR-240FPS"].to_s.start_with?("file:///REDACTED/") &&
           asset["previewImage"].to_s.start_with?("file:///REDACTED/")
      error("lock_screen_manifest fixture asset structure is invalid")
    end
    expected_managed = [
      "AllSpacesAndDisplays",
      "SystemDefault",
      "Displays",
      "Spaces"
    ]
    expected_choice = {
      "Configuration" => {"assetID" => asset_id},
      "Files" => [],
      "Provider" => "com.apple.wallpaper.choice.aerials"
    }
    global_node = fixture.dig("wallpaper_index", "global_linked_node")
    global_content = global_node&.dig("Linked", "Content")
    unless fixture.dig("wallpaper_index", "selection_policy") == "main_display_single_asset" &&
           fixture.dig("wallpaper_index", "managed_root_values") == expected_managed &&
           fixture.dig("wallpaper_index", "mutable_node_patterns") == expected_managed &&
           fixture.dig("wallpaper_index", "configuration", "assetID") == asset_id &&
           fixture.dig("wallpaper_index", "configuration_encoding") == "binary-plist-data" &&
           global_node&.fetch("Type", nil) == "linked" &&
           global_content&.fetch("Choices", nil) == [expected_choice] &&
           global_content&.fetch("EncodedOptionValues", nil) == "REDACTED_BINARY_PLIST_DATA" &&
           global_content&.fetch("Shuffle", nil) == "$null" &&
           global_node&.dig("Linked", "LastSet") == "REDACTED_DATE" &&
           global_node&.dig("Linked", "LastUse") == "REDACTED_DATE" &&
           fixture.dig("wallpaper_index", "active_override_maps") == {
             "Displays" => {}, "Spaces" => {}
           } &&
           fixture.dig("wallpaper_index", "preserved_global_fields") == [
             "Linked/Content/EncodedOptionValues", "Linked/Content/Shuffle"
           ] &&
           fixture.dig("wallpaper_index", "daemon_timestamp_drift_fields") == [
             "Linked/LastSet", "Linked/LastUse"
           ] &&
           fixture.dig("wallpaper_index", "rollback_policy") == "restore_exact_four_root_preimage"
      error("lock_screen_manifest fixture node scope is invalid")
    end
    serialized = File.read(path)
    file_urls = serialized.scan(%r{file://[^"\s]+})
    if serialized.include?("/Users/") || serialized.match?(/Backdrop/i) ||
       file_urls.any? { |url| !url.start_with?("file:///REDACTED/") }
      error("lock_screen_manifest fixture must remain redacted and product-neutral")
    end
  end

  def validate_surface_details(id, implementation, details)
    unless details.is_a?(Hash)
      error("surface #{id} details must be a mapping")
      return
    end
    case id
    when "sqlite_schema"
      require_exact_fields(
        details,
        %w[runtime_owner database_openers migration_policy],
        "#{id} details"
      )
      error("sqlite_schema runtime_owner must be WALIAgent") unless details["runtime_owner"] == "WALIAgent"
      validate_exact_string_set(details["database_openers"], ["WALIAgent"], "sqlite_schema database_openers")
      policy = details["migration_policy"]
      if policy.is_a?(Hash)
        require_exact_fields(policy, %w[fixture_requirement unknown_newer stepwise], "sqlite_schema migration_policy")
        error("sqlite_schema migration fixture policy is invalid") unless policy["fixture_requirement"] == "every_supported_epoch_revision"
        error("sqlite_schema unknown-newer policy is invalid") unless policy["unknown_newer"] == "reject_before_write"
        error("sqlite_schema migration must be stepwise") unless policy["stepwise"] == true
      else
        error("sqlite_schema migration_policy must be a mapping")
      end
    when "artifact_manifest"
      require_exact_fields(
        details,
        %w[trust_authority checksum_algorithm schema_policy worker_claims],
        "#{id} details"
      )
      error("artifact_manifest trust_authority must be WALIAgent") unless details["trust_authority"] == "WALIAgent"
      error("artifact_manifest checksum_algorithm must be SHA-256") unless details["checksum_algorithm"] == "SHA-256"
      error("artifact_manifest schema_policy is invalid") unless details["schema_policy"] == "immutable_versioned_manifest"
      error("artifact_manifest worker_claims must be untrusted") unless details["worker_claims"] == "untrusted"
    when "model_records"
      require_exact_fields(
        details,
        %w[
          schema coding_semantics canonical_bytes record_roots
          golden_fixture_paths invalid_fixture_paths
        ],
        "#{id} details"
      )
      error("model_records schema must be epoch 1 revision 0") unless details["schema"] == {
        "epoch" => 1,
        "revision" => 0
      }
      unless details["coding_semantics"] == "logical_record_shape"
        error("model_records coding semantics must be logical_record_shape")
      end
      error("model_records must not claim canonical bytes") unless details["canonical_bytes"] == false
      validate_exact_string_set(
        details["record_roots"],
        %w[
          artifact asset_release library_item display_record
          device_local_presentation_assignment playback_state durable_job import_job
        ],
        "model_records record_roots"
      )
      golden = string_array(
        details["golden_fixture_paths"],
        "model_records golden_fixture_paths"
      )
      invalid = string_array(
        details["invalid_fixture_paths"],
        "model_records invalid_fixture_paths"
      )
      if golden.empty? || invalid.empty?
        error("model_records must declare golden and invalid fixture paths")
      end
      (golden + invalid).each { |path| validate_existing_fixture_path(id, path) }
    when "app_agent_wire", "agent_worker_wire"
      validate_wire_details(id, implementation, details)
    when "lock_screen_helper_wire"
      require_exact_fields(
        details,
        %w[direction message_catalog rejected_payload_classes],
        "#{id} details"
      )
      validate_wire_details(
        id,
        implementation,
        {
          "direction" => details["direction"],
          "message_catalog" => details["message_catalog"]
        }
      )
      validate_exact_string_set(
        details["rejected_payload_classes"],
        %w[url path bookmark media_bytes command script unknown_operation],
        "#{id} rejected_payload_classes"
      )
    when "store_wire_contracts"
      expected = {
        "policy_adr" => "docs/adr/0018-sandboxed-mac-app-store-distribution.md", "module" => "WALIWire",
        "source_path" => "Packages/WALICore/Sources/WALIWire/StoreProtocol.swift", "direct_wire_unchanged" => true,
        "shared_envelope_maximum_bytes" => 4_194_304,
        "import_grant" => {"message_version" => 1, "maximum_bookmark_bytes" => 262_144, "maximum_encoded_bytes" => 368_640, "persistence" => "transient_only"},
        "worker_request" => {"message_version" => 2, "maximum_source_bookmark_bytes" => 262_144, "maximum_staging_bookmark_bytes" => 262_144, "staging_scope" => "exact_job_uuid_and_generation_directory"},
        "worker_handshake" => {"protocol_version" => 2, "message_version" => 2, "maximum_encoded_bytes" => 4096, "correlation" => "exact_nonce_echo_before_any_grants", "added_selectors" => ["negotiate:withReply:", "shutdownWithReply:"]},
        "presentation_demand" => {"command" => "preparePresentation", "envelope_message_version" => 1, "maximum_unique_item_ids" => 32, "caller_paths" => "forbidden", "authority" => "committed_agent_snapshot"},
        "lifecycle_callback" => {"message_version" => 1, "selector" => "agentWillTerminateWithReply:", "payload" => "none"},
        "regression_paths" => ["Packages/WALICore/Tests/WALIWireTests/StoreWireTests.swift", "Tests/WALIAgentTests/StoreScopedStorageTests.swift", "Tests/WALITranscoderTests/WorkerGrantTests.swift"],
        "remaining_gate" => "signed_cross_process_scope_and_recovery_journeys"
      }
      error("Store wire contract registry differs from accepted bounded contract") unless details == expected
    when "store_distribution"
      require_exact_fields(details, %w[policy_adr cross_distribution_migration signing_gate configurations], "#{id} details")
      error("Store distribution ADR must be 0018") unless details["policy_adr"] == "docs/adr/0018-sandboxed-mac-app-store-distribution.md"
      error("Store cross-distribution migration must be none") unless details["cross_distribution_migration"] == "none"
      error("Store signed feasibility remains required") unless details["signing_gate"] == "signed_sandbox_feasibility_pending"
      expected = StoreGraphChecker::CONFIGS.transform_values do |part|
        {"WALI" => "com.wali.#{part}.WALI", "WALIAgent" => "com.wali.#{part}.WALIAgent", "WALITranscoder" => "com.wali.#{part}.WALITranscoder", "application_group" => "group.com.wali.#{part}.shared", "app_agent_service" => "group.com.wali.#{part}.shared.agent-control"}
      end
      error("Store distribution identity registry mismatch") unless details["configurations"] == expected
    when "bundle_identifiers"
      require_exact_fields(details, %w[configurations], "#{id} details")
      validate_bundle_configurations(id, details["configurations"])
    when "application_group_containers"
      require_exact_fields(details, %w[entitlement_key configurations], "#{id} details")
      error("application group entitlement key is invalid") unless details["entitlement_key"] == "com.apple.security.application-groups"
      validate_container_configurations(id, details["configurations"])
    when "app_agent_service_names", "agent_worker_service_names", "agent_lock_screen_helper_service_names"
      require_exact_fields(details, %w[decision_gate configurations], "#{id} details")
      error("#{id} decision_gate must be a non-empty string") unless nonempty_string?(details["decision_gate"])
      validate_service_configurations(id, implementation, details["configurations"])
    when "content_store"
      require_exact_fields(
        details,
        %w[current_layout target_layout digest_algorithm publication_scope publication_primitive],
        "#{id} details"
      )
      error("content_store target_layout must be a non-empty string") unless nonempty_string?(details["target_layout"])
      error("content_store digest_algorithm must be SHA-256") unless details["digest_algorithm"] == "SHA-256"
      error("content_store publication_scope must be same_volume_only") unless details["publication_scope"] == "same_volume_only"
      error("content_store publication_primitive must be no_replace") unless details["publication_primitive"] == "no_replace"
      if implementation != "implemented" && !details["current_layout"].nil?
        error("unimplemented content_store current_layout must be null")
      end
    when "preferences"
      require_exact_fields(
        details,
        %w[authority storage_status current_keys unknown_newer_policy],
        "#{id} details"
      )
      error("preferences authority must be WALIAgent") unless details["authority"] == "WALIAgent"
      error("preferences storage_status must match implementation") unless details["storage_status"] == implementation
      string_array(details["current_keys"], "preferences current_keys")
      error("preferences unknown_newer_policy is invalid") unless details["unknown_newer_policy"] == "reject_before_mutation"
    when "url_schemes"
      require_exact_fields(details, %w[configurations mutation_policy], "#{id} details")
      validate_configuration_keys(id, details["configurations"])
      if details["configurations"].is_a?(Hash)
        CONFIGURATIONS.each { |configuration| string_array(details["configurations"][configuration], "#{id} #{configuration} schemes") }
      end
      error("url_schemes mutation_policy is invalid") unless details["mutation_policy"] == "validate_and_confirm"
    when "catalog_manifest"
      require_exact_fields(
        details,
        %w[
          trust_model signature_required signature_algorithm digest_algorithm
          canonicalization maximum_body_bytes maximum_nesting minimum_artifacts
          maximum_artifacts required_artifact_roles approved_host_policy
          network_status schema_policy contract
        ],
        "#{id} details"
      )
      error("catalog_manifest trust model is invalid") unless details["trust_model"] == "signed_manifest_required"
      error("catalog_manifest must require signatures") unless details["signature_required"] == true
      error("catalog_manifest signature algorithm is invalid") unless details["signature_algorithm"] == "Ed25519"
      error("catalog_manifest digest algorithm is invalid") unless details["digest_algorithm"] == "SHA-256"
      unless details["canonicalization"] == "schema_ordered_compact_utf8"
        error("catalog_manifest canonicalization is invalid")
      end
      error("catalog_manifest body bound is invalid") unless details["maximum_body_bytes"] == 65_536
      error("catalog_manifest nesting bound is invalid") unless details["maximum_nesting"] == 4
      error("catalog_manifest minimum artifact bound is invalid") unless details["minimum_artifacts"] == 4
      error("catalog_manifest maximum artifact bound is invalid") unless details["maximum_artifacts"] == 7
      validate_exact_string_set(
        details["required_artifact_roles"],
        %w[thumbnail poster preview video_default],
        "catalog_manifest required artifact roles"
      )
      unless details["approved_host_policy"] == "injected_exact_allowlist_no_redirects"
        error("catalog_manifest approved host policy is invalid")
      end
      unless details["network_status"] == "foreground_adapter_only"
        error("catalog_manifest network status is invalid")
      end
      unless details["schema_policy"] == "reject_unknown_epoch_and_undeclared_revision"
        error("catalog_manifest schema policy is invalid")
      end
      unless details["contract"] == "docs/api/catalog-v1.md"
        error("catalog_manifest contract path is invalid")
      end
    when "catalog_revocations"
      require_exact_fields(
        details,
        %w[
          trust_model digest_algorithm maximum_body_bytes maximum_entries
          ordering allowed_reasons scope contract
        ],
        "#{id} details"
      )
      error("catalog_revocations trust model is invalid") unless details["trust_model"] == "detached_ed25519_from_trusted_key"
      error("catalog_revocations digest is invalid") unless details["digest_algorithm"] == "SHA-256"
      error("catalog_revocations body bound is invalid") unless details["maximum_body_bytes"] == 1_048_576
      error("catalog_revocations entry bound is invalid") unless details["maximum_entries"] == 4_096
      error("catalog_revocations ordering is invalid") unless details["ordering"] == "release_id_then_artifact_sha256"
      validate_exact_string_set(
        details["allowed_reasons"],
        %w[critical_security corrupt_artifact signing_compromise],
        "catalog_revocations reasons"
      )
      error("catalog_revocations scope is invalid") unless details["scope"] == "catalog_origin_only"
      error("catalog_revocations contract is invalid") unless details["contract"] == "docs/api/catalog-v1.md"
    when "marketplace_server_schema"
      require_exact_fields(
        details,
        %w[
          target authoritative_schema exposed_schema exposed_table_policy
          migration_policy unknown_newer_policy contract
        ],
        "#{id} details"
      )
      validate_target_epoch(details["target"], id)
      error("#{id} authoritative schema is invalid") unless details["authoritative_schema"] == "wali"
      error("#{id} exposed schema is invalid") unless details["exposed_schema"] == "public"
      error("#{id} exposed table policy is invalid") unless details["exposed_table_policy"] == "none"
      unless details["migration_policy"] == "ordered_local_then_staging_then_production"
        error("#{id} migration policy is invalid")
      end
      error("#{id} unknown-newer policy is invalid") unless details["unknown_newer_policy"] == "reject_before_write"
      error("#{id} contract is invalid") unless details["contract"] == "docs/adr/0014-marketplace-schema-and-rls.md"
    when "catalog_public_api", "creator_public_api", "moderation_public_api"
      require_exact_fields(
        details,
        %w[
          target_version contract maximum_request_bytes maximum_response_bytes
          maximum_page_items exposed_table_policy
        ],
        "#{id} details"
      )
      expected_version = {
        "catalog_public_api" => "catalog.v1",
        "creator_public_api" => "creator.v1",
        "moderation_public_api" => "moderation.v1"
      }.fetch(id)
      expected_contract = {
        "catalog_public_api" => "docs/api/catalog-v1.md",
        "creator_public_api" => "docs/api/creator-v1.md",
        "moderation_public_api" => "docs/api/moderation-v1.md"
      }.fetch(id)
      error("#{id} target version is invalid") unless details["target_version"] == expected_version
      error("#{id} contract path is invalid") unless details["contract"] == expected_contract
      error("#{id} request bound is invalid") unless details["maximum_request_bytes"] == 65_536
      error("#{id} response bound is invalid") unless details["maximum_response_bytes"] == 1_048_576
      error("#{id} page bound is invalid") unless details["maximum_page_items"] == 50
      error("#{id} exposed table policy is invalid") unless details["exposed_table_policy"] == "none"
    when "catalog_signing_keys"
      require_exact_fields(
        details,
        %w[target algorithm private_key_location trust_anchor transition_policy history_policy],
        "#{id} details"
      )
      validate_target_epoch(details["target"], id)
      error("#{id} algorithm is invalid") unless details["algorithm"] == "Ed25519"
      unless details["private_key_location"] == "signing_edge_secret_only"
        error("#{id} private key location is invalid")
      end
      error("#{id} trust anchor is invalid") unless details["trust_anchor"] == "shipped_public_key"
      unless details["transition_policy"] == "signed_by_existing_trusted_key"
        error("#{id} transition policy is invalid")
      end
      error("#{id} history policy is invalid") unless details["history_policy"] == "append_only"
    when "classifier_model_registry"
      require_exact_fields(
        details,
        %w[
          target default_model_id default_model_revision embedding_dimension
          license weight_digest_required taxonomy_revision_required fallback
        ],
        "#{id} details"
      )
      validate_target_epoch(details["target"], id)
      error("#{id} model ID is invalid") unless details["default_model_id"] == "google-siglip-base-patch16-224"
      error("#{id} model revision is invalid") unless details["default_model_revision"] == 1
      error("#{id} embedding dimension is invalid") unless details["embedding_dimension"] == 768
      error("#{id} license is invalid") unless details["license"] == "Apache-2.0"
      error("#{id} must require weight digests") unless details["weight_digest_required"] == true
      error("#{id} must require taxonomy revisions") unless details["taxonomy_revision_required"] == true
      error("#{id} fallback is invalid") unless details["fallback"] == "noop_classifier"
    when "marketplace_storage_paths"
      require_exact_fields(
        details,
        %w[
          target buckets public_path_template creator_filename_in_path overwrite
          upsert object_backup_required
        ],
        "#{id} details"
      )
      validate_target_epoch(details["target"], id)
      validate_exact_string_set(
        details["buckets"],
        %w[uploads-private moderation-private catalog-public exports-private],
        "#{id} buckets"
      )
      expected_template = "sha256/<hex-0-1>/<hex-2-3>/<digest>/<role>.<extension>"
      error("#{id} public path template is invalid") unless details["public_path_template"] == expected_template
      error("#{id} must exclude creator filenames") unless details["creator_filename_in_path"] == false
      error("#{id} overwrite must be false") unless details["overwrite"] == false
      error("#{id} upsert must be false") unless details["upsert"] == false
      error("#{id} must require object backups") unless details["object_backup_required"] == true
    when "lock_screen_manifest"
      require_exact_fields(
        details,
        %w[
          support_scope implementation_gate fixture_policy verified_system_builds
          manifest_version provider category_id subcategory_id shot_prefix
          maximum_owned_assets unknown_newer_policy global_default_policy
          selection_policy active_override_policy rollback_policy
          agent_quiesce_policy daemon_timestamp_policy session_lock_refresh_policy
        ],
        "#{id} details"
      )
      error("lock_screen_manifest must be implemented") unless implementation == "implemented"
      error("lock_screen_manifest support scope is invalid") unless details["support_scope"] == "session_lock_screen_only"
      unless details["implementation_gate"] == "accepted_adrs_0010_and_0013"
        error("lock_screen_manifest implementation_gate is invalid")
      end
      error("lock_screen_manifest fixture_policy is invalid") unless details["fixture_policy"] == "redacted_version_gated_store"
      error("lock_screen_manifest verified builds are invalid") unless details["verified_system_builds"] == ["25F80", "25G83"]
      error("lock_screen_manifest manifest version is invalid") unless details["manifest_version"] == 1
      error("lock_screen_manifest provider is invalid") unless details["provider"] == "com.apple.wallpaper.choice.aerials"
      error("lock_screen_manifest category ID is invalid") unless details["category_id"] == "57414C49-0000-4000-8000-000000000001"
      error("lock_screen_manifest subcategory ID is invalid") unless details["subcategory_id"] == "57414C49-0000-4000-8000-000000000002"
      error("lock_screen_manifest shot prefix is invalid") unless details["shot_prefix"] == "CUSTOM_WALI_"
      error("lock_screen_manifest asset bound is invalid") unless details["maximum_owned_assets"] == 8
      error("lock_screen_manifest must reject unknown schemas before write") unless details["unknown_newer_policy"] == "reject_before_write"
      error("lock_screen_manifest global policy is invalid") unless details["global_default_policy"] == "transactional_current_user_linked"
      error("lock_screen_manifest selection policy is invalid") unless details["selection_policy"] == "main_display_single_asset"
      error("lock_screen_manifest active override policy is invalid") unless details["active_override_policy"] == "clear_displays_and_spaces_restore_exact"
      error("lock_screen_manifest rollback policy is invalid") unless details["rollback_policy"] == "exact_four_root_preimage_with_conflict_detection"
      error("lock_screen_manifest quiesce policy is invalid") unless details["agent_quiesce_policy"] == "before_managed_manifest_or_index_write"
      error("lock_screen_manifest daemon timestamp policy is invalid") unless details["daemon_timestamp_policy"] == "allow_last_set_and_last_use_drift_only"
      error("lock_screen_manifest session lock refresh policy is invalid") unless details["session_lock_refresh_policy"] == "restart_active_selection_once_per_distinct_lock"
    when "diagnostic_export"
      require_exact_fields(
        details,
        %w[current_format required_redaction excluded_payloads lease_required],
        "#{id} details"
      )
      error("unimplemented diagnostic_export current_format must be null") if implementation != "implemented" && !details["current_format"].nil?
      required = %w[user_paths credentials private_values media_bytes]
      redactions = string_array(details["required_redaction"], "diagnostic_export required_redaction")
      error("diagnostic_export required_redaction is incomplete") unless (required - redactions).empty?
      string_array(details["excluded_payloads"], "diagnostic_export excluded_payloads")
      error("diagnostic_export must require a lease") unless details["lease_required"] == true
    end
  end

  def validate_bundle_configurations(id, configurations)
    validate_configuration_keys(id, configurations)
    return unless configurations.is_a?(Hash)

    CONFIGURATIONS.each do |configuration|
      values = configurations[configuration]
      unless values.is_a?(Hash)
        error("#{id} #{configuration} configuration must be a mapping")
        next
      end
      require_exact_fields(values, IDENTITY_BUILD_SETTINGS.keys, "#{id} #{configuration}")
      values.each do |target, identifier|
        error("#{id} #{configuration} #{target} must be a bundle identifier") unless bundle_identifier?(identifier)
        expected = project_bundle_identifier(target, configuration)
        if expected && identifier != expected
          error("#{id} #{configuration} #{target} does not match resolved build settings")
        end
        required = EXPECTED_BUNDLE_IDENTIFIERS.dig(configuration, target)
        unless identifier == required
          error("#{id} #{configuration} #{target} must be #{required}")
        end
      end
    end
  end

  def validate_container_configurations(id, configurations)
    validate_configuration_keys(id, configurations)
    return unless configurations.is_a?(Hash)

    CONFIGURATIONS.each do |configuration|
      values = configurations[configuration]
      unless values.is_a?(Hash)
        error("#{id} #{configuration} configuration must be a mapping")
        next
      end
      require_exact_fields(values, %w[WALI WALIAgent WALILockScreenHelper], "#{id} #{configuration}")
      values.each do |target, identifiers|
        actual = string_array(identifiers, "#{id} #{configuration} #{target}")
        expected = project_application_groups(target, configuration)
        unless expected.nil? || actual.sort == expected.sort
          error("#{id} #{configuration} #{target} does not match resolved entitlements")
        end
        required = EXPECTED_APPLICATION_GROUPS.fetch(configuration)
        next if actual.sort == required.sort

        if required.empty?
          error("#{id} #{configuration} #{target} must not declare an application group")
        else
          error("#{id} #{configuration} #{target} must be #{required.join(', ')}")
        end
      end
    end
  end

  def validate_service_configurations(id, implementation, configurations)
    validate_configuration_keys(id, configurations)
    return unless configurations.is_a?(Hash)

    CONFIGURATIONS.each do |configuration|
      values = configurations[configuration]
      unless values.is_a?(Hash)
        error("#{id} #{configuration} configuration must be a mapping")
        next
      end
      require_exact_fields(values, %w[current target], "#{id} #{configuration}")
      current = string_array(values["current"], "#{id} #{configuration} current")
      target = string_array(values["target"], "#{id} #{configuration} target")
      if implementation == "unimplemented" && current.any?
        error("#{id} #{configuration} cannot declare a current service")
      elsif id == "agent_worker_service_names" && implementation == "configured"
        expected = project_bundle_identifier("WALITranscoder", configuration)
        unless expected && current == [expected]
          error("#{id} #{configuration} current service does not match resolved worker bundle identifier")
        end
        unless expected && target == [expected]
          error("#{id} #{configuration} target service does not match resolved worker bundle identifier")
        end
      end

      if id == "app_agent_service_names"
        expected = resolved_target_build_setting(
          "WALIAgent",
          configuration,
          "WALI_AGENT_CONTROL_SERVICE_NAME"
        )
        unless expected && target == [expected]
          error("#{id} #{configuration} target service does not match resolved build settings")
        end
        required = EXPECTED_CONTROL_SERVICES.fetch(configuration)
        unless target == [required]
          error("#{id} #{configuration} target must be #{required}")
        end
      elsif id == "agent_lock_screen_helper_service_names"
        required = "#{EXPECTED_BUNDLE_IDENTIFIERS.fetch(configuration).fetch("WALILockScreenHelper")}.control"
        expected = resolved_target_build_setting("WALILockScreenHelper", configuration, "WALI_LOCK_SCREEN_HELPER_SERVICE_NAME")
        error("#{id} #{configuration} service does not match resolved build settings") unless expected == required
        error("#{id} #{configuration} current and target must be #{required}") unless current == [required] && target == [required]
      elsif id == "agent_worker_service_names"
        required = EXPECTED_BUNDLE_IDENTIFIERS.dig(configuration, "WALITranscoder")
        unless current == [required]
          error("#{id} #{configuration} current must be #{required}")
        end
        unless target == [required]
          error("#{id} #{configuration} target must be #{required}")
        end
      end
    end
  end

  def validate_configuration_keys(id, configurations)
    unless configurations.is_a?(Hash)
      error("#{id} configurations must be a mapping")
      return
    end
    unless configurations.keys.sort == CONFIGURATIONS.sort
      error("#{id} configurations must contain exactly Debug, Development, Release")
    end
  end

  def validate_wire_details(id, implementation, details)
    require_exact_fields(details, %w[direction message_catalog], "#{id} details")
    direction = details["direction"]
    direction_pairs = Set.new
    unless direction.is_a?(Array) && !direction.empty?
      error("#{id} direction must be a non-empty array")
    else
      direction.each do |entry|
        unless entry.is_a?(Hash)
          error("#{id} direction entry must be a mapping")
          next
        end
        require_exact_fields(entry, %w[from to message_flow], "#{id} direction entry")
        unless %w[from to message_flow].all? { |field| nonempty_string?(entry[field]) }
          error("#{id} direction entries require from, to, and message_flow")
          next
        end
        %w[from to].each do |field|
          module_id = entry[field]
          error("#{id} direction references unknown module #{module_id}") unless @modules.key?(module_id)
        end
        direction_pairs << [entry["from"], entry["to"]]
      end
    end
    expected_pairs = case id
    when "app_agent_wire"
      Set.new([["WALI", "WALIAgent"], ["WALIAgent", "WALI"]])
    when "lock_screen_helper_wire"
      Set.new([
        ["WALIAgent", "WALILockScreenHelper"],
        ["WALILockScreenHelper", "WALIAgent"]
      ])
    else
      Set.new([["WALIAgent", "WALITranscoder"], ["WALITranscoder", "WALIAgent"]])
    end
    error("#{id} direction does not match its channel endpoints") unless direction_pairs == expected_pairs

    catalog = details["message_catalog"]
    unless catalog.is_a?(Hash)
      error("#{id} missing message_catalog")
      return
    end
    require_exact_fields(
      catalog,
      %w[status path messages required_envelope_fields],
      "#{id} message_catalog"
    )
    fields = string_array(catalog["required_envelope_fields"], "#{id} required_envelope_fields")
    missing = REQUIRED_ENVELOPE_FIELDS - fields
    error("#{id} message_catalog missing envelope fields: #{missing.join(', ')}") if missing.any?
    extras = fields - REQUIRED_ENVELOPE_FIELDS
    error("#{id} message_catalog has unknown envelope fields: #{extras.join(', ')}") if extras.any?
    messages = string_array(catalog["messages"], "#{id} messages")
    if implementation == "implemented"
      path = catalog["path"]
      catalog_path = safe_relative_path(path, "#{id} message_catalog path")
      error("#{id} implemented message_catalog status must be implemented") unless catalog["status"] == "implemented"
      error("#{id} implemented message_catalog path must exist") unless catalog_path && File.file?(catalog_path)
      error("#{id} implemented message_catalog must declare messages") if messages.empty?
    elsif id == "lock_screen_helper_wire"
      unless catalog["status"] == "planned" && catalog["path"].nil?
        error("#{id} unimplemented message_catalog must remain planned with a null path")
      end
      validate_exact_string_set(
        messages,
        %w[status activateVerifiedRelease deactivate restore],
        "#{id} planned messages"
      )
    elsif catalog["status"] != "planned" || !catalog["path"].nil? || catalog["messages"] != []
      error("#{id} unimplemented message_catalog must use null path and empty messages")
    end
  end

  def validate_rules
    rules_path = repository_path(".cursor/rules")
    return unless Dir.exist?(rules_path)

    Dir.glob(File.join(rules_path, "*.mdc")).sort.each do |rule|
      basename = File.basename(rule)
      lines = File.readlines(rule, chomp: true)
      error("#{basename} must stay under 50 lines") if lines.length >= 50
      unless lines.first == "---"
        error("#{basename} is missing YAML frontmatter")
        next
      end
      closing = lines[1..-1].index("---")
      unless closing
        error("#{basename} has invalid YAML frontmatter")
        next
      end
      frontmatter = lines[1, closing].join("\n")
      begin
        stream = Psych.parse_stream(frontmatter, basename)
        detect_duplicate_keys(stream, basename)
        metadata = Psych.safe_load(frontmatter, aliases: false)
        unless metadata.is_a?(Hash)
          error("#{basename} has invalid YAML frontmatter")
          next
        end
        error("#{basename} is missing a description") unless nonempty_string?(metadata["description"])
        error("#{basename} is missing alwaysApply") unless [true, false].include?(metadata["alwaysApply"])
      rescue Psych::SyntaxError, Psych::BadAlias
        error("#{basename} has invalid YAML frontmatter")
      end
    end
  end

  def validate_adrs
    adr_path = repository_path("docs/adr")
    return unless Dir.exist?(adr_path)

    records = {}
    Dir.glob(File.join(adr_path, "*.md")).sort.each do |adr|
      basename = File.basename(adr)
      next if basename == "README.md"
      error("#{basename} does not follow ADR naming") unless basename.match?(/\A[0-9]{4}-[a-z0-9-]+\.md\z/)
      record_id = basename[0, 4]

      metadata = {}
      File.readlines(adr, chomp: true).first(20).each do |line|
        match = line.match(/\A- ([a-z_]+):\s*(.+)\z/)
        next unless match
        key = match[1]
        error("#{basename} has duplicate ADR metadata #{key}") if metadata.key?(key)
        metadata[key] = match[2].strip
      end
      %w[status date owner_role accepted_by approval_reference].each do |field|
        error("#{basename} missing ADR metadata #{field}") unless nonempty_string?(metadata[field])
      end
      error("#{basename} has invalid ADR status") unless ADR_STATUS_VALUES.include?(metadata["status"])
      error("#{basename} has unknown owner_role #{metadata['owner_role']}") unless ROLE_IDS.include?(metadata["owner_role"])
      error("#{basename} has invalid accepted_by #{metadata['accepted_by']}") unless ACCEPTED_BY_VALUES.include?(metadata["accepted_by"])
      error("#{basename} date must use YYYY-MM-DD") unless metadata["date"].to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      if %w[accepted partially_superseded superseded].include?(metadata["status"]) &&
         metadata["accepted_by"] == "pending"
        error("#{basename} accepted status cannot have pending accepted_by")
      end
      if metadata["status"] == "proposed" && metadata["accepted_by"] != "pending"
        error("#{basename} proposed status must have accepted_by pending")
      end
      if %w[partially_superseded superseded].include?(metadata["status"])
        %w[superseded_by superseded_scope].each do |field|
          error("#{basename} #{metadata['status']} status requires #{field}") unless nonempty_string?(metadata[field])
        end
      end
      records[record_id] = {basename: basename, metadata: metadata}
    end
    validate_adr_supersession(records)
  end

  def validate_adr_supersession(records)
    records.each do |record_id, record|
      metadata = record[:metadata]
      next unless %w[accepted partially_superseded superseded].include?(metadata["status"])

      metadata_ids(metadata["superseded_by"]).each do |newer_id|
        newer = records[newer_id]
        unless newer && metadata_ids(newer[:metadata]["supersedes"]).include?(record_id)
          error("ADR #{record_id} superseded_by #{newer_id} is not reciprocated")
          next
        end
        old_scope = metadata_scopes_for(metadata["superseded_scope"], newer_id)
        new_scope = metadata_scopes_for(newer[:metadata]["supersedes_scope"], record_id)
        if old_scope.empty? || old_scope != new_scope
          error("supersession scope mismatch between ADR #{record_id} and ADR #{newer_id}")
        end
      end

      metadata_ids(metadata["supersedes"]).each do |older_id|
        older = records[older_id]
        unless older && metadata_ids(older[:metadata]["superseded_by"]).include?(record_id)
          error("ADR #{record_id} supersedes #{older_id} without reciprocal superseded_by")
        end
      end
    end
  end

  def metadata_ids(value)
    value.to_s.scan(/\b\d{4}\b/).uniq
  end

  def metadata_scopes(value)
    value.to_s.split(",").map(&:strip).reject(&:empty?).sort
  end

  def metadata_scopes_for(value, counterpart_id)
    serialized = value.to_s
    return metadata_scopes(serialized) unless serialized.include?("=")

    entry = serialized.split(";").map(&:strip).find do |candidate|
      candidate.start_with?("#{counterpart_id}=")
    end
    return [] unless entry

    metadata_scopes(entry.split("=", 2).last)
  end

  def validate_distribution_graphs(document)
    distributions = document["distributions"]
    unless distributions.is_a?(Hash) && distributions.keys.sort == %w[direct store]
      error("modules.yml must declare direct and store distributions")
      return
    end
    direct = distributions["direct"]
    expected_direct = {
      "project_spec" => "project.yml", "generated_project" => "WALI.xcodeproj",
      "identity_policy_adr" => "docs/adr/0020-direct-release-identifier-namespace.md",
      "release_policy_adr" => "docs/adr/0021-developer-id-local-only-entitlements.md",
      "configurations" => CONFIGURATIONS
    }
    error("direct distribution registry differs from approved graph") unless direct == expected_direct
    store = distributions["store"]
    expected_store = {
      "project_spec" => "project-store.yml", "generated_project" => "WALIStore.xcodeproj",
      "configurations" => %w[StoreDevelopment AppStore], "production_targets" => StoreGraphChecker::PRODUCTION,
      "excluded_modules" => %w[WALILockScreenWire WALILockScreenHelperRuntime WALILockScreenHelper],
      "excluded_sources" => ["Sources/WALIAgentRuntime/LockScreen/**"], "compilation_condition" => "WALI_APP_STORE",
      "policy_adr" => "docs/adr/0018-sandboxed-mac-app-store-distribution.md", "verification_gate" => "signed_sandbox_feasibility_pending"
    }
    error("store distribution registry differs from approved graph") unless store == expected_store
    %w[project-store.yml project-common.yml].each { |path| load_yaml(path, "missing #{path}") }
    StoreGraphChecker.new(@root).check!
  rescue StoreGraphChecker::Error => exception
    error("Store graph: #{exception.message}")
  end

  def validate_generated_project_ignore
    output, status = Open3.capture2e("git", "-C", @root, "rev-parse", "--is-inside-work-tree")
    return unless status.success? && output.strip == "true"

    _ignore_output, ignore_status = Open3.capture2e(
      "git", "-C", @root, "check-ignore", "--quiet", "--no-index",
      "WALI.xcodeproj/project.pbxproj"
    )
    error("generated WALI.xcodeproj must be ignored") unless ignore_status.success?
    _, store_ignored = Open3.capture2e("git", "-C", @root, "check-ignore", "--quiet", "--no-index", "WALIStore.xcodeproj/project.pbxproj")
    error("generated WALIStore.xcodeproj must be ignored") unless store_ignored.success?
  end

  def require_fields(value, fields, label)
    fields.each do |field|
      error("#{label} missing required field #{field}") unless value.key?(field)
    end
  end

  def require_exact_fields(value, fields, label)
    unless value.is_a?(Hash)
      error("#{label} must be a mapping")
      return
    end
    require_fields(value, fields, label)
    extras = value.keys - fields
    error("#{label} has unknown fields: #{extras.sort.join(', ')}") if extras.any?
  end

  def validate_exact_string_set(value, expected, label)
    actual = string_array(value, label)
    error("#{label} must contain exactly #{expected.join(', ')}") unless actual.sort == expected.sort
  end

  def string_array(value, label)
    unless value.is_a?(Array) && value.all? { |item| nonempty_string?(item) }
      error("#{label} must be an array of non-empty strings")
      return []
    end
    error("#{label} must not contain duplicates") unless value.uniq.length == value.length
    value
  end

  def safe_relative_path(value, label)
    unless nonempty_string?(value)
      error("#{label} must be a non-empty relative path")
      return nil
    end
    pathname = Pathname.new(value)
    if pathname.absolute? || pathname.each_filename.any? { |part| part == ".." }
      error("#{label} must stay within the repository")
      return nil
    end
    repository_path(pathname.cleanpath.to_s)
  end

  def safe_package_relative_path(value, label)
    unless nonempty_string?(value)
      error("#{label} must be a non-empty package-relative path")
      return nil
    end
    pathname = Pathname.new(value)
    if pathname.absolute? || pathname.each_filename.any? { |part| part == ".." }
      error("#{label} must stay within the Swift package")
      return nil
    end
    pathname.cleanpath.to_s
  end

  def nonempty_string?(value)
    value.is_a?(String) && !value.strip.empty?
  end

  def product_version?(value)
    nonempty_string?(value) && value.match?(/\A\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?\z/)
  end

  def bundle_identifier?(value)
    nonempty_string?(value) && value.match?(/\A[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\z/)
  end

  def project_bundle_identifier(target_name, configuration)
    target = @project.dig("targets", target_name)
    return nil unless target.is_a?(Hash)

    resolved_target_build_setting(
      target_name,
      configuration,
      "PRODUCT_BUNDLE_IDENTIFIER"
    )
  end

  def project_application_groups(target_name, configuration)
    target = @project.dig("targets", target_name)
    return nil unless target.is_a?(Hash)

    entitlements = target_build_settings(target_name, configuration)["CODE_SIGN_ENTITLEMENTS"]
    return [] unless nonempty_string?(entitlements)

    entitlement_application_groups(entitlements, target_name, configuration, resolve: true)
  end

  def entitlement_application_groups(relative, target_name, configuration, resolve:)
    path = safe_relative_path(relative, "#{target_name} #{configuration} entitlements")
    return nil unless path && File.file?(path)

    document = REXML::Document.new(File.read(path))
    dictionary = REXML::XPath.first(document, "/plist/dict")
    return [] unless dictionary

    elements = dictionary.elements.to_a
    key_index = elements.index do |element|
      element.name == "key" && element.text == "com.apple.security.application-groups"
    end
    return [] unless key_index

    array = elements[key_index + 1]
    return [] unless array && array.name == "array"

    values = REXML::XPath.match(array, "string").map { |element| element.text.to_s }
    return values unless resolve

    settings = target_build_settings(target_name, configuration)
    values.map do |value|
      expand_build_setting(
        value,
        settings,
        "#{target_name} #{configuration} application group",
        []
      )
    end.reject(&:empty?)
  rescue REXML::ParseException => exception
    error("#{target_name} #{configuration} entitlements are invalid XML: #{exception.message}")
    nil
  end

  def format_edges(edges)
    edges.to_a.sort.map { |from, to| "#{from}->#{to}" }.join(", ")
  end
end

root = ARGV[0] || File.expand_path("..", __dir__)
checker = ArchitectureChecker.new(root)
exit checker.run
