# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "open3"

# One production identity shared by source, Xcode, bundle, and release gates.
# Public configuration is intentionally reviewable; privileged keys are rejected.
module WALIProductionConfig
  PROJECT_REF = "afgxvhhubqzgpijcstsv"
  ORIGIN = "https://#{PROJECT_REF}.supabase.co"
  LEGAL_URL = "https://github.com/CodeWithInferno/WALI/blob/main/docs/legal"
  DIGEST_KEY = "WALI_PRODUCTION_CONFIGURATION_SHA256"
  INFO_KEYS = {
    "WALI_MARKETPLACE_ENABLED" => "WALIMarketplaceEnabled",
    "WALI_RELEASE_MODE" => "WALIReleaseMode",
    "WALI_AUTHENTICATION_METHOD" => "WALIAuthenticationMethod",
    "WALI_SUPABASE_PROJECT_REF" => "WALISupabaseProjectRef",
    "WALI_SUPABASE_URL" => "WALIMarketplaceURL",
    "WALI_SUPABASE_PUBLISHABLE_KEY" => "WALIMarketplacePublishableKey",
    "WALI_SUPABASE_PUBLISHABLE_KEY_SHA256" => "WALIMarketplacePublishableKeySHA256",
    "WALI_CATALOG_CDN_HOST" => "WALIApprovedCDNHosts",
    "WALI_CATALOG_SIGNING_KEY_ID" => "WALICatalogSigningKeyID",
    "WALI_CATALOG_SIGNING_PUBLIC_KEY_BASE64" => "WALICatalogSigningPublicKeyBase64",
    "WALI_CATALOG_RECOVERY_SIGNING_KEY_ID" => "WALICatalogRecoverySigningKeyID",
    "WALI_CATALOG_RECOVERY_SIGNING_PUBLIC_KEY_BASE64" => "WALICatalogRecoverySigningPublicKeyBase64",
    "WALI_LEGAL_BASE_URL" => "WALILegalBaseURL",
    DIGEST_KEY => "WALIProductionConfigurationSHA256"
  }.freeze
  MANIFEST_KEYS = (INFO_KEYS.keys - [DIGEST_KEY]).freeze
  AGENT_KEYS = %w[WALI_RELEASE_MODE WALI_PRODUCTION_CONFIGURATION_SHA256 WALI_CATALOG_CDN_HOST WALI_CATALOG_SIGNING_KEY_ID WALI_CATALOG_SIGNING_PUBLIC_KEY_BASE64 WALI_CATALOG_RECOVERY_SIGNING_KEY_ID WALI_CATALOG_RECOVERY_SIGNING_PUBLIC_KEY_BASE64].freeze
  module_function

  def demand(condition, message)
    raise "Production configuration: #{message}" unless condition
  end

  def validate_manifest!(manifest)
    demand(manifest.is_a?(Hash) && manifest.keys.sort == %w[schema_version settings] && manifest["schema_version"].instance_of?(Integer) && manifest["schema_version"] == 1, "unsupported manifest")
    values = manifest["settings"]
    demand(values.is_a?(Hash) && values.keys.sort == MANIFEST_KEYS.sort, "supply exactly the public manifest fields")
    demand(values.values.all? { |value| value.is_a?(String) && value.bytesize.between?(1, 2048) && value.ascii_only? && !value.match?(/[\x00-\x20\x7f$#\\\"]/) }, "invalid public field encoding")
    {
      "WALI_MARKETPLACE_ENABLED" => "YES", "WALI_RELEASE_MODE" => "production",
      "WALI_AUTHENTICATION_METHOD" => "email_otp", "WALI_SUPABASE_PROJECT_REF" => PROJECT_REF,
      "WALI_SUPABASE_URL" => ORIGIN, "WALI_CATALOG_CDN_HOST" => "#{PROJECT_REF}.supabase.co",
      "WALI_LEGAL_BASE_URL" => LEGAL_URL
    }.each { |key, expected| demand(values[key] == expected, "#{key} differs from the approved production identity") }
    key = values.fetch("WALI_SUPABASE_PUBLISHABLE_KEY")
    demand(key.match?(/\Asb_publishable_[A-Za-z0-9_-]{20,}\z/), "only a public publishable key is permitted")
    demand(values["WALI_SUPABASE_PUBLISHABLE_KEY_SHA256"] == Digest::SHA256.hexdigest(key), "publishable-key fingerprint mismatch")
    %w[WALI_CATALOG_SIGNING_KEY_ID WALI_CATALOG_RECOVERY_SIGNING_KEY_ID].each do |name|
      demand(values[name].match?(/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/), "invalid catalog key identifier")
    end
    %w[WALI_CATALOG_SIGNING_PUBLIC_KEY_BASE64 WALI_CATALOG_RECOVERY_SIGNING_PUBLIC_KEY_BASE64].each do |name|
      decoded = Base64.strict_decode64(values.fetch(name))
      demand(decoded.bytesize == 32 && decoded.bytes.any? { |byte| byte != 0 } && Base64.strict_encode64(decoded) == values[name], "use a canonical raw Ed25519 public key")
    end
    demand(values["WALI_CATALOG_SIGNING_KEY_ID"] != values["WALI_CATALOG_RECOVERY_SIGNING_KEY_ID"] && values["WALI_CATALOG_SIGNING_PUBLIC_KEY_BASE64"] != values["WALI_CATALOG_RECOVERY_SIGNING_PUBLIC_KEY_BASE64"], "primary and recovery keys must be distinct")
    manifest
  rescue ArgumentError
    raise "Production configuration: invalid public key encoding"
  end

  def load_manifest(root)
    path = File.join(root, "Config/Marketplace.production.json")
    demand(File.file?(path) && !File.symlink?(path) && File.size(path) <= 16 * 1024, "reviewed production manifest is missing or invalid")
    validate_manifest!(JSON.parse(File.binread(path)))
  rescue JSON::ParserError
    raise "Production configuration: invalid manifest JSON"
  end

  # All values are bounded ASCII without whitespace, so this encoding has one
  # interpretation in Ruby and Swift and is independent of JSON formatting.
  def manifest_digest(manifest)
    validate_manifest!(manifest)
    bytes = "schema_version=1\n" + MANIFEST_KEYS.sort.map { |key| "#{key}=#{manifest.fetch('settings').fetch(key)}\n" }.join
    Digest::SHA256.hexdigest(bytes)
  end

  def verify_settings!(values, root:, require_production: false)
    demand(values.is_a?(Hash), "missing resolved settings")
    INFO_KEYS.each_key do |key|
      demand(!values.keys.any? { |candidate| candidate.to_s.start_with?("#{key}[") }, "conditional override for #{key}")
    end
    if values["WALI_MARKETPLACE_ENABLED"] == "NO"
      demand(!require_production && values["WALI_RELEASE_MODE"] == "local_preview" && values["WALI_AUTHENTICATION_METHOD"] == "disabled" && values[DIGEST_KEY] == "", "local preview requires disabled auth and cannot be published as production")
      return {"release_mode" => "local_preview", "production_configuration_sha256" => nil}
    end
    demand(values["WALI_MARKETPLACE_ENABLED"] == "YES", "marketplace flag must be the exact string YES or NO")
    manifest = load_manifest(root)
    manifest.fetch("settings").each { |key, expected| demand(values[key] == expected, "resolved #{key} differs from reviewed manifest") }
    digest = manifest_digest(manifest)
    demand(values[DIGEST_KEY] == digest, "compiled digest differs from reviewed manifest")
    {"release_mode" => "production", "production_configuration_sha256" => digest}
  end

  def verify_bundle_info!(app, agent, root:, require_production: false)
    demand(app.is_a?(Hash) && agent.is_a?(Hash), "missing app/agent metadata")
    values = INFO_KEYS.to_h { |key, field| [key, app[field]] }
    receipt = verify_settings!(values, root: root, require_production: require_production)
    AGENT_KEYS.each do |key|
      next if receipt["release_mode"] == "local_preview" && !%w[WALI_RELEASE_MODE WALI_PRODUCTION_CONFIGURATION_SHA256].include?(key)
      demand(agent[INFO_KEYS.fetch(key)] == values[key], "app and agent #{key} differ")
    end
    %w[WALIMarketplacePublishableKey WALIMarketplacePublishableKeySHA256 WALIMarketplaceURL WALIAuthenticationMethod WALISupabaseProjectRef].each do |field|
      demand(!agent.key?(field), "foreground account configuration must not enter the agent")
    end
    receipt
  end

  def read_plist(path)
    text, status = Open3.capture2("/usr/bin/plutil", "-convert", "json", "-o", "-", path)
    demand(status.success?, "cannot read bundle metadata")
    JSON.parse(text)
  end

  def verify_app!(app, root:, require_production: false)
    verify_bundle_info!(read_plist(File.join(app, "Contents/Info.plist")), read_plist(File.join(app, "Contents/Library/LoginItems/WALIAgent.app/Contents/Info.plist")), root: root, require_production: require_production)
  end

  def xcconfig(text, root:)
    demand(text.bytesize <= 16 * 1024, "input exceeds bound")
    values = JSON.parse(text)
    demand(values.is_a?(Hash) && values.keys.sort == INFO_KEYS.keys.sort, "supply exactly the compiled public fields")
    verify_settings!(values, root: root, require_production: true)
    INFO_KEYS.keys.map { |key| "#{key} = #{values.fetch(key).gsub('/', '/$()')}\n" }.join
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    command, root, app = ARGV
    raise "Usage: production-config.rb verify-app ROOT APP | render ROOT | json ROOT" unless root
    case command
    when "verify-app"
      raise "Missing app" unless app
      puts JSON.generate(WALIProductionConfig.verify_app!(app, root: root))
    when "render", "json"
      manifest = WALIProductionConfig.load_manifest(root)
      values = manifest.fetch("settings").merge(WALIProductionConfig::DIGEST_KEY => WALIProductionConfig.manifest_digest(manifest))
      if command == "json"
        puts JSON.pretty_generate(values)
      else
        print WALIProductionConfig.xcconfig(JSON.generate(values), root: root)
      end
    else raise "Unknown production configuration operation"
    end
  rescue StandardError => error
    warn error.message
    exit 1
  end
end
