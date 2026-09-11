#!/usr/bin/env ruby
# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../scripts/production-config"
require_relative "../../fastlane/release_support"

class ProductionConfigTests < Minitest::Test
  P = WALIProductionConfig
  def settings
    key = "sb_publishable_" + "x" * 32
    {
      "WALI_MARKETPLACE_ENABLED" => "YES", "WALI_RELEASE_MODE" => "production",
      "WALI_AUTHENTICATION_METHOD" => "email_otp",
      "WALI_SUPABASE_PROJECT_REF" => "afgxvhhubqzgpijcstsv",
      "WALI_SUPABASE_URL" => "https://afgxvhhubqzgpijcstsv.supabase.co",
      "WALI_SUPABASE_PUBLISHABLE_KEY" => key,
      "WALI_SUPABASE_PUBLISHABLE_KEY_SHA256" => Digest::SHA256.hexdigest(key),
      "WALI_CATALOG_CDN_HOST" => "afgxvhhubqzgpijcstsv.supabase.co",
      "WALI_CATALOG_SIGNING_KEY_ID" => "fixture-primary",
      "WALI_CATALOG_SIGNING_PUBLIC_KEY_BASE64" => Base64.strict_encode64("a" * 32),
      "WALI_CATALOG_RECOVERY_SIGNING_KEY_ID" => "fixture-recovery",
      "WALI_CATALOG_RECOVERY_SIGNING_PUBLIC_KEY_BASE64" => Base64.strict_encode64("b" * 32),
      "WALI_LEGAL_BASE_URL" => "https://github.com/CodeWithInferno/WALI/blob/main/docs/legal"
    }
  end
  def with_manifest
    Dir.mktmpdir("wali-production-config-") do |root|
      FileUtils.mkdir_p(File.join(root, "Config"))
      File.write(File.join(root, "Config/Marketplace.production.json"), JSON.generate({"schema_version" => 1, "settings" => settings}))
      yield root
    end
  end
  def resolved(root)
    P.load_manifest(root).fetch("settings").merge("WALI_PRODUCTION_CONFIGURATION_SHA256" => P.manifest_digest(P.load_manifest(root)))
  end
  def info(values)
    P::INFO_KEYS.to_h { |key, field| [field, values.fetch(key)] }
  end
  def test_reviewed_source_resolved_and_app_agent_are_bound
    with_manifest do |root|
      value = resolved(root)
      expected = P.verify_settings!(value, root: root)
      app = info(value)
      agent = P::AGENT_KEYS.to_h { |key| [P::INFO_KEYS.fetch(key), value.fetch(key)] }
      assert_equal "production", expected.fetch("release_mode")
      assert_equal expected, P.verify_bundle_info!(app, agent, root: root)
      assert_equal 64, expected.fetch("production_configuration_sha256").size
      agent["WALICatalogSigningKeyID"] = "substituted"
      assert_raises(RuntimeError) { P.verify_bundle_info!(app, agent, root: root) }
    end
  end
  def test_actual_bundle_plists_and_receipts_cannot_hide_configuration_changes
    with_manifest do |root|
      value = resolved(root)
      app = File.join(root, "WALI.app")
      agent_path = File.join(app, "Contents/Library/LoginItems/WALIAgent.app/Contents")
      FileUtils.mkdir_p(agent_path)
      app_info = File.join(app, "Contents/Info.plist")
      File.write(app_info, JSON.generate(info(value)))
      agent = P::AGENT_KEYS.to_h { |key| [P::INFO_KEYS.fetch(key), value.fetch(key)] }
      File.write(File.join(agent_path, "Info.plist"), JSON.generate(agent))
      assert_equal P.verify_settings!(value, root: root), P.verify_app!(app, root: root)
      changed = info(value).merge("WALIMarketplaceEnabled" => true)
      File.write(app_info, JSON.generate(changed))
      assert_raises(RuntimeError) { P.verify_app!(app, root: root) }
      File.write(app_info, JSON.generate(info(value)))
      agent["WALIMarketplacePublishableKey"] = value.fetch("WALI_SUPABASE_PUBLISHABLE_KEY")
      File.write(File.join(agent_path, "Info.plist"), JSON.generate(agent))
      assert_raises(RuntimeError) { P.verify_app!(app, root: root) }
    end
  end
  def test_release_settings_require_both_resolved_production_targets
    with_manifest do |root|
      value = resolved(root)
      app = {"target" => "WALI", "buildSettings" => value.merge("CONFIGURATION" => "Release")}
      agent_values = P::AGENT_KEYS.to_h { |key| [key, value.fetch(key)] }.merge("CONFIGURATION" => "Release")
      agent = {"target" => "WALIAgent", "buildSettings" => agent_values}
      assert_equal P.verify_settings!(value, root: root), WALIReleaseSupport.verify_direct_release_build_settings!([app, agent], root: root)
      assert_raises(RuntimeError) { WALIReleaseSupport.verify_direct_release_build_settings!([app], root: root) }
      assert_raises(RuntimeError) { WALIReleaseSupport.verify_direct_release_build_settings!([app, agent, agent], root: root) }
      [agent_values.merge("CONFIGURATION" => "Debug"), agent_values.merge("WALI_CATALOG_CDN_HOST" => "staging.example")].each do |changed|
        assert_raises(RuntimeError) { WALIReleaseSupport.verify_direct_release_build_settings!([app, agent.merge("buildSettings" => changed)], root: root) }
      end
    end
  end
  def test_mixed_project_key_trust_and_method_fail
    with_manifest do |root|
      value = resolved(root)
      mutations = {
        "WALI_SUPABASE_URL" => "https://nkwzjuzoyuanjimexulz.supabase.co",
        "WALI_SUPABASE_PROJECT_REF" => "nkwzjuzoyuanjimexulz",
        "WALI_CATALOG_CDN_HOST" => "cdn.example.com",
        "WALI_SUPABASE_PUBLISHABLE_KEY" => "sb_publishable_" + "y" * 32,
        "WALI_CATALOG_SIGNING_PUBLIC_KEY_BASE64" => Base64.strict_encode64("z" * 32),
        "WALI_AUTHENTICATION_METHOD" => "native_apple",
        "WALI_PRODUCTION_CONFIGURATION_SHA256" => "0" * 64
      }
      mutations.each { |key, replacement| assert_raises(RuntimeError, key) { P.verify_settings!(value.merge(key => replacement), root: root) } }
      P::INFO_KEYS.each_key do |key|
        assert_raises(RuntimeError) { P.verify_settings!(value.reject { |name, _| name == key }, root: root) }
        assert_raises(RuntimeError) { P.verify_settings!(value.merge("#{key}[sdk=macosx*]" => value.fetch(key)), root: root) }
      end
    end
  end
  def test_unreviewed_manifest_hosts_and_privileged_inputs_fail
    replacements = {"WALI_SUPABASE_URL" => "https://other.supabase.co", "WALI_CATALOG_CDN_HOST" => "localhost", "WALI_SUPABASE_PUBLISHABLE_KEY" => "sb_secret_private", "WALI_AUTHENTICATION_METHOD" => "browser", "WALI_SUPABASE_PUBLISHABLE_KEY_SHA256" => "0" * 64}
    replacements.each { |key, value| assert_raises(RuntimeError) { P.validate_manifest!({"schema_version" => 1, "settings" => settings.merge(key => value)}) } }
    assert_raises(RuntimeError) { P.validate_manifest!({"schema_version" => 2, "settings" => settings}) }
    assert_raises(RuntimeError) { P.validate_manifest!({"schema_version" => 1, "settings" => settings.merge("SECRET" => "no")}) }
  end
  def test_local_preview_is_explicit_and_never_production
    local = {"WALI_MARKETPLACE_ENABLED" => "NO", "WALI_RELEASE_MODE" => "local_preview", "WALI_AUTHENTICATION_METHOD" => "disabled", "WALI_PRODUCTION_CONFIGURATION_SHA256" => ""}
    assert_equal({"release_mode" => "local_preview", "production_configuration_sha256" => nil}, P.verify_settings!(local, root: "/unused"))
    assert_raises(RuntimeError) { P.verify_settings!(local, root: "/unused", require_production: true) }
    [nil, false, "", "NO ", "no", "$(FLAG)"].each { |flag| assert_raises(RuntimeError) { P.verify_settings!(local.merge("WALI_MARKETPLACE_ENABLED" => flag), root: "/unused") } }
    assert_raises(RuntimeError) { P.verify_settings!(local.merge("WALI_AUTHENTICATION_METHOD" => "native_apple"), root: "/unused") }
  end
  def test_generation_is_bound_to_reviewed_manifest_and_escapes_comments
    with_manifest do |root|
      generated = P.xcconfig(JSON.generate(resolved(root)), root: root)
      refute_includes generated, "//"
      assert_includes generated, "WALI_AUTHENTICATION_METHOD = email_otp"
      assert_raises(RuntimeError) { P.xcconfig(JSON.generate(resolved(root).merge("WALI_CATALOG_SIGNING_KEY_ID" => "other")), root: root) }
    end
  end
end
