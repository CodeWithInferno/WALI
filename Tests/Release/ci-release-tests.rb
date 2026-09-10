#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require "psych"
require_relative "../../scripts/ci-release"

class CIReleaseTests < Minitest::Test
  S = WALICIRelease
  COMMIT = "a" * 40
  TEAM = "ABCDE12345"
  APP_SHA = "b" * 64
  RELEASE_IDS = {
    "APP" => "io.github.codewithinferno.wali.WALI",
    "AGENT" => "io.github.codewithinferno.wali.WALIAgent",
    "HELPER" => "io.github.codewithinferno.wali.WALILockScreenHelper"
  }.freeze
  LEGACY_IDS = {
    "APP" => "com.wali.WALI",
    "AGENT" => "com.wali.WALIAgent",
    "HELPER" => "com.wali.WALILockScreenHelper"
  }.freeze

  def with_environment(values)
    previous = ENV.to_h
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    ENV.replace(previous)
  end

  def policy(name)
    {"id" => 7, "name" => name, "deployment_branch_policy" => {"protected_branches" => false, "custom_branch_policies" => true}, "protection_rules" => [{"type" => "required_reviewers", "prevent_self_review" => false, "reviewers" => [{"type" => "User", "reviewer" => {"id" => 1}}]}]}
  end

  def branches
    {"total_count" => 1, "branch_policies" => [{"name" => "main", "type" => "branch"}]}
  end

  def client
    {"WALI_MARKETPLACE_ENABLED" => "YES", "WALI_SUPABASE_URL" => "https://catalog.example.com", "WALI_SUPABASE_PUBLISHABLE_KEY" => "sb_publishable_#{SecureRandom.hex(20)}", "WALI_CATALOG_CDN_HOST" => "cdn.example.com", "WALI_CATALOG_SIGNING_KEY_ID" => "primary-1", "WALI_CATALOG_SIGNING_PUBLIC_KEY_BASE64" => Base64.strict_encode64("a" * 32), "WALI_CATALOG_RECOVERY_SIGNING_KEY_ID" => "recovery-1", "WALI_CATALOG_RECOVERY_SIGNING_PUBLIC_KEY_BASE64" => Base64.strict_encode64("b" * 32), "WALI_LEGAL_BASE_URL" => "https://example.com/legal"}
  end

  def profile(identifier = RELEASE_IDS.fetch("APP"))
    # Shape of the downloaded Developer ID profiles; values and certificate bytes
    # are synthetic. Native Sign in with Apple is unavailable for this purpose.
    entitlements = {"com.apple.application-identifier" => "#{TEAM}.#{identifier}", "com.apple.developer.team-identifier" => TEAM, "keychain-access-groups" => ["#{TEAM}.*"], "com.apple.security.application-groups" => ["group.com.wali.shared"]}
    {"UUID" => "12345678-1234-1234-1234-123456789ABC", "TeamIdentifier" => [TEAM], "Platform" => ["OSX"], "ProvisionsAllDevices" => true, "ExpirationDate" => "2030-01-01T00:00:00Z", "DeveloperCertificates" => ["fixture certificate bytes"], "Entitlements" => entitlements}
  end

  def verify_profile(value, identifier = RELEASE_IDS.fetch("APP"))
    S.verify_profile(value, identifier: identifier, team: TEAM, certificate_sha256: Digest::SHA256.hexdigest("fixture certificate bytes"), now: Time.utc(2026))
  end

  def test_main_only_environments_allow_the_owner_to_review
    assert_equal 7, S.environment_policy(policy("production"), branches, name: "production", review: true)
    value = policy("release-signing")
    value["protection_rules"] = []
    assert_equal 7, S.environment_policy(value, branches, name: "release-signing", review: false)
  end

  def test_environment_policy_refuses_missing_review_or_wildcards_or_tags
    value = policy("production")
    value["protection_rules"] = []
    assert_raises(RuntimeError) { S.environment_policy(value, branches, name: "production", review: true) }
    [nil, {"protected_branches" => true, "custom_branch_policies" => false}].each do |branch_policy|
      value = policy("production").merge("deployment_branch_policy" => branch_policy)
      assert_raises(RuntimeError) { S.environment_policy(value, branches, name: "production", review: true) }
    end
    [{"name" => "*", "type" => "branch"}, {"name" => "main", "type" => "tag"}].each do |branch|
      assert_raises(RuntimeError) { S.environment_policy(policy("production"), {"total_count" => 1, "branch_policies" => [branch]}, name: "production", review: true) }
    end
  end

  def test_approval_binds_exact_app_digest_and_current_environment
    review = {"state" => "approved", "comment" => "Native review passed: #{APP_SHA}", "environments" => [{"id" => 7, "name" => "production"}]}
    S.verify_review([review], environment_id: 7, digest: APP_SHA)
    [review.merge("state" => "rejected"), review.merge("comment" => "Approved"), review.merge("comment" => "Native review passed: #{'c' * 64}"), review.merge("environments" => [{"id" => 8, "name" => "production"}]), review.merge("environments" => [{"id" => 7, "name" => "release-signing"}])].each do |value|
      assert_raises(RuntimeError) { S.verify_review([value], environment_id: 7, digest: APP_SHA) }
    end
  end

  def test_production_config_is_explicit_and_escapes_xcconfig_comment_delimiters
    text = S.client_config(JSON.generate(client))
    assert_includes text, "WALI_SUPABASE_URL = https:/$()/$()catalog.example.com\n"
    assert_equal 9, text.lines.length
    assert_equal S::CLIENT_KEYS.length, S::CLIENT_INFO_KEYS.length
    value = client
    value["WALI_CATALOG_SIGNING_PUBLIC_KEY_BASE64"] = Base64.strict_encode64("\xff" * 32)
    value["WALI_LEGAL_BASE_URL"] = "https://example.com/legal///version"
    encoded = S.client_config(JSON.generate(value))
    refute_includes encoded, "//"
    key_line = encoded.lines.find { |line| line.start_with?("WALI_CATALOG_SIGNING_PUBLIC_KEY_BASE64 = ") }
    assert_equal value.fetch("WALI_CATALOG_SIGNING_PUBLIC_KEY_BASE64"), key_line.split(" = ", 2).last.strip.gsub("$()", "")
  end

  def test_production_config_refuses_disabled_injected_missing_and_private_inputs
    mutations = [
      ->(v) { v["WALI_MARKETPLACE_ENABLED"] = "NO" },
      ->(v) { v.delete("WALI_CATALOG_RECOVERY_SIGNING_PUBLIC_KEY_BASE64") },
      ->(v) { v["PRIVATE_KEY"] = SecureRandom.hex },
      ->(v) { v["WALI_SUPABASE_PUBLISHABLE_KEY"] = "sb_secret_#{SecureRandom.hex(20)}" },
      ->(v) { v["WALI_SUPABASE_PUBLISHABLE_KEY"] = "eyJhbGciOiJIUzI1NiJ9.fixture.fixture" },
      ->(v) { v["WALI_SUPABASE_URL"] = "https://catalog.example.com\nCODE_SIGNING_ALLOWED = NO" },
      ->(v) { v["WALI_SUPABASE_URL"] = "https://user:password@catalog.example.com" },
      ->(v) { v["WALI_LEGAL_BASE_URL"] = "https://example.com/$(OTHER_SETTING)" },
      ->(v) { v["WALI_LEGAL_BASE_URL"] = "https://example.com/\"/*" },
      ->(v) { v["WALI_CATALOG_RECOVERY_SIGNING_PUBLIC_KEY_BASE64"] = v["WALI_CATALOG_SIGNING_PUBLIC_KEY_BASE64"] },
      ->(v) { v["WALI_CATALOG_SIGNING_PUBLIC_KEY_BASE64"] = Base64.strict_encode64("a" * 64) }
    ]
    mutations.each do |mutation|
      value = client
      mutation.call(value)
      assert_raises(RuntimeError, ArgumentError, URI::InvalidURIError) { S.client_config(JSON.generate(value)) }
    end
  end

  def test_profiles_accept_only_the_exact_approved_direct_release_identities
    assert_equal RELEASE_IDS, S::PROFILE_IDS
    RELEASE_IDS.each do |kind, identifier|
      assert_equal profile(identifier).fetch("UUID"), verify_profile(profile(identifier), S::PROFILE_IDS.fetch(kind))
      rejected_ids = LEGACY_IDS.values + (RELEASE_IDS.values - [identifier]) +
        ["io.github.codewithinferno.wali.*", "io.github.codewithinferno.wali.WALITranscoder", "com.wali.development.WALI", "com.wali.store.WALI", "#{identifier}.other"]
      rejected_ids.each do |other|
        assert_raises(RuntimeError, "#{kind} must reject profile for #{other}") { verify_profile(profile(other), identifier) }
      end
    end
  end

  def test_profile_validator_refuses_legacy_or_unsupported_selected_identities
    (LEGACY_IDS.values + ["io.github.codewithinferno.wali.WALITranscoder", "com.wali.store.WALI"]).each do |identifier|
      assert_raises(RuntimeError, "Unsupported selected identity #{identifier}") { verify_profile(profile(identifier), identifier) }
    end
  end

  def test_downloaded_developer_id_profile_shape_passes_without_native_sign_in_with_apple
    RELEASE_IDS.each_value do |identifier|
      value = profile(identifier)
      assert_equal %w[com.apple.application-identifier com.apple.developer.team-identifier com.apple.security.application-groups keychain-access-groups], value.fetch("Entitlements").keys.sort
      refute value.fetch("Entitlements").key?("com.apple.developer.applesignin")
      assert_equal value.fetch("UUID"), verify_profile(value, identifier)
    end
  end

  def test_profile_checks_team_identity_distribution_expiry_capabilities_and_certificate
    assert_equal profile.fetch("UUID"), verify_profile(profile)
    mutations = [
      ->(v) { v["UUID"] = "../../other" },
      ->(v) { v["TeamIdentifier"] = ["OTHER12345"] },
      ->(v) { v["Platform"] = ["iOS"] },
      ->(v) { v["ProvisionsAllDevices"] = false },
      ->(v) { v["ProvisionedDevices"] = ["device"] },
      ->(v) { v["ExpirationDate"] = "2020-01-01T00:00:00Z" },
      ->(v) { v["DeveloperCertificates"] = ["unrelated certificate"] },
      ->(v) { v["Entitlements"]["com.apple.application-identifier"] = "#{TEAM}.*" },
      ->(v) { v["Entitlements"]["com.apple.developer.team-identifier"] = "OTHER12345" },
      ->(v) { v["Entitlements"]["get-task-allow"] = true },
      ->(v) { v["Entitlements"]["com.apple.security.get-task-allow"] = true },
      ->(v) { v["Entitlements"]["com.apple.security.application-groups"] = [] }
    ]
    RELEASE_IDS.each_value do |identifier|
      mutations.each do |mutation|
        value = profile(identifier)
        mutation.call(value)
        assert_raises(RuntimeError) { verify_profile(value, identifier) }
      end
    end
  end

  def test_dispatch_refuses_reused_attempts_foreign_source_prs_and_tag_injection
    Dir.mktmpdir("wali-ci-context-") do |root|
      FileUtils.mkdir_p(File.join(root, "Config"))
      FileUtils.mkdir_p(File.join(root, "docs/release/notes"))
      File.write(File.join(root, "Config/Base.xcconfig"), "MARKETING_VERSION = 0.1.0\nCURRENT_PROJECT_VERSION = 1\n")
      File.write(File.join(root, "docs/release/notes/v0.1.0.md"), "Reviewed release notes\n")
      env = {"GITHUB_ACTIONS" => "true", "RUNNER_ENVIRONMENT" => "github-hosted", "GITHUB_REPOSITORY" => S::REPOSITORY, "GITHUB_EVENT_NAME" => "workflow_dispatch", "GITHUB_REF" => "refs/heads/main", "GITHUB_RUN_ATTEMPT" => "1", "GITHUB_RUN_ID" => "123", "GITHUB_SHA" => COMMIT, "GITHUB_WORKSPACE" => root, "WALI_RELEASE_TAG" => "v0.1.0"}
      WALIReleaseSupport.stub(:source_commit, COMMIT) do
        S.stub(:committed_notes?, true) do
        assert_equal "0.1.0", S.context(env, root: root).fetch("version")
        {"RUNNER_ENVIRONMENT" => "self-hosted", "GITHUB_REPOSITORY" => "fork/WALI", "GITHUB_REF" => "refs/heads/unreviewed", "GITHUB_EVENT_NAME" => "pull_request", "GITHUB_RUN_ATTEMPT" => "2", "GITHUB_SHA" => "f" * 40, "WALI_RELEASE_TAG" => "v0.1.0;touch /tmp/injected", "ACTIONS_STEP_DEBUG" => "true", "RUNNER_DEBUG" => "1"}.each do |key, value|
          assert_raises(RuntimeError) { S.context(env.merge(key => value), root: root) }
        end
        end
        File.unlink(File.join(root, "docs/release/notes/v0.1.0.md"))
        assert_raises(RuntimeError) { S.context(env, root: root) }
      end
    end
  end

  def test_transport_fails_closed_for_swaps_foreign_receipts_and_unexpected_entries
    Dir.mktmpdir("wali-ci-transport-") do |directory|
      archive = File.join(directory, "WALI-candidate.zip")
      receipt = File.join(directory, "archive.json")
      File.write(archive, "signed candidate transport fixture")
      value = {"source_commit" => COMMIT, "team_id" => TEAM, "app_sha256" => APP_SHA}
      File.write(receipt, JSON.generate(value))
      arguments = {archive_sha: Digest::SHA256.file(archive).hexdigest, receipt_sha: Digest::SHA256.file(receipt).hexdigest, app_sha: APP_SHA, input: {"source_commit" => COMMIT}}
      with_environment("DEVELOPMENT_TEAM" => TEAM) do
        assert_equal value, S.verify_transport(directory, **arguments)
        File.write(archive, "replacement")
        assert_raises(RuntimeError) { S.verify_transport(directory, **arguments) }
        arguments[:archive_sha] = Digest::SHA256.file(archive).hexdigest
        File.write(receipt, JSON.generate(value.merge("source_commit" => "f" * 40)))
        arguments[:receipt_sha] = Digest::SHA256.file(receipt).hexdigest
        assert_raises(RuntimeError) { S.verify_transport(directory, **arguments) }
        File.write(receipt, JSON.generate(value))
        arguments[:receipt_sha] = Digest::SHA256.file(receipt).hexdigest
        File.write(File.join(directory, "unexpected"), "extra")
        assert_raises(RuntimeError) { S.verify_transport(directory, **arguments) }
        File.unlink(File.join(directory, "unexpected"))
        File.unlink(archive)
        File.symlink(receipt, archive)
        assert_raises(RuntimeError) { S.verify_transport(directory, **arguments) }
      end
    end
  end

  def test_partial_signing_setup_cleans_keychain_without_logging_secret_arguments
    Dir.mktmpdir("wali-ci-cleanup-") do |temporary|
      directory = File.join(temporary, "wali-ci-release-signing")
      commands = []
      fake = lambda do |*args, **_options|
        commands << args
        case args[1]
        when "default-keychain" then '"/tmp/Original Keychain.keychain-db"'
        when "list-keychains" then '"/tmp/Original Keychain.keychain-db" "/tmp/Second Keychain.keychain-db"'
        when "create-keychain" then File.write(args.last, "temporary fixture")
        when "import" then raise "injected import failure"
        when "delete-keychain" then File.unlink(args.last)
        else ""
        end
      end
      with_environment("RUNNER_TEMP" => temporary, "DEVELOPMENT_TEAM" => TEAM, "WALI_SIGNING_P12_BASE64" => Base64.strict_encode64("fixture"), "WALI_SIGNING_P12_PASSWORD" => SecureRandom.hex) do
        S.stub(:run, fake) do
          assert_raises(RuntimeError) { S.with_signing(candidate: true) { flunk "failed import must not reach build" } }
        end
        refute File.exist?(directory)
        refute ENV.key?("WALI_SIGNING_P12_PASSWORD")
        assert commands.any? { |args| args[1] == "delete-keychain" }
      end
    end
  end

  def test_cleanup_restores_full_argv_and_retries_after_restore_failure
    Dir.mktmpdir("wali-ci-journal-") do |temporary|
      with_environment("RUNNER_TEMP" => temporary) do
        directory = S.state_directory
        Dir.mkdir(directory)
        keychain = File.join(directory, "signing.keychain-db")
        File.write(keychain, "fixture")
        original = "/tmp/Original Keychain.keychain-db"
        search = [original, "/tmp/Second Keychain.keychain-db"]
        S.save_state({"default" => original, "search" => search, "owned" => [], "keychains_changed" => true})
        calls = []
        fail_once = true
        fake = lambda do |*args, **_options|
          calls << args
          if args[1] == "default-keychain" && fail_once
            fail_once = false
            raise "injected restore failure"
          end
          File.unlink(args.last) if args[1] == "delete-keychain" && File.exist?(args.last)
          ""
        end
        S.stub(:run, fake) do
          assert_raises(RuntimeError) { S.cleanup }
          assert File.file?(File.join(directory, "state.json"))
          S.cleanup
        end
        assert_includes calls, ["/usr/bin/security", "default-keychain", "-d", "user", "-s", original]
        assert_includes calls, ["/usr/bin/security", "list-keychains", "-d", "user", "-s", *search]
        refute File.exist?(directory)
      end
    end
  end

  def test_existing_signing_material_is_never_overwritten
    Dir.mktmpdir("wali-ci-exclusive-") do |temporary|
      path = File.join(temporary, "profile")
      File.write(path, "original")
      assert_raises(RuntimeError) { S.owned_write(path, "new", {"owned" => []}) }
      assert_equal "original", File.read(path)
      File.symlink(path, File.join(temporary, "link"))
      assert_raises(RuntimeError) { S.owned_write(File.join(temporary, "link"), "new", {"owned" => []}) }
    end
  end

  def test_workflow_has_no_pr_trigger_or_dynamic_commands_and_only_publish_can_write
    workflow = Psych.load_file(File.expand_path("../../.github/workflows/release.yml", __dir__))
    triggers = workflow["on"] || workflow[true]
    assert_equal ["workflow_dispatch"], triggers.keys
    assert_equal ["tag"], triggers.fetch("workflow_dispatch").fetch("inputs").keys
    assert_equal "read", workflow.fetch("permissions").fetch("contents")
    jobs = workflow.fetch("jobs")
    assert_equal "write", jobs.fetch("publish").fetch("permissions").fetch("contents")
    assert_equal "release-signing", jobs.fetch("candidate").fetch("environment")
    assert_equal "production", jobs.fetch("publish").fetch("environment").fetch("name")
    jobs.each_value do |job|
      job.fetch("steps").each do |step|
        assert_match(/@[0-9a-f]{40}\z/, step["uses"]) if step["uses"]
        refute_match(/\$\{\{/, step.fetch("run", ""))
        if step["uses"].to_s.start_with?("actions/checkout@")
          assert_equal false, step.fetch("with").fetch("persist-credentials")
          assert_equal "${{ github.sha }}", step.fetch("with").fetch("ref")
        end
      end
    end
    download = jobs.fetch("publish").fetch("steps").find { |step| step["uses"].to_s.start_with?("actions/download-artifact@") }
    assert_equal "${{ needs.candidate.outputs.artifact_id }}", download.fetch("with").fetch("artifact-ids")
    refute download.fetch("with").key?("run-id")
    %w[candidate publish].each do |name|
      cleanup = jobs.fetch(name).fetch("steps").find { |step| step["run"].to_s.end_with?("ci-release.rb cleanup") }
      assert_equal "always()", cleanup.fetch("if")
    end
  end
end
