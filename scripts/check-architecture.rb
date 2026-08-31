#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "pathname"
require "psych"
require "rexml/document"
require "rexml/xpath"
require "set"

class ArchitectureChecker
  REQUIRED_MODULE_IDS = %w[
    WALICore WALIModel WALIWire WALIEngine WALIUI WALIAppRuntime
    WALIAgentRuntime WALITranscoderRuntime WALI WALIAgent WALITranscoder
  ].freeze

  REQUIRED_SURFACES = {
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
    "WALITranscoder" => "WALI_TRANSCODER_BUNDLE_IDENTIFIER"
  }.freeze
  EXPECTED_BUNDLE_IDENTIFIERS = {
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
  }.freeze
  EXPECTED_APPLICATION_GROUPS = {
    "Debug" => [],
    "Development" => ["group.com.wali.development.shared"],
    "Release" => ["group.com.wali.shared"]
  }.freeze
  EXPECTED_CONTROL_SERVICES = {
    "Debug" => "com.wali.debug.WALIAgent.control",
    "Development" => "com.wali.development.WALIAgent.control",
    "Release" => "com.wali.WALIAgent.control"
  }.freeze
  REQUIRED_EMBED_ONLY_EDGES = Set.new([
    ["WALI", "WALIAgent"],
    ["WALIAgent", "WALITranscoder"]
  ]).freeze
  REQUIRED_BUILD_EDGES = Set.new([
    ["WALI", "WALIAppRuntime"],
    ["WALIAppRuntime", "WALIUI"],
    ["WALIAgent", "WALIAgentRuntime"],
    ["WALIAgentRuntime", "WALIUI"],
    ["WALITranscoder", "WALITranscoderRuntime"]
  ]).freeze
  REQUIRED_PACKAGE_EDGES = Set.new([
    ["WALIAppRuntime", "WALIModel"],
    ["WALIAppRuntime", "WALIWire"],
    ["WALIAgentRuntime", "WALIModel"],
    ["WALIAgentRuntime", "WALIWire"],
    ["WALIAgentRuntime", "WALIEngine"],
    ["WALITranscoderRuntime", "WALIModel"],
    ["WALITranscoderRuntime", "WALIWire"],
    ["WALIUI", "WALIModel"]
  ]).freeze
  REQUIRED_PACKAGE_PRODUCTS = {
    "WALIModel" => {
      "kind" => "library", "linkage" => "static", "targets" => ["WALIModel"]
    },
    "WALIWire" => {
      "kind" => "library", "linkage" => "static", "targets" => ["WALIWire"]
    },
    "WALIEngine" => {
      "kind" => "library", "linkage" => "static", "targets" => ["WALIEngine"]
    }
  }.freeze
  REQUIRED_PACKAGE_TARGETS = {
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

    validate_modules(modules_document) if modules_document
    validate_project if modules_document && @project.is_a?(Hash)
    validate_swift_package_dumps if modules_document
    validate_imports if modules_document
    validate_surfaces(surfaces_document) if surfaces_document
    validate_rules
    validate_adrs
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
    %w[WALIModel WALIWire WALIEngine].each do |module_id|
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
        error("#{phase} WALICore package products must be exactly WALIModel, WALIWire, and WALIEngine")
      end
      unless targets == REQUIRED_PACKAGE_TARGETS
        error("#{phase} WALICore package targets must match the six-target split graph")
      end
    end

    {
      "build" => REQUIRED_BUILD_EDGES,
      "package" => REQUIRED_PACKAGE_EDGES,
      "embed_only" => REQUIRED_EMBED_ONLY_EDGES
    }.each do |kind, expected|
      %w[current target].each do |phase|
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

      match = assignment.match(/\A([A-Za-z_][A-Za-z0-9_]*)\s*(\?=|\+=|=)\s*(.*?)\s*\z/)
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
                         %w[WALI_APP_GROUP_IDENTIFIER WALI_AGENT_CONTROL_SERVICE_NAME]
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
    %w[WALI WALIAgent].each do |target_name|
      settings = target_build_settings(target_name, configuration)
      entitlements = settings["CODE_SIGN_ENTITLEMENTS"]
      if configuration == "Debug"
        error("#{target_name} Debug must not use entitlements") if nonempty_string?(entitlements)
        next
      end

      expected_path = "Config/#{target_name}.entitlements"
      unless entitlements == expected_path
        error("#{target_name} #{configuration} must use #{expected_path}")
        next
      end
      raw_groups = entitlement_application_groups(entitlements, target_name, configuration, resolve: false)
      unless raw_groups == ["$(WALI_APP_GROUP_IDENTIFIER)"]
        error("#{target_name} entitlements must reference $(WALI_APP_GROUP_IDENTIFIER)")
      end
    end

    CONFIGURATIONS.each do |candidate|
      entitlements = target_build_settings("WALITranscoder", candidate)["CODE_SIGN_ENTITLEMENTS"]
      if nonempty_string?(entitlements)
        error("WALITranscoder #{candidate} must not use application-group entitlements")
      end
    end
  end

  def validate_project_package_references
    project_packages = @project["packages"]
    unless project_packages.is_a?(Hash)
      error("project.yml packages must be a mapping")
      return
    end
    (project_packages.keys - @swift_packages.keys).sort.each do |reference|
      error("project.yml contains undeclared XcodeGen package reference #{reference}")
    end
    (@swift_packages.keys - project_packages.keys).sort.each do |reference|
      error("project.yml is missing XcodeGen package reference #{reference}")
    end
    (@swift_packages.keys & project_packages.keys).each do |reference|
      declared_path = @swift_packages.dig(reference, "xcodegen_reference", "path")
      actual_path = project_packages.dig(reference, "path")
      error("#{reference} XcodeGen package path does not match project.yml") unless declared_path == actual_path
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
    when "bundle_identifiers"
      require_exact_fields(details, %w[configurations], "#{id} details")
      validate_bundle_configurations(id, details["configurations"])
    when "application_group_containers"
      require_exact_fields(details, %w[entitlement_key configurations], "#{id} details")
      error("application group entitlement key is invalid") unless details["entitlement_key"] == "com.apple.security.application-groups"
      validate_container_configurations(id, details["configurations"])
    when "app_agent_service_names", "agent_worker_service_names"
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
        %w[trust_model signature_required network_status schema_policy],
        "#{id} details"
      )
      error("catalog_manifest trust model is invalid") unless details["trust_model"] == "signed_manifest_required"
      error("catalog_manifest must require signatures") unless details["signature_required"] == true
      error("catalog_manifest network_status must be deferred") unless details["network_status"] == "deferred"
      error("catalog_manifest schema_policy is invalid") unless details["schema_policy"] == "bounded_versioned"
    when "lock_screen_manifest"
      require_exact_fields(
        details,
        %w[support_scope implementation_gate fixture_policy],
        "#{id} details"
      )
      error("lock_screen_manifest must remain deferred") unless implementation == "deferred"
      error("lock_screen_manifest implementation_gate is invalid") unless details["implementation_gate"] == "separate_accepted_adr"
      error("lock_screen_manifest fixture_policy is invalid") unless details["fixture_policy"] == "copied_version_gated_store"
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
      require_exact_fields(values, %w[WALI WALIAgent WALITranscoder], "#{id} #{configuration}")
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
      require_exact_fields(values, %w[WALI WALIAgent], "#{id} #{configuration}")
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
    expected_pairs =
      if id == "app_agent_wire"
        Set.new([["WALI", "WALIAgent"], ["WALIAgent", "WALI"]])
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
        old_scope = metadata_scopes(metadata["superseded_scope"])
        new_scope = metadata_scopes(newer[:metadata]["supersedes_scope"])
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

  def validate_generated_project_ignore
    output, status = Open3.capture2e("git", "-C", @root, "rev-parse", "--is-inside-work-tree")
    return unless status.success? && output.strip == "true"

    _ignore_output, ignore_status = Open3.capture2e(
      "git", "-C", @root, "check-ignore", "--quiet", "--no-index",
      "WALI.xcodeproj/project.pbxproj"
    )
    error("generated WALI.xcodeproj must be ignored") unless ignore_status.success?
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
