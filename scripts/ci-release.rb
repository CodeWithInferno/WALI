#!/usr/bin/env ruby
# frozen_string_literal: true

# This adapter owns hosted-runner transport and temporary credentials only.
# Build, signing validation, notarization, and publication stay in Fastlane.
require "base64"
require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "openssl"
require "rexml/document"
require "securerandom"
require "shellwords"
require "time"
require "uri"
require_relative "../fastlane/release_support"

module WALICIRelease
  REPOSITORY = "CodeWithInferno/WALI"
  ROOT = File.expand_path("..", __dir__)
  TEAM_PATTERN = /\A[A-Z0-9]{10}\z/
  SHA_PATTERN = /\A[0-9a-f]{64}\z/
  PROFILE_IDS = {
    "APP" => "io.github.codewithinferno.wali.WALI",
    "AGENT" => "io.github.codewithinferno.wali.WALIAgent",
    "HELPER" => "io.github.codewithinferno.wali.WALILockScreenHelper"
  }.freeze
  CLIENT_KEYS = WALIProductionConfig::INFO_KEYS.keys.freeze
  CLIENT_INFO_KEYS = WALIProductionConfig::INFO_KEYS.values.freeze
  SECRET_KEYS = %w[WALI_SIGNING_P12_BASE64 WALI_SIGNING_P12_PASSWORD WALI_APP_PROFILE_BASE64 WALI_AGENT_PROFILE_BASE64 WALI_HELPER_PROFILE_BASE64 WALI_NOTARY_KEY_BASE64].freeze
  module_function

  def demand(condition, message)
    raise message unless condition
  end

  def run(*arguments, quiet: false, environment: {})
    if quiet
      out, _err, status = Open3.capture3(environment, *arguments)
      demand(status.success?, "Required #{File.basename(arguments.first)} operation failed; private output suppressed")
      out
    else
      demand(system(environment, *arguments), "Required #{File.basename(arguments.first)} operation failed")
    end
  end

  def api(path, optional: false)
    token = ENV.fetch("GH_TOKEN")
    demand(!token.empty?, "Missing ephemeral GitHub token")
    uri = URI("https://api.github.com/repos/#{REPOSITORY}/#{path}")
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{token}"
    request["Accept"] = "application/vnd.github+json"
    request["X-GitHub-Api-Version"] = "2022-11-28"
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 20, read_timeout: 60) { |http| http.request(request) }
    return nil if optional && response.code == "404"
    demand(response.code == "200", "GitHub prerequisite failed with HTTP #{response.code}")
    demand(response.body.bytesize <= 8 * 1024 * 1024, "GitHub prerequisite response exceeds bound")
    JSON.parse(response.body)
  end

  def committed_notes?(root, relative, commit)
    _output, status = Open3.capture2e("git", "-C", root, "cat-file", "-e", "#{commit}:#{relative}")
    status.success?
  end

  def context(env = ENV, root: ROOT)
    root = File.realpath(root)
    demand(env["GITHUB_ACTIONS"] == "true" && env["RUNNER_ENVIRONMENT"] == "github-hosted", "Use a fresh GitHub-hosted runner")
    demand(env["GITHUB_REPOSITORY"] == REPOSITORY && env["GITHUB_EVENT_NAME"] == "workflow_dispatch" && env["GITHUB_REF"] == "refs/heads/main", "Release only from a manual main dispatch in the canonical repository")
    demand(env["GITHUB_RUN_ATTEMPT"] == "1", "Do not rerun release jobs; dispatch a new candidate after reconciling any draft release")
    demand(env.fetch("GITHUB_RUN_ID", "").match?(/\A[1-9][0-9]*\z/), "Invalid workflow run")
    demand(env.fetch("GITHUB_SHA", "").match?(/\A[0-9a-f]{40}\z/), "Invalid workflow commit")
    demand(env.fetch("WALI_RELEASE_TAG", "").match?(/\Av[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*)?\z/) && env["WALI_RELEASE_TAG"].bytesize <= 100, "Use a version tag such as v0.1.0 or v0.1.0-beta.1")
    demand(env["RUNNER_DEBUG"] != "1" && !%w[ACTIONS_STEP_DEBUG ACTIONS_RUNNER_DEBUG].any? { |key| env[key] == "true" }, "Release credential steps forbid debug logging")
    demand(File.realpath(env.fetch("GITHUB_WORKSPACE")) == File.realpath(root), "Unexpected checkout root")
    commit = WALIReleaseSupport.source_commit(root)
    demand(commit == env["GITHUB_SHA"], "Checkout does not match the dispatched commit")
    notes = File.join(root, "docs", "release", "notes", "#{env['WALI_RELEASE_TAG']}.md")
    demand(File.file?(notes) && File.realpath(notes) == notes && File.size(notes).between?(1, 128 * 1024), "Commit nonempty versioned release notes at docs/release/notes/TAG.md before dispatch")
    demand(committed_notes?(root, notes.delete_prefix("#{root}/"), commit), "Release notes must be present in the dispatched commit")
    text = File.read(notes, encoding: "UTF-8")
    demand(text.valid_encoding? && !text.strip.empty?, "Release notes must be nonempty UTF-8")
    version = File.read(File.join(root, "Config", "Base.xcconfig")).match(/^MARKETING_VERSION = ([0-9]+\.[0-9]+\.[0-9]+)$/)&.captures&.first
    build = File.read(File.join(root, "Config", "Base.xcconfig")).match(/^CURRENT_PROJECT_VERSION = ([1-9][0-9]*)$/)&.captures&.first
    demand(version && build && env["WALI_RELEASE_TAG"].match?(/\Av#{Regexp.escape(version)}(?:-|\z)/), "Commit the version and build in Base.xcconfig before dispatch")
    {"source_commit" => commit, "version" => version, "build" => build, "tag" => env["WALI_RELEASE_TAG"], "notes" => notes}
  end

  def environment_policy(environment, branches, name:, review:)
    demand(environment["name"] == name && environment["id"].is_a?(Integer), "Missing expected release environment")
    demand(environment["deployment_branch_policy"] == {"protected_branches" => false, "custom_branch_policies" => true}, "#{name} must use a selected main-only deployment branch policy")
    rules = branches.fetch("branch_policies")
    demand(branches["total_count"] == 1 && rules.length == 1 && rules.first["name"] == "main" && rules.first["type"] == "branch", "#{name} must allow only the main branch, with no tag or wildcard rules")
    if review
      required = environment.fetch("protection_rules").select { |rule| rule["type"] == "required_reviewers" }
      demand(required.length == 1 && required.first.fetch("reviewers").any?, "production needs a configured required reviewer; the owner may fill this role")
    end
    environment.fetch("id")
  end

  def preflight
    input = context
    demand(api("commits/main").fetch("sha") == input.fetch("source_commit"), "Main moved; dispatch a new candidate from current main")
    WALIReleaseSupport.verify_ci!(api("commits/#{input.fetch('source_commit')}/check-runs?filter=latest&per_page=100").fetch("check_runs"), commit: input.fetch("source_commit"))
    workflow = api("actions/runs/#{ENV.fetch('GITHUB_RUN_ID')}")
    demand(workflow["head_sha"] == input.fetch("source_commit") && workflow["head_branch"] == "main" && workflow["event"] == "workflow_dispatch" && workflow["run_attempt"] == 1 && workflow["path"] == ".github/workflows/release.yml", "Unexpected release workflow identity")
    %w[release-signing production].each do |name|
      id = environment_policy(api("environments/#{name}"), api("environments/#{name}/deployment-branch-policies?per_page=100"), name: name, review: name == "production")
      input["production_environment_id"] = id if name == "production"
    end
    demand(api("releases/tags/#{input.fetch('tag')}", optional: true).nil?, "A release already exists for this tag; inspect it rather than overwrite or resume automatically")
    input
  end

  def verify_review(history, environment_id:, digest:)
    demand(digest.match?(SHA_PATTERN), "Invalid reviewed app digest")
    expected = "Native review passed: #{digest}"
    approved = history.any? do |review|
      review["state"] == "approved" && review["comment"].to_s.strip == expected && review.fetch("environments", []).any? { |item| item["id"] == environment_id && item["name"] == "production" }
    end
    demand(approved, "Production approval must include exactly: #{expected}")
  end

  def client_config(text, root: ROOT)
    WALIProductionConfig.xcconfig(text, root: root)
  end

  def plist_value(element)
    case element.name
    when "dict"
      children = element.elements.to_a
      demand(children.length.even?, "Malformed profile dictionary")
      children.each_slice(2).to_h { |key, value| demand(key.name == "key", "Malformed profile key"); [key.text.to_s, plist_value(value)] }
    when "array" then element.elements.map { |item| plist_value(item) }
    when "string", "date" then element.text.to_s
    when "data" then Base64.strict_decode64(element.text.to_s.gsub(/\s/, ""))
    when "integer" then Integer(element.text)
    when "true" then true
    when "false" then false
    else raise "Unsupported provisioning value"
    end
  end

  def profile_metadata(xml)
    demand(xml.bytesize <= 2 * 1024 * 1024, "Profile exceeds bound")
    demand(!xml.include?("<!ENTITY"), "Profile entity definitions are forbidden")
    plist_value(REXML::Document.new(xml).elements["plist/dict"])
  end

  def verify_profile(data, identifier:, team:, certificate_sha256:, now: Time.now)
    demand(PROFILE_IDS.value?(identifier), "Unsupported direct Release profile identity")
    demand(data["UUID"].to_s.match?(/\A[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}\z/), "Invalid profile UUID")
    demand(data["TeamIdentifier"] == [team] && data.fetch("Platform", []).include?("OSX") && data["ProvisionsAllDevices"] == true && !data.key?("ProvisionedDevices"), "Require a Developer ID macOS profile for the selected team")
    demand(Time.iso8601(data.fetch("ExpirationDate")) > now + 86_400, "Profile expires within one day")
    entitlements = data.fetch("Entitlements")
    demand(entitlements["com.apple.application-identifier"] == "#{team}.#{identifier}" && entitlements["com.apple.developer.team-identifier"] == team && entitlements["get-task-allow"] != true && entitlements["com.apple.security.get-task-allow"] != true, "Profile app identity or distribution entitlement differs")
    demand(entitlements.fetch("com.apple.security.application-groups", []).include?("group.com.wali.shared"), "Profile must authorize the direct shared app group")
    demand(data.fetch("DeveloperCertificates", []).any? { |der| Digest::SHA256.hexdigest(der) == certificate_sha256 }, "Profile does not authorize the imported signing certificate")
    data.fetch("UUID")
  end

  def append_output(key, value)
    demand(key.match?(/\A[a-z_]+\z/) && value.to_s.match?(/\A[A-Za-z0-9._-]+\z/), "Invalid workflow output")
    File.open(ENV.fetch("GITHUB_OUTPUT"), "a") { |file| file.puts("#{key}=#{value}") }
  end

  def state_directory
    base = File.realpath(ENV.fetch("RUNNER_TEMP"))
    File.join(base, "wali-ci-release-signing")
  end

  def save_state(state)
    path = File.join(state_directory, "state.json")
    File.write("#{path}.new", JSON.generate(state), perm: 0o600)
    File.rename("#{path}.new", path)
  end

  def cleanup
    directory = state_directory
    return unless File.exist?(directory)
    demand(!File.symlink?(directory), "Refusing symbolic-link cleanup directory")
    path = File.join(directory, "state.json")
    demand(File.file?(path) && !File.symlink?(path), "Missing signing cleanup journal")
    state = JSON.parse(File.read(path))
    keychain = File.join(directory, "signing.keychain-db")
    errors = []
    if state["keychains_changed"]
      [["default-keychain", "-d", "user", "-s", state.fetch("default")], ["list-keychains", "-d", "user", "-s", *state.fetch("search")]].each do |arguments|
        begin
          run("/usr/bin/security", *arguments, quiet: true)
        rescue StandardError
          errors << "restore keychain settings"
        end
      end
    end
    state.fetch("owned", []).each do |file|
      config = ["Signing.local.xcconfig", "Marketplace.production.local.xcconfig"].map { |name| File.join(ROOT, "Config", name) }
      profile_root = File.join(Dir.home, "Library/Developer/Xcode/UserData/Provisioning Profiles")
      valid_profile = File.dirname(file) == profile_root && File.basename(file).match?(/\A[A-Fa-f0-9-]{36}\.provisionprofile\z/)
      demand(config.include?(file) || valid_profile, "Unexpected cleanup target")
      File.unlink(file) if File.file?(file) || File.symlink?(file)
    end
    if errors.empty? && File.exist?(keychain)
      begin
        run("/usr/bin/security", "delete-keychain", keychain, quiet: true)
      rescue StandardError
        errors << "delete temporary keychain"
      end
    end
    # Retain the journal on failure so the always() cleanup step can retry.
    demand(errors.empty?, "Signing cleanup needs another attempt: #{errors.uniq.join(', ')}")
    FileUtils.remove_entry_secure(directory)
  end

  def owned_write(path, bytes, state)
    demand(!File.exist?(path) && !File.symlink?(path), "Refusing to replace existing signing/configuration material")
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      state.fetch("owned") << path
      save_state(state)
      file.write(bytes)
    end
  end

  def decode_secret(name, limit:)
    encoded = ENV.fetch(name)
    demand(encoded.bytesize <= limit * 2, "Signing material exceeds bound")
    data = Base64.strict_decode64(encoded)
    demand(data.bytesize.between?(1, limit), "Signing material size is invalid")
    data
  end

  def with_signing(candidate:)
    team = ENV.fetch("DEVELOPMENT_TEAM", "")
    demand(team.match?(TEAM_PATTERN), "Configure the approved ten-character team identifier")
    directory = state_directory
    demand(!File.exist?(directory) && !File.symlink?(directory), "Stale signing state; cleanup before a new run")
    defaults = Shellwords.split(run("/usr/bin/security", "default-keychain", "-d", "user", quiet: true))
    search = Shellwords.split(run("/usr/bin/security", "list-keychains", "-d", "user", quiet: true))
    demand(defaults.length == 1 && !search.empty?, "Cannot preserve runner keychain settings")
    Dir.mkdir(directory, 0o700)
    state = {"default" => defaults.first, "search" => search, "owned" => [], "keychains_changed" => false}
    save_state(state)
    begin
      keychain = File.join(directory, "signing.keychain-db")
      password = SecureRandom.hex(32)
      p12 = File.join(directory, "signing.p12")
      File.write(p12, decode_secret("WALI_SIGNING_P12_BASE64", limit: 1024 * 1024), perm: 0o600)
      run("/usr/bin/security", "create-keychain", "-p", password, keychain, quiet: true)
      run("/usr/bin/security", "set-keychain-settings", "-u", "-t", "14400", keychain, quiet: true)
      run("/usr/bin/security", "unlock-keychain", "-p", password, keychain, quiet: true)
      run("/usr/bin/security", "import", p12, "-k", keychain, "-P", ENV.fetch("WALI_SIGNING_P12_PASSWORD"), "-T", "/usr/bin/codesign", "-T", "/usr/bin/security", quiet: true)
      File.unlink(p12)
      run("/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, keychain, quiet: true)
      identities = run("/usr/bin/security", "find-identity", "-v", "-p", "codesigning", keychain, quiet: true).scan(/\b([A-Fa-f0-9]{40}) "(Developer ID Application: [^"\r\n]+ \([A-Z0-9]{10}\))"/)
      demand(identities.length == 1 && identities.first.last.end_with?("(#{team})"), "Import exactly one valid Developer ID Application identity for the selected team")
      identity_sha, identity = identities.first
      certificates = run("/usr/bin/security", "find-certificate", "-a", "-p", keychain, quiet: true).scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m).map { |pem| OpenSSL::X509::Certificate.new(pem) }
      certificate = certificates.find { |cert| Digest::SHA1.hexdigest(cert.to_der).casecmp(identity_sha).zero? }
      demand(certificate && certificate.not_after > Time.now + 86_400, "Signing certificate is missing or expires within one day")
      state["keychains_changed"] = true
      save_state(state)
      run("/usr/bin/security", "list-keychains", "-d", "user", "-s", keychain, *search, quiet: true)
      run("/usr/bin/security", "default-keychain", "-d", "user", "-s", keychain, quiet: true)
      signing = "WALI_DEVELOPMENT_TEAM = #{team}\n"
      if candidate
        profile_root = File.join(Dir.home, "Library/Developer/Xcode/UserData/Provisioning Profiles")
        FileUtils.mkdir_p(profile_root)
        demand(!File.symlink?(profile_root), "Profile directory cannot be a symbolic link")
        PROFILE_IDS.each do |kind, identifier|
          profile = File.join(directory, "#{kind}.provisionprofile")
          bytes = decode_secret("WALI_#{kind}_PROFILE_BASE64", limit: 1024 * 1024)
          File.write(profile, bytes, perm: 0o600)
          metadata = profile_metadata(run("/usr/bin/security", "cms", "-D", "-i", profile, quiet: true))
          uuid = verify_profile(metadata, identifier: identifier, team: team, certificate_sha256: Digest::SHA256.hexdigest(certificate.to_der))
          owned_write(File.join(profile_root, "#{uuid}.provisionprofile"), bytes, state)
          signing += "WALI_#{kind}_PROVISIONING_PROFILE = #{uuid}\n"
        end
        owned_write(File.join(ROOT, "Config/Signing.local.xcconfig"), signing, state)
        owned_write(File.join(ROOT, "Config/Marketplace.production.local.xcconfig"), client_config(ENV.fetch("WALI_MARKETPLACE_CONFIG_JSON")), state)
      else
        private_key = File.join(directory, "AuthKey.p8")
        File.write(private_key, decode_secret("WALI_NOTARY_KEY_BASE64", limit: 16 * 1024), perm: 0o600)
        key_id = ENV.fetch("WALI_NOTARY_KEY_ID", "")
        issuer = ENV.fetch("WALI_NOTARY_ISSUER_ID", "")
        demand(key_id.match?(/\A[A-Z0-9]{10}\z/) && issuer.match?(/\A[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z/), "Configure a Team App Store Connect API key ID and issuer")
        profile = "wali-ci-#{ENV.fetch('GITHUB_RUN_ID')}"
        run("/usr/bin/xcrun", "notarytool", "store-credentials", profile, "--key", private_key, "--key-id", key_id, "--issuer", issuer, "--keychain", keychain, quiet: true)
        File.unlink(private_key)
        ENV["WALI_NOTARY_KEYCHAIN_PROFILE"] = profile
      end
      SECRET_KEYS.each { |key| ENV.delete(key) }
      ENV["WALI_CODE_SIGN_IDENTITY"] = identity
      yield
    ensure
      SECRET_KEYS.each { |key| ENV.delete(key) }
      cleanup
    end
  end

  def bundle_identity(app, input)
    %w[CFBundleShortVersionString CFBundleVersion].zip(%w[version build]).each do |key, field|
      value = run("/usr/bin/plutil", "-extract", key, "raw", "-o", "-", File.join(app, "Contents/Info.plist"), quiet: true).strip
      demand(value == input.fetch(field), "Signed candidate version/build differs from committed source")
    end
    wrappers = [app, File.join(app, "Contents/Library/LoginItems/WALIAgent.app"), File.join(app, "Contents/Library/LoginItems/WALILockScreenHelper.app"), File.join(app, "Contents/Library/LoginItems/WALIAgent.app/Contents/XPCServices/WALITranscoder.xpc")]
    wrappers.each do |wrapper|
      output, error, status = Open3.capture3("/usr/bin/codesign", "-dvv", wrapper)
      demand(status.success? && (output + error).lines.include?("TeamIdentifier=#{ENV.fetch('DEVELOPMENT_TEAM')}\n"), "Signed wrapper belongs to a different team")
    end
  end

  def candidate
    input = preflight
    transport = File.join(ROOT, ".build/ci-release/candidate")
    demand(!File.exist?(File.join(ROOT, ".build/release")) && !File.exist?(transport), "Candidate job needs fresh build and transport directories")
    with_signing(candidate: true) do
      run("bundle", "exec", "fastlane", "mac", "archive", environment: {"GH_TOKEN" => nil, "GITHUB_TOKEN" => nil, "GITHUB_API_TOKEN" => nil})
      app = File.join(ROOT, ".build/release/candidate/WALI.app")
      receipt_path = File.join(ROOT, ".build/release/archive.json")
      receipt = JSON.parse(File.read(receipt_path))
      WALIReleaseSupport.verify_archive!(receipt, app: app, root: ROOT)
      demand(receipt["team_id"] == ENV.fetch("DEVELOPMENT_TEAM"), "Archive receipt team differs")
      bundle_identity(app, input)
      # Verify the archived client actually contains each reviewed public value.
      expected_client = JSON.parse(ENV.fetch("WALI_MARKETPLACE_CONFIG_JSON"))
      CLIENT_KEYS.zip(CLIENT_INFO_KEYS).each do |key, info_key|
        actual = run("/usr/bin/plutil", "-extract", info_key, "raw", "-o", "-", File.join(app, "Contents/Info.plist"), quiet: true).strip
        demand(actual == expected_client.fetch(key), "Archived production client configuration differs from the reviewed inputs")
      end
      FileUtils.mkdir_p(transport)
      archive = File.join(transport, "WALI-candidate.zip")
      run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)
      FileUtils.cp(receipt_path, File.join(transport, "archive.json"))
      sha = Digest::SHA256.file(archive).hexdigest
      receipt_sha = Digest::SHA256.file(receipt_path).hexdigest
      append_output("archive_sha", sha)
      append_output("receipt_sha", receipt_sha)
      append_output("app_sha", receipt.fetch("app_sha256"))
      File.open(ENV.fetch("GITHUB_STEP_SUMMARY"), "a") do |file|
        file.puts("Signed candidate for `#{input.fetch('tag')}` from `#{input.fetch('source_commit')}`.\n\nApp digest: `#{receipt.fetch('app_sha256')}`\n\nTransport ZIP digest: `#{sha}`\n\nDownload this run's candidate artifact, verify the ZIP digest, and complete the native journeys in docs/release/fastlane.md. This candidate is not yet notarized or published. To approve production after those journeys pass, use this exact review comment:\n\n`Native review passed: #{receipt.fetch('app_sha256')}`")
      end
    end
  end

  def verify_transport(directory, archive_sha:, receipt_sha:, app_sha:, input:)
    demand([archive_sha, receipt_sha, app_sha].all? { |sha| sha.match?(SHA_PATTERN) }, "Missing candidate job digests")
    demand(File.directory?(directory) && !File.symlink?(directory) && Dir.children(directory).sort == %w[WALI-candidate.zip archive.json], "Candidate transport contains unexpected entries")
    {"WALI-candidate.zip" => archive_sha, "archive.json" => receipt_sha}.each do |name, sha|
      path = File.join(directory, name)
      demand(File.file?(path) && !File.symlink?(path) && Digest::SHA256.file(path).hexdigest == sha, "Candidate transport was replaced or damaged")
    end
    receipt = JSON.parse(File.read(File.join(directory, "archive.json")))
    demand(receipt["source_commit"] == input.fetch("source_commit") && receipt["team_id"] == ENV.fetch("DEVELOPMENT_TEAM") && receipt["app_sha256"] == app_sha, "Candidate receipt belongs to another source, team, or app")
    receipt
  end

  def publish
    input = preflight
    directory = File.join(ROOT, ".build/ci-release/download")
    receipt = verify_transport(directory, archive_sha: ENV.fetch("WALI_CANDIDATE_ARCHIVE_SHA"), receipt_sha: ENV.fetch("WALI_CANDIDATE_RECEIPT_SHA"), app_sha: ENV.fetch("WALI_CANDIDATE_APP_SHA"), input: input)
    verify_review(api("actions/runs/#{ENV.fetch('GITHUB_RUN_ID')}/approvals"), environment_id: input.fetch("production_environment_id"), digest: receipt.fetch("app_sha256"))
    release = File.join(ROOT, ".build/release")
    demand(!File.exist?(release), "Publish job needs a fresh release directory")
    FileUtils.mkdir_p(File.join(release, "candidate"))
    # ZIP bytes are hard-bound to our same-run signed candidate before extraction.
    run("/usr/bin/ditto", "-x", "-k", File.join(directory, "WALI-candidate.zip"), File.join(release, "candidate"))
    FileUtils.cp(File.join(directory, "archive.json"), File.join(release, "archive.json"))
    app = File.join(release, "candidate/WALI.app")
    WALIReleaseSupport.verify_archive!(receipt, app: app, root: ROOT)
    bundle_identity(app, input)
    run("./scripts/verify-bundle.sh", app, environment: {"CONFIGURATION" => "Release"})
    with_signing(candidate: false) do
      run("bundle", "exec", "fastlane", "mac", "notarize_candidate", environment: {"GH_TOKEN" => nil, "GITHUB_TOKEN" => nil, "GITHUB_API_TOKEN" => nil})
      # github_release repeats clean-source, current-main, CI, signature,
      # notarization, exact asset/sidecar, tag, and remote upload digest checks.
      run("bundle", "exec", "fastlane", "mac", "github_release", "tag:#{input.fetch('tag')}", "notes:#{input.fetch('notes')}", environment: {"GITHUB_API_TOKEN" => ENV.fetch("GH_TOKEN"), "GH_TOKEN" => nil})
    end
  end

  def main(arguments)
    demand(arguments.length == 1 && %w[preflight candidate publish cleanup].include?(arguments.first), "Use preflight, candidate, publish, or cleanup")
    Dir.chdir(ROOT) { send(arguments.first) }
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    WALICIRelease.main(ARGV)
  rescue StandardError => error
    # No exception inspect/backtrace: command arguments may contain credentials.
    warn "Release stopped: #{error.is_a?(RuntimeError) ? error.message : error.class}"
    exit 1
  end
end
