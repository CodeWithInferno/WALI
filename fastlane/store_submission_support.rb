# frozen_string_literal: true

require "digest"
require "json"
require "uri"
require_relative "release_support"

module WALIStoreSubmissionSupport
  module_function

  def verify_environment!(environment:, configuration_files:)
    raise "Unset DELIVER_* overrides before using the verified Store lanes" if environment.keys.any? { |key| key.start_with?("DELIVER_") }
    raise "Remove ambient Deliverfile configuration before using the verified Store lanes" if configuration_files.any? { |path| File.exist?(path) }
  end

  def delivery_options(upload:)
    {verify_only: false, edit_live: false, use_live_version: false,
     skip_binary_upload: !upload, skip_metadata: !upload, skip_screenshots: !upload,
     skip_app_version_update: true, submit_for_review: !upload,
     force: true, automatic_release: false, reject_if_possible: false,
     overwrite_screenshots: upload, sync_screenshots: false,
     run_precheck_before_submit: false}
  end

  def verify_editable_version!(version, archive:)
    raise "Create this candidate version without renaming another prepared version" unless version && version.version_string == archive.fetch("version") && version.platform == "MAC_OS"
  end

  def verify_screenshot_scope!(localizations)
    localizations.each do |localization|
      next if localization.locale == "en-US"
      raise "Resolve existing screenshots in other languages before this English-only upload" unless localization.get_app_screenshot_sets.empty?
    end
  end

  def verify_screenshots!(sets, directory:)
    expected = Dir.glob(File.join(directory, "en-US", "*.{png,jpg,jpeg}")).sort.map do |path|
      [Digest::MD5.file(path).hexdigest, File.size(path)]
    end
    raise "Unexpected Store screenshot display type" unless sets.all? { |set| set.screenshot_display_type == "APP_DESKTOP" }
    screenshots = sets.flat_map { |set| set.app_screenshots || [] }
    raise "Store screenshots are still processing or failed" unless screenshots.all? { |shot| shot.asset_delivery_state && shot.asset_delivery_state["state"] == "COMPLETE" }
    actual = screenshots.map { |shot| [shot.source_file_checksum, shot.file_size] }
    raise "App Store screenshots differ from the reviewed files" unless actual == expected
  end

  def verify_encryption!(build, answer:, require_value: false)
    current = build.uses_non_exempt_encryption
    raise "App Store encryption declaration differs from the reviewed answer" unless (!require_value && current.nil?) || current == answer
  end

  def verify_archive!(receipt, payload:, package:, commit:, team:)
    raise "Store archive belongs to different source/team" unless receipt.fetch("source_commit") == commit && receipt.fetch("team_id") == team
    raise "Not an App Store archive" unless receipt.fetch("distribution") == "app_store"
    raise "Missing regular Store package" unless File.file?(package) && !File.symlink?(package)
    raise "Store package changed after archive" unless receipt.fetch("package_sha256") == Digest::SHA256.file(package).hexdigest
    raise "Expected a freshly verified exported Store payload" unless payload.fetch("verified_payload") == "exported_pkg" && payload.fetch("configuration") == "AppStore" && payload.fetch("team_id") == team
    %w[app_sha256 bundle_id version build].each do |key|
      raise "Store payload #{key} changed after archive" unless receipt.fetch(key) == payload.fetch(key)
    end
    raise "Unexpected Store bundle ID" unless receipt.fetch("bundle_id") == "com.wali.store.WALI"
    %w[version build].each do |key|
      raise "Invalid Store #{key}" unless receipt.fetch(key).is_a?(String) && receipt.fetch(key).match?(/\A[0-9]+(?:\.[0-9]+){0,2}\z/)
    end
  end

  def verify_github_release!(release, direct_receipt:, direct_bytes:, directory:, tag:, tag_commit:, store_receipt:)
    raise "Publish the GitHub release before Store upload" unless release.fetch("draft") == false && !release.fetch("published_at").to_s.empty? && release.fetch("tag_name") == tag
    raise "GitHub tag belongs to different source" unless tag_commit == store_receipt.fetch("source_commit")
    %w[source_commit team_id version build].each do |key|
      raise "GitHub release #{key} differs from Store candidate" unless direct_receipt.fetch(key) == store_receipt.fetch(key)
    end
    raise "GitHub release has no app/DMG notarization receipt" unless %w[app dmg].all? { |key| direct_receipt.fetch("notarization").fetch(key).match?(/\A[0-9a-f-]{36}\z/i) }
    paths = WALIReleaseSupport.verify_assets!(direct_receipt, directory: directory)
    expected = WALIReleaseSupport.asset_manifest(paths)
    expected["release.json"] = {"size" => direct_bytes.bytesize, "sha256" => Digest::SHA256.hexdigest(direct_bytes)}
    uploaded = release.fetch("assets").select { |asset| expected.key?(asset.fetch("name")) }
    WALIReleaseSupport.verify_uploaded_assets!(uploaded, expected: expected)
  end

  def required_text(path)
    raise "Missing final metadata file: #{File.basename(path)}" unless File.file?(path) && !File.symlink?(path) && File.size(path).between?(1, 65_536)
    value = File.read(path, encoding: "UTF-8").strip
    raise "Finalize draft metadata before upload" unless value.valid_encoding? && !value.empty? && !value.match?(/\b(?:PENDING|REPLACE|TODO|TBD)\b|example\.invalid/)
    value
  end

  def review_inputs(metadata:, screenshots:, review:)
    [metadata, screenshots].each do |path|
      raise "Missing metadata/screenshots directory" unless File.directory?(path) && !File.symlink?(path)
      Find.find(path) { |entry| raise "Submission directories cannot contain symlinks" if File.symlink?(entry) }
    end
    allowed_root = %w[copyright primary_category secondary_category primary_first_sub_category primary_second_sub_category secondary_first_sub_category secondary_second_sub_category].map { |key| "#{key}.txt" }
    raise "Metadata supports en-US and reviewed category/copyright files only" unless (Dir.children(metadata) - ["en-US"] - allowed_root).empty? && File.directory?(File.join(metadata, "en-US"))
    localized = %w[name subtitle description keywords release_notes support_url marketing_url promotional_text privacy_url].map { |key| "#{key}.txt" }
    raise "Metadata contains unsupported English files or review overrides" unless (Dir.children(File.join(metadata, "en-US")) - localized).empty?
    %w[copyright primary_category].each { |name| required_text(File.join(metadata, "#{name}.txt")) }
    %w[name description keywords support_url privacy_url].each do |name|
      value = required_text(File.join(metadata, "en-US", "#{name}.txt"))
      next unless name.end_with?("_url")
      uri = URI.parse(value)
      raise "Use final public HTTPS support/privacy URLs" unless uri.scheme == "https" && uri.host && !uri.userinfo && !uri.fragment
    end
    Find.find(metadata) { |entry| required_text(entry) if File.file?(entry) }
    raise "Only reviewed en-US screenshots are supported by this release lane" unless Dir.children(screenshots).sort == ["en-US"]
    images = Dir.glob(File.join(screenshots, "en-US", "*.{png,jpg,jpeg}"))
    raise "Screenshot directory contains unreviewed entries" unless Dir.children(File.join(screenshots, "en-US")).sort == images.map { |path| File.basename(path) }.sort
    names = images.map { |path| File.basename(path) }
    raise "Use unique two-digit screenshot prefixes, such as 01-library.png" unless names.all? { |name| name.match?(/\A[0-9]{2}-[A-Za-z0-9][A-Za-z0-9._-]*\.(?:png|jpe?g)\z/) } && names.map { |name| name[0, 2] }.uniq.length == names.length
    raise "Provide 1–10 actual-build English screenshots" unless images.length.between?(1, 10) && images.all? { |path| File.file?(path) && File.size(path).between?(1, 20 * 1024 * 1024) }
    packet = JSON.parse(required_text(review))
    raise "Review packet must contain review and submission information only" unless packet.keys.sort == %w[app_review_information submission_information]
    contact = packet.fetch("app_review_information")
    %w[first_name last_name phone_number email_address notes].each do |key|
      raise "Missing final App Review #{key}" unless contact.fetch(key).is_a?(String) && !contact.fetch(key).strip.empty?
    end
    raise "Invalid App Review contact email" unless contact.fetch("email_address").match?(/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/)
    allowed_contact = %w[first_name last_name phone_number email_address notes demo_user demo_password]
    raise "Unknown App Review field" unless (contact.keys - allowed_contact).empty?
    raise "Provide both review demo credentials or neither" unless contact.key?("demo_user") == contact.key?("demo_password")
    answers = packet.fetch("submission_information")
    required_answers = %w[content_rights_contains_third_party_content export_compliance_uses_encryption]
    raise "Provide explicit reviewed content-rights and encryption answers" unless answers.keys.sort == required_answers && answers.values.all? { |value| value == true || value == false }
    fingerprint = {
      "metadata_sha256" => WALIReleaseSupport.bundle_digest(metadata),
      "screenshots_sha256" => WALIReleaseSupport.bundle_digest(screenshots),
      "review_sha256" => Digest::SHA256.file(review).hexdigest
    }
    [packet, fingerprint]
  end

  def verify_upload!(upload, archive:, fingerprint:, github_release_id:)
    raise "No completed upload for this candidate" unless upload.fetch("status") == "uploaded_not_submitted"
    %w[source_commit team_id app_sha256 package_sha256 bundle_id version build].each do |key|
      raise "Uploaded Store #{key} differs from current candidate" unless upload.fetch(key) == archive.fetch(key)
    end
    raise "GitHub release changed after Store upload" unless upload.fetch("github_release_id") == github_release_id
    raise "Review inputs changed; upload the final metadata again" unless upload.fetch("review_inputs") == fingerprint
  end

  def verify_submission!(submission, items:, version_id:, selected_build_id:, expected_build_id:)
    raise "Apple review submission is not waiting/in review" unless submission && %w[WAITING_FOR_REVIEW IN_REVIEW].include?(submission.state) && submission.platform == "MAC_OS"
    raise "Apple review submission belongs to another version" unless submission.app_store_version_for_review && submission.app_store_version_for_review.id == version_id
    raise "Apple review submission contains unexpected items" unless items.length == 1 && items.first.app_store_version && items.first.app_store_version.id == version_id && [items.first.app_store_version_experiment, items.first.app_store_product_page_version, items.first.app_event].all?(&:nil?)
    raise "Apple selected a different build" unless selected_build_id == expected_build_id
  end

  def verify_processed_build!(build, archive:)
    raise "Uploaded Store build is not ready for review" unless build.processing_state == "VALID" && build.expired == false
    raise "App Store Connect returned a different build" unless build.bundle_id == archive.fetch("bundle_id") && build.app_version == archive.fetch("version") && build.version == archive.fetch("build") && build.platform == "MAC_OS"
  end
end
