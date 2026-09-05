#!/usr/bin/ruby
# frozen_string_literal: true

require "base64"
require "json"
require "pathname"
require "psych"
require "set"
require "time"
require "uri"

class MarketplaceContractError < StandardError
  attr_reader :code

  def initialize(code, message)
    @code = code
    super(message)
  end
end

class MarketplaceContractChecker
  ACCEPTANCE_REFERENCE = "project-owner AFK marketplace implementation directive 2026-09-01"
  REQUIRED_ADRS = %w[0011 0012 0013 0014 0015 0016 0017].freeze
  REQUIRED_CONTRACT_FILES = %w[
    docs/api/catalog-v1.md
    docs/api/creator-v1.md
    docs/api/moderation-v1.md
    docs/security/marketplace-threat-model.md
    docs/security/data-inventory.yml
    docs/security/media-policy.yml
    docs/security/dependency-policy.yml
    Fixtures/Catalog/manifest-v1.json
    Fixtures/Catalog/manifest-v1.signature
    Fixtures/Catalog/revocations-v1.json
    Fixtures/Catalog/invalid/duplicate-key.json
    Fixtures/Catalog/invalid/oversized-count.json
    Fixtures/Catalog/invalid/unapproved-host.json
  ].freeze
  REQUIRED_SURFACES = %w[
    catalog_manifest catalog_revocations marketplace_server_schema
    catalog_public_api creator_public_api moderation_public_api
    catalog_signing_keys classifier_model_registry marketplace_storage_paths
    lock_screen_helper_wire
  ].freeze
  REQUIRED_DATA_STORES = %w[
    auth.users wali.profiles wali.role_grants wali.creator_profiles
    wali.terms_acceptances wali.user_preferences wali.licenses wali.categories
    wali.tags wali.wallpapers wali.wallpaper_releases wali.artifacts
    wali.release_artifacts wali.wallpaper_categories wali.wallpaper_tags
    wali.wallpaper_embeddings wali.collections wali.collection_items
    wali.upload_sessions wali.submissions wali.rights_declarations
    wali.processing_attempts wali.classification_runs wali.moderation_reviews
    wali.moderation_actions wali.reports wali.copyright_cases
    wali.catalog_revocations wali.favorites wali.saved_wallpapers
    wali.creator_follows wali.engagement_events wali.wallpaper_stats_hourly
    wali.install_receipts wali.wallpaper_stats_daily wali.ranking_snapshots
    wali.quality_assessments
    wali.user_interest_profiles wali.command_idempotency wali.rate_limit_buckets
    wali.audit_events wali.catalog_signing_keys wali.model_registry
    wali.account_exports wali.queue_policies wali.backup_verification_runs
    wali.orphan_object_observations
    storage.uploads-private storage.moderation-private storage.catalog-public
    storage.exports-private logs.edge-functions logs.media-worker
    logs.client-diagnostics
  ].freeze
  REQUIRED_PUBLIC_VIEWS = %w[
    catalog_home_v1 catalog_wallpapers_v1 catalog_wallpaper_details_v1
    catalog_creators_v1 catalog_categories_v1 catalog_tags_v1
    catalog_collections_v1 my_profile_v1 my_creator_submissions_v1
    my_favorites_v1 my_saved_wallpapers_v1
  ].freeze
  ALLOWED_PUBLIC_FUNCTIONS = Set.new(%w[
    catalog_home_v1 catalog_search_v1 catalog_browse_v1
    catalog_wallpaper_detail_v1 catalog_creator_v1 my_favorites_v1
    my_saved_wallpapers_v1 set_favorite_v1 set_saved_v1
    set_creator_follow_v1 request_install_v1 creator_authorization_v1
    creator_metadata_v1 creator_processing_status_v1 my_creator_submissions_v1
    moderation_queue_v1 moderation_reports_v1 moderation_metadata_v1
    account_operation_references_v1
  ]).freeze
  EDGE_BOUNDARY_PUBLIC_FUNCTIONS = Set.new(%w[
    record_install_v1 wali_edge_take_rate_limit_v1
    wali_edge_request_install_v1 wali_edge_create_upload_v1
    wali_edge_bind_upload_endpoint_v1 wali_edge_complete_upload_v1
    wali_edge_submit_wallpaper_v1 wali_edge_moderate_submission_v1
    wali_edge_report_wallpaper_v1 wali_edge_resolve_report_v1 wali_edge_request_account_export_v1
    wali_edge_request_account_deletion_v1 wali_edge_admin_role_grant_v1
    wali_edge_catalog_security_state_v1 wali_edge_publish_security_document_v1
    wali_edge_prepare_publication_v1 wali_edge_finalize_publication_v1
    wali_edge_prepare_catalog_revocation_v1 wali_edge_finalize_catalog_revocation_v1
    wali_edge_account_export_status_v1
    wali_edge_mark_account_deletion_sessions_revoked_v1
    wali_edge_account_deletion_status_v1
    wali_edge_prepare_account_identity_deletion_v1
    wali_edge_finalize_account_identity_deletion_v1
    wali_edge_accept_creator_terms_v1 wali_edge_save_submission_draft_v1
    wali_edge_withdraw_submission_v1
  ]).freeze
  MANIFEST_ROOT_KEYS = %w[
    schema key_id wallpaper_id release_id edition issued_at artifacts
    metadata_digest
  ].freeze
  ARTIFACT_KEYS = %w[
    role url sha256 byte_count media_type width height duration_ms
  ].freeze
  ARTIFACT_ORDER = %w[
    thumbnail poster preview video_default video_1080p video_1440p video_2160p
  ].freeze
  REQUIRED_ARTIFACTS = Set.new(%w[thumbnail poster preview video_default]).freeze
  VIDEO_ROLES = Set.new(%w[preview video_default video_1080p video_1440p video_2160p]).freeze
  IMAGE_ROLES = Set.new(%w[thumbnail poster]).freeze
  REVOCATION_ROOT_KEYS = %w[schema key_id revision issued_at revocations].freeze
  REVOCATION_KEYS = %w[release_id artifact_sha256 reason issued_at].freeze
  REVOCATION_REASONS = Set.new(%w[
    critical_security corrupt_artifact signing_compromise
  ]).freeze
  TEST_SIGNATURE = "t0VeLJM0dupSRctfw3WA3_96NnnS06QyayZYPm5b2rwYktc7UzfSMSOgfM2GTXE48K-18Hz_oDu2ctxiSbjsAw"
  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/.freeze
  DIGEST_PATTERN = /\A[0-9a-f]{64}\z/.freeze
  KEY_ID_PATTERN = /\A[a-z0-9._-]{1,64}\z/.freeze
  TIMESTAMP_PATTERN = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/.freeze
  FORBIDDEN_HELPER_IMPORTS = Set.new(%w[
    SwiftUI AppKit AVFoundation VideoToolbox WebKit JavaScriptCore Network
    SQLite3 CoreData SwiftData CloudKit
  ]).freeze
  FORBIDDEN_HELPER_APIS = %w[
    Process NSTask dlopen NSAppleScript WKWebView URLSession NWConnection
  ].freeze

  def initialize(root)
    @root = File.expand_path(root)
    @errors = []
  end

  def run
    unless active?
      puts "Marketplace contract checks skipped: no marketplace contract surface"
      return 0
    end

    check_required_files
    check_accepted_adrs
    check_yaml_contracts
    check_module_and_surface_inventory
    check_api_documents
    check_manifest_fixtures
    check_database_exposure
    check_helper_boundary
    check_remote_dependency_pins

    @errors.each { |error| warn "Marketplace contract violation [#{error.code}]: #{error.message}" }
    if @errors.empty?
      puts "Marketplace contract checks passed"
      0
    else
      warn "Marketplace contract checks failed: #{@errors.length} violation(s)"
      1
    end
  rescue MarketplaceContractError => error
    warn "Marketplace contract violation [#{error.code}]: #{error.message}"
    1
  end

  private

  def active?
    File.file?(path("docs/api/catalog-v1.md")) ||
      File.directory?(path("Packages/WALICore/Sources/WALICatalog")) ||
      File.directory?(path("Sources/WALILockScreenHelper")) ||
      Dir.glob(path("supabase/migrations/*.sql")).any?
  end

  def path(relative)
    File.join(@root, relative)
  end

  def record(code, message)
    @errors << MarketplaceContractError.new(code, message)
  end

  def check_required_files
    REQUIRED_CONTRACT_FILES.each do |relative|
      record("MKT-CONTRACT-MISSING", "missing #{relative}") unless File.file?(path(relative))
    end
  end

  def check_accepted_adrs
    adrs = {}
    Dir.glob(path("docs/adr/[0-9][0-9][0-9][0-9]-*.md")).each do |file|
      id = File.basename(file)[0, 4]
      metadata = {}
      File.readlines(file, chomp: true).first(24).each do |line|
        match = line.match(/\A- ([a-z_]+):\s*(.+)\z/)
        metadata[match[1]] = match[2].strip if match
      end
      adrs[id] = metadata
    end

    REQUIRED_ADRS.each do |id|
      metadata = adrs[id]
      unless metadata
        record("MKT-ADR-GATE", "missing accepted ADR #{id}")
        next
      end
      record("MKT-ADR-GATE", "ADR #{id} must be accepted or partially superseded") unless %w[accepted partially_superseded].include?(metadata["status"])
      record("MKT-ADR-GATE", "ADR #{id} must be accepted by project_owner") unless metadata["accepted_by"] == "project_owner"
      unless metadata["approval_reference"] == ACCEPTANCE_REFERENCE
        record("MKT-ADR-GATE", "ADR #{id} has the wrong approval reference")
      end
    end

    expected_new = "0008=lock_screen_privileged_process_ownership;0009=lock_screen_privileged_process_ownership;0010=lock_screen_privileged_process_ownership"
    record("MKT-ADR-RECIPROCITY", "ADR 0013 pair-scoped supersession is incomplete") unless adrs.dig("0013", "supersedes_scope") == expected_new
    expected_old = {
      "0008" => "0013=lock_screen_privileged_process_ownership",
      "0009" => "0010=refresh_only_after_required_mutation;0013=lock_screen_privileged_process_ownership",
      "0010" => "0013=lock_screen_privileged_process_ownership"
    }
    expected_old.each do |id, value|
      record("MKT-ADR-RECIPROCITY", "ADR #{id} pair-scoped supersession is incomplete") unless adrs.dig(id, "superseded_scope") == value
    end
  end

  def check_yaml_contracts
    media = load_yaml("docs/security/media-policy.yml")
    dependencies = load_yaml("docs/security/dependency-policy.yml")
    inventory = load_yaml("docs/security/data-inventory.yml")
    return unless media && dependencies && inventory

    required_media = {
      %w[intake maximum_raw_bytes] => 1_073_741_824,
      %w[intake maximum_duration_ms] => 600_000,
      %w[intake maximum_width] => 7_680,
      %w[intake maximum_height] => 4_320,
      %w[intake maximum_tracks] => 2,
      %w[processing maximum_total_output_bytes] => 2_147_483_648,
      %w[processing network] => "none",
      %w[processing credentials] => "none",
      %w[canonical_output video codec] => "hevc",
      %w[canonical_output video exact_video_tracks] => 1,
      %w[canonical_output video exact_audio_tracks] => 0,
      %w[classification deterministic_frame_count] => 7,
      %w[publication immutable] => true,
      %w[publication overwrite] => false,
      %w[publication upsert] => false
    }
    required_media.each do |keys, expected|
      actual = keys.reduce(media) { |value, key| value.is_a?(Hash) ? value[key] : nil }
      record("MKT-MEDIA-POLICY", "#{keys.join('.')} must be #{expected.inspect}") unless actual == expected
    end

    pins = dependencies["pinning"]
    unless pins.is_a?(Hash) && pins["floating_branches_forbidden"] == true && pins["mutable_container_tags_forbidden"] == true
      record("MKT-DEPENDENCY-POLICY", "dependency pinning must reject floating branches and mutable tags")
    end
    unless dependencies.dig("ffmpeg", "forbidden_default_flags") == ["--enable-gpl", "--enable-nonfree"]
      record("MKT-DEPENDENCY-POLICY", "FFmpeg default profile must forbid GPL and nonfree flags")
    end

    stores = inventory["stores"]
    unless stores.is_a?(Array)
      record("MKT-DATA-INVENTORY", "data inventory stores must be an array")
      return
    end
    ids = stores.map { |item| item.is_a?(Hash) ? item["id"] : nil }.compact
    duplicates = ids.group_by { |item| item }.select { |_id, values| values.length > 1 }.keys
    record("MKT-DATA-INVENTORY", "duplicate data inventory IDs: #{duplicates.join(', ')}") unless duplicates.empty?
    missing = REQUIRED_DATA_STORES - ids
    record("MKT-DATA-INVENTORY", "missing data stores: #{missing.join(', ')}") unless missing.empty?
    migration_stores = Dir.glob(path("supabase/migrations/*.sql")).flat_map do |file|
      File.read(file).scan(/create\s+table\s+(?:if\s+not\s+exists\s+)?(wali\.[a-zA-Z0-9_]+)/i).flatten
    end.uniq.sort
    undocumented = migration_stores - ids
    unless undocumented.empty?
      record("MKT-DATA-INVENTORY", "migration tables missing from data inventory: #{undocumented.join(', ')}")
    end
    stores.each do |store|
      next unless store.is_a?(Hash)

      required = %w[id category purpose subjects read_roles write_roles classification retention deletion backup]
      absent = required - store.keys
      record("MKT-DATA-INVENTORY", "#{store['id'] || '<unknown>'} missing #{absent.join(', ')}") unless absent.empty?
    end
  end

  def load_yaml(relative)
    file = path(relative)
    return nil unless File.file?(file)

    reject_duplicate_yaml_keys(file)
    value = Psych.safe_load(File.read(file), aliases: false)
    unless value.is_a?(Hash)
      record("MKT-YAML-SHAPE", "#{relative} root must be a mapping")
      return nil
    end
    value
  rescue Psych::SyntaxError, Psych::BadAlias => error
    record("MKT-YAML-SHAPE", "#{relative} is invalid YAML: #{error.message.lines.first.to_s.strip}")
    nil
  rescue MarketplaceContractError => error
    @errors << error
    nil
  end

  def reject_duplicate_yaml_keys(file)
    document = Psych.parse_stream(File.read(file))
    walk_yaml_node(document, file)
  end

  def walk_yaml_node(node, file)
    if node.is_a?(Psych::Nodes::Mapping)
      seen = Set.new
      node.children.each_slice(2) do |key, value|
        if key.is_a?(Psych::Nodes::Scalar)
          raise MarketplaceContractError.new("MKT-YAML-DUPLICATE-KEY", "#{relative(file)} duplicates YAML key #{key.value}") if seen.include?(key.value)
          seen << key.value
        end
        walk_yaml_node(key, file)
        walk_yaml_node(value, file)
      end
    elsif node.respond_to?(:children)
      Array(node.children).each { |child| walk_yaml_node(child, file) }
    end
  end

  def relative(file)
    Pathname.new(file).relative_path_from(Pathname.new(@root)).to_s
  end

  def check_module_and_surface_inventory
    modules = load_yaml("docs/architecture/modules.yml")
    surfaces = load_yaml("docs/compatibility/surfaces.yml")
    return unless modules && surfaces

    module_map = modules["modules"] || {}
    %w[WALICatalog WALICatalogRuntime WALILockScreenHelperRuntime WALILockScreenHelper].each do |id|
      record("MKT-MODULE-MISSING", "modules.yml missing #{id}") unless module_map.key?(id)
    end
    if module_map["WALICatalog"]
      imports = module_map["WALICatalog"]["current_allowed_internal_imports"]
      record("MKT-MODULE-BOUNDARY", "WALICatalog must import only WALIModel internally") unless imports == ["WALIModel"]
    end
    if module_map["WALICatalogRuntime"]
      imports = module_map["WALICatalogRuntime"]["target_allowed_internal_imports"]
      record("MKT-MODULE-BOUNDARY", "WALICatalogRuntime must import only WALICatalog internally") unless imports == ["WALICatalog"]
    end
    if module_map["WALILockScreenHelperRuntime"]
      forbidden = Set.new(module_map["WALILockScreenHelperRuntime"]["forbidden_frameworks"] || [])
      missing = FORBIDDEN_HELPER_IMPORTS - forbidden
      record("MKT-HELPER-BOUNDARY", "helper forbidden framework list missing #{missing.to_a.sort.join(', ')}") unless missing.empty?
    end

    ids = Array(surfaces["surfaces"]).map { |surface| surface.is_a?(Hash) ? surface["id"] : nil }.compact
    missing = REQUIRED_SURFACES - ids
    record("MKT-COMPATIBILITY-MISSING", "missing compatibility entries: #{missing.join(', ')}") unless missing.empty?
    catalog = Array(surfaces["surfaces"]).find { |surface| surface["id"] == "catalog_manifest" }
    unless catalog && catalog.dig("version", "current") == {"epoch" => 1, "revision" => 0}
      record("MKT-COMPATIBILITY-VERSION", "catalog manifest must be epoch 1 revision 0")
    end
  end

  def check_api_documents
    catalog = read("docs/api/catalog-v1.md")
    creator = read("docs/api/creator-v1.md")
    moderation = read("docs/api/moderation-v1.md")
    REQUIRED_PUBLIC_VIEWS.each do |name|
      record("MKT-API-ALLOWLIST", "catalog contract missing #{name}") unless catalog.include?(name)
    end
    %w[request-install record-install report-wallpaper].each do |name|
      record("MKT-API-ALLOWLIST", "catalog contract missing #{name}") unless catalog.include?(name)
    end
    %w[current_release_id revision favorite_revision saved_revision].each do |field|
      record("MKT-API-SHAPE", "catalog contract missing #{field}") unless catalog.include?(field)
    end
    %w[create-upload complete-upload submit-wallpaper].each do |name|
      record("MKT-API-ALLOWLIST", "creator contract missing #{name}") unless creator.include?(name)
    end
    %w[moderate-submission publish-release admin-role-grant].each do |name|
      record("MKT-API-ALLOWLIST", "moderation contract missing #{name}") unless moderation.include?(name)
    end
  end

  def read(relative)
    file = path(relative)
    File.file?(file) ? File.read(file) : ""
  end

  def check_manifest_fixtures
    manifest_path = path("Fixtures/Catalog/manifest-v1.json")
    return unless File.file?(manifest_path)

    raw, manifest = strict_json(manifest_path, maximum_bytes: 65_536, canonical: true)
    validate_manifest(manifest, allowed_hosts: Set.new(["catalog.wali.example"]))
    signature = read("Fixtures/Catalog/manifest-v1.signature")
    unless signature == TEST_SIGNATURE && signature.match?(/\A[A-Za-z0-9_-]{86}\z/)
      record("MKT-MANIFEST-SIGNATURE", "golden detached signature does not match the accepted test vector")
    end
    record("MKT-MANIFEST-BYTES", "golden manifest unexpectedly empty") if raw.empty?

    revocation_path = path("Fixtures/Catalog/revocations-v1.json")
    if File.file?(revocation_path)
      _body, revocations = strict_json(revocation_path, maximum_bytes: 1_048_576, canonical: true)
      validate_revocations(revocations)
    end

    expected = {
      "duplicate-key.json" => "MKT-JSON-DUPLICATE-KEY",
      "oversized-count.json" => "MKT-MANIFEST-ARTIFACT-COUNT",
      "unapproved-host.json" => "MKT-MANIFEST-HOST"
    }
    expected.each do |name, code|
      file = path("Fixtures/Catalog/invalid/#{name}")
      next unless File.file?(file)

      begin
        _invalid_raw, invalid = strict_json(file, maximum_bytes: 65_536, canonical: true)
        validate_manifest(invalid, allowed_hosts: Set.new(["catalog.wali.example"]))
        record("MKT-INVALID-FIXTURE-ACCEPTED", "#{name} no longer violates its contract")
      rescue MarketplaceContractError => error
        record("MKT-INVALID-FIXTURE-CODE", "#{name} produced #{error.code}, expected #{code}") unless error.code == code
      end
    end
  rescue MarketplaceContractError => error
    @errors << error
  end

  def strict_json(file, maximum_bytes:, canonical:)
    raw = File.binread(file)
    raise MarketplaceContractError.new("MKT-JSON-SIZE", "#{relative(file)} exceeds #{maximum_bytes} bytes") if raw.bytesize > maximum_bytes
    raise MarketplaceContractError.new("MKT-JSON-BOM", "#{relative(file)} contains a UTF-8 BOM") if raw.start_with?("\xEF\xBB\xBF".b)
    raise MarketplaceContractError.new("MKT-JSON-ENCODING", "#{relative(file)} is not valid UTF-8") unless raw.dup.force_encoding(Encoding::UTF_8).valid_encoding?
    reject_duplicate_json_keys(raw)
    value = JSON.parse(raw, create_additions: false)
    if canonical && JSON.generate(value) != raw
      raise MarketplaceContractError.new("MKT-JSON-NONCANONICAL", "#{relative(file)} is not compact schema-canonical JSON")
    end
    [raw, value]
  rescue JSON::ParserError => error
    raise MarketplaceContractError.new("MKT-JSON-SHAPE", "#{relative(file)} is invalid JSON: #{error.message}")
  end

  # JSON's object_class hook does not consistently call Hash#[]= across the
  # C-extension versions shipped by macOS and Ubuntu. Psych preserves mapping
  # pairs in its syntax tree, so use it only as a portable duplicate-key pass;
  # JSON.parse below remains the authority for JSON grammar and values.
  def reject_duplicate_json_keys(raw)
    document = Psych.parse(raw)
    visit = lambda do |node|
      if node.is_a?(Psych::Nodes::Mapping)
        keys = Set.new
        node.children.each_slice(2) do |key, value|
          if key.is_a?(Psych::Nodes::Scalar)
            decoded = key.value
            if keys.include?(decoded)
              raise MarketplaceContractError.new("MKT-JSON-DUPLICATE-KEY", "duplicate JSON key #{decoded}")
            end
            keys << decoded
          end
          visit.call(value)
        end
      else
        node.children&.each { |child| visit.call(child) }
      end
    end
    visit.call(document)
  rescue Psych::SyntaxError
    # Let JSON.parse report malformed JSON using the stable contract code.
    nil
  end

  def validate_manifest(value, allowed_hosts:)
    mapping(value, "MKT-MANIFEST-SHAPE", "manifest")
    exact_keys(value, MANIFEST_ROOT_KEYS, "MKT-MANIFEST-KEYS", "manifest")
    validate_depth(value, 4)
    validate_schema(value["schema"])
    string(value["key_id"], KEY_ID_PATTERN, "MKT-MANIFEST-KEY-ID", "key_id")
    uuid(value["wallpaper_id"], "wallpaper_id")
    uuid(value["release_id"], "release_id")
    integer_range(value["edition"], 1, 2_147_483_647, "MKT-MANIFEST-EDITION", "edition")
    timestamp(value["issued_at"])
    digest(value["metadata_digest"], "metadata_digest")

    artifacts = value["artifacts"]
    unless artifacts.is_a?(Array) && artifacts.length.between?(4, 7)
      raise MarketplaceContractError.new("MKT-MANIFEST-ARTIFACT-COUNT", "manifest must contain 4...7 artifacts")
    end
    roles = artifacts.map { |artifact| artifact.is_a?(Hash) ? artifact["role"] : nil }
    unless roles == ARTIFACT_ORDER.select { |role| roles.include?(role) } && roles.uniq == roles
      raise MarketplaceContractError.new("MKT-MANIFEST-ARTIFACT-ORDER", "artifact roles are duplicated or not in canonical order")
    end
    unless REQUIRED_ARTIFACTS.subset?(Set.new(roles))
      raise MarketplaceContractError.new("MKT-MANIFEST-ARTIFACT-ROLES", "manifest is missing a required artifact role")
    end
    artifacts.each { |artifact| validate_artifact(artifact, allowed_hosts) }
  end

  def validate_schema(value)
    mapping(value, "MKT-MANIFEST-SCHEMA", "schema")
    exact_keys(value, %w[epoch revision], "MKT-MANIFEST-SCHEMA", "schema")
    unless value["epoch"] == 1 && value["revision"] == 0
      raise MarketplaceContractError.new("MKT-MANIFEST-EPOCH", "only manifest epoch 1 revision 0 is accepted")
    end
  end

  def validate_artifact(value, allowed_hosts)
    mapping(value, "MKT-MANIFEST-ARTIFACT", "artifact")
    exact_keys(value, ARTIFACT_KEYS, "MKT-MANIFEST-ARTIFACT", "artifact")
    role = value["role"]
    raise MarketplaceContractError.new("MKT-MANIFEST-ARTIFACT-ROLES", "unknown artifact role") unless ARTIFACT_ORDER.include?(role)

    digest(value["sha256"], "artifact sha256")
    integer_range(value["byte_count"], 1, 2_147_483_648, "MKT-MANIFEST-BYTE-COUNT", "byte_count")
    integer_range(value["width"], 1, 7_680, "MKT-MANIFEST-DIMENSION", "width")
    integer_range(value["height"], 1, 4_320, "MKT-MANIFEST-DIMENSION", "height")
    if IMAGE_ROLES.include?(role)
      raise MarketplaceContractError.new("MKT-MANIFEST-MEDIA-TYPE", "image role has invalid media type") unless %w[image/jpeg image/png].include?(value["media_type"])
      raise MarketplaceContractError.new("MKT-MANIFEST-DURATION", "image duration must be zero") unless value["duration_ms"] == 0
    elsif VIDEO_ROLES.include?(role)
      raise MarketplaceContractError.new("MKT-MANIFEST-MEDIA-TYPE", "video role must be video/mp4") unless value["media_type"] == "video/mp4"
      integer_range(value["duration_ms"], 1, 600_000, "MKT-MANIFEST-DURATION", "duration_ms")
    end
    validate_url(value["url"], allowed_hosts, value["sha256"])
  end

  def validate_url(value, allowed_hosts, artifact_digest)
    unless value.is_a?(String) && value.length <= 2_048
      raise MarketplaceContractError.new("MKT-MANIFEST-URL", "artifact URL is absent or too long")
    end
    uri = URI.parse(value)
    unless uri.is_a?(URI::HTTPS) && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
      raise MarketplaceContractError.new("MKT-MANIFEST-URL", "artifact URL must be bare HTTPS")
    end
    unless allowed_hosts.include?(uri.host)
      raise MarketplaceContractError.new("MKT-MANIFEST-HOST", "artifact URL host #{uri.host} is not approved")
    end
    unless uri.path.include?(artifact_digest)
      raise MarketplaceContractError.new("MKT-MANIFEST-URL", "artifact URL path does not contain its digest")
    end
  rescue URI::InvalidURIError
    raise MarketplaceContractError.new("MKT-MANIFEST-URL", "artifact URL is invalid")
  end

  def validate_revocations(value)
    mapping(value, "MKT-REVOCATION-SHAPE", "revocation body")
    exact_keys(value, REVOCATION_ROOT_KEYS, "MKT-REVOCATION-KEYS", "revocation body")
    validate_schema(value["schema"])
    string(value["key_id"], KEY_ID_PATTERN, "MKT-REVOCATION-KEY-ID", "key_id")
    integer_range(value["revision"], 1, 2_147_483_647, "MKT-REVOCATION-REVISION", "revision")
    timestamp(value["issued_at"])
    entries = value["revocations"]
    unless entries.is_a?(Array) && entries.length <= 4_096
      raise MarketplaceContractError.new("MKT-REVOCATION-COUNT", "revocation count exceeds 4096")
    end
    tuples = entries.map do |entry|
      mapping(entry, "MKT-REVOCATION-SHAPE", "revocation entry")
      exact_keys(entry, REVOCATION_KEYS, "MKT-REVOCATION-KEYS", "revocation entry")
      uuid(entry["release_id"], "release_id")
      digest(entry["artifact_sha256"], "artifact_sha256")
      unless REVOCATION_REASONS.include?(entry["reason"])
        raise MarketplaceContractError.new("MKT-REVOCATION-REASON", "invalid revocation reason")
      end
      timestamp(entry["issued_at"])
      [entry["release_id"], entry["artifact_sha256"]]
    end
    unless tuples == tuples.sort && tuples.uniq == tuples
      raise MarketplaceContractError.new("MKT-REVOCATION-ORDER", "revocations must be unique and canonically sorted")
    end
  end

  def validate_depth(value, maximum, depth = 1)
    raise MarketplaceContractError.new("MKT-JSON-DEPTH", "JSON nesting exceeds #{maximum}") if depth > maximum
    case value
    when Hash
      value.each_value { |child| validate_depth(child, maximum, depth + 1) if child.is_a?(Hash) || child.is_a?(Array) }
    when Array
      value.each { |child| validate_depth(child, maximum, depth + 1) if child.is_a?(Hash) || child.is_a?(Array) }
    end
  end

  def mapping(value, code, label)
    raise MarketplaceContractError.new(code, "#{label} must be an object") unless value.is_a?(Hash)
  end

  def exact_keys(value, expected, code, label)
    raise MarketplaceContractError.new(code, "#{label} keys are not in canonical schema order") unless value.keys == expected
  end

  def string(value, pattern, code, label)
    raise MarketplaceContractError.new(code, "#{label} is invalid") unless value.is_a?(String) && value.match?(pattern)
  end

  def uuid(value, label)
    string(value, UUID_PATTERN, "MKT-MANIFEST-UUID", label)
  end

  def digest(value, label)
    string(value, DIGEST_PATTERN, "MKT-MANIFEST-DIGEST", label)
  end

  def integer_range(value, minimum, maximum, code, label)
    unless value.is_a?(Integer) && value.between?(minimum, maximum)
      raise MarketplaceContractError.new(code, "#{label} must be an integer in #{minimum}...#{maximum}")
    end
  end

  def timestamp(value)
    unless value.is_a?(String) && value.match?(TIMESTAMP_PATTERN)
      raise MarketplaceContractError.new("MKT-MANIFEST-TIMESTAMP", "timestamp must be UTC RFC3339 seconds")
    end
    Time.iso8601(value)
  rescue ArgumentError
    raise MarketplaceContractError.new("MKT-MANIFEST-TIMESTAMP", "timestamp is not a real UTC instant")
  end

  def check_database_exposure
    Dir.glob(path("supabase/migrations/*.sql")).sort.each do |file|
      sql = File.read(file)
      sql.scan(/create\s+(?:or\s+replace\s+)?table\s+(?:if\s+not\s+exists\s+)?public\.([a-zA-Z0-9_]+)/i).flatten.each do |name|
        record("MKT-EXPOSED-TABLE", "#{relative(file)} creates forbidden exposed table public.#{name}")
      end
      sql.scan(/create\s+(?:or\s+replace\s+)?view\s+public\.([a-zA-Z0-9_]+)/i).flatten.each do |name|
        record("MKT-API-ALLOWLIST", "#{relative(file)} creates unapproved public view #{name}") unless REQUIRED_PUBLIC_VIEWS.include?(name)
      end
      sql.scan(/create\s+(?:or\s+replace\s+)?function\s+public\.([a-zA-Z0-9_]+)/i).flatten.each do |name|
        approved = ALLOWED_PUBLIC_FUNCTIONS.include?(name) || EDGE_BOUNDARY_PUBLIC_FUNCTIONS.include?(name)
        record("MKT-API-ALLOWLIST", "#{relative(file)} creates unapproved public function #{name}") unless approved
      end
    end
  end

  def check_helper_boundary
    %w[Sources/WALILockScreenHelper Sources/WALILockScreenHelperRuntime].each do |relative_dir|
      directory = path(relative_dir)
      next unless File.directory?(directory)

      Dir.glob(File.join(directory, "**/*.swift")).sort.each do |file|
        source = File.read(file)
        source.scan(/^\s*(?:@testable\s+)?import\s+([A-Za-z_][A-Za-z0-9_]*)/).flatten.each do |imported|
          if FORBIDDEN_HELPER_IMPORTS.include?(imported)
            record("MKT-HELPER-FORBIDDEN-IMPORT", "#{relative(file)} imports #{imported}")
          end
        end
        FORBIDDEN_HELPER_APIS.each do |api|
          if source.match?(/\b#{Regexp.escape(api)}\b/)
            record("MKT-HELPER-FORBIDDEN-API", "#{relative(file)} references #{api}")
          end
        end
      end
    end
  end

  def check_remote_dependency_pins
    project = load_yaml("project.yml")
    if project
      (project["packages"] || {}).each do |name, specification|
        next unless specification.is_a?(Hash) && specification["url"]

        unless specification["exactVersion"].is_a?(String) && !specification["exactVersion"].empty?
          record("MKT-DEPENDENCY-UNPINNED", "project.yml package #{name} must use exactVersion")
        end
        forbidden = %w[from version branch revision] & specification.keys
        record("MKT-DEPENDENCY-UNPINNED", "project.yml package #{name} uses #{forbidden.join(', ')}") unless forbidden.empty?
      end
    end

    package_file = path("Packages/WALICore/Package.swift")
    if File.file?(package_file)
      File.read(package_file).scan(/\.package\s*\((.*?)\)/m).flatten.each do |declaration|
        next unless declaration.include?("url:")
        record("MKT-DEPENDENCY-UNPINNED", "Package.swift remote dependency must use exact:") unless declaration.include?("exact:")
      end
    end

    Dir.glob(path(".github/workflows/*.{yml,yaml}")).each do |file|
      File.readlines(file).each_with_index do |line, index|
        match = line.match(/^\s*uses:\s*([^\s]+)\s*$/)
        next unless match
        next if match[1].start_with?("./")
        next if match[1].match?(/@[0-9a-f]{40}\z/)

        record("MKT-ACTION-UNPINNED", "#{relative(file)}:#{index + 1} is not SHA-pinned")
      end
    end
  end
end

root = ARGV[0] || File.expand_path("..", __dir__)
exit MarketplaceContractChecker.new(root).run
