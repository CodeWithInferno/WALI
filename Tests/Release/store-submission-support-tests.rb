#!/usr/bin/env ruby
# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require_relative "../../fastlane/store_submission_support"

$count = 0
def reject_case(name)
  begin
    yield
  rescue RuntimeError, KeyError, Errno::ENOENT
    $count += 1
    return
  end
  raise "Accepted #{name}"
end

team = "ABCDEFGHIJ"
identity = "3rd Party Mac Developer Application: Fixture (#{team})"
resolved = %w[WALI WALIAgent WALITranscoder].map do |target|
  {"target" => target, "buildSettings" => {"PRODUCT_BUNDLE_IDENTIFIER" => "com.wali.store.#{target}",
    "DEVELOPMENT_TEAM" => team, "CODE_SIGN_STYLE" => "Manual", "CODE_SIGN_IDENTITY" => identity,
    "PROVISIONING_PROFILE_SPECIFIER" => "Store #{target} Fixture"}}
end
export_options = lambda do |settings = resolved|
  WALIStoreSubmissionSupport.archive_export_options(settings, team: team, identity: identity)
end
expected_profiles = resolved.to_h { |entry| [entry.fetch("buildSettings").fetch("PRODUCT_BUNDLE_IDENTIFIER"), entry.fetch("buildSettings").fetch("PROVISIONING_PROFILE_SPECIFIER")] }
options = export_options.call
raise "Missing exact manual Store export mapping" unless options == {"method" => "app-store", "signingStyle" => "manual", "teamID" => team, "signingCertificate" => identity, "provisioningProfiles" => expected_profiles}
reject_case("missing export target") { export_options.call(resolved.drop(1)) }
raise "Repeated identical Xcode record changes export" unless export_options.call(resolved + [resolved.first]) == options
duplicate = Marshal.load(Marshal.dump(resolved.first))
duplicate.fetch("buildSettings")["PROVISIONING_PROFILE_SPECIFIER"] = "Other Store Profile"
reject_case("conflicting export target") { export_options.call(resolved + [duplicate]) }
{"PRODUCT_BUNDLE_IDENTIFIER" => "com.wali.debug.WALI", "DEVELOPMENT_TEAM" => "OTHERTEAM1", "CODE_SIGN_STYLE" => "Automatic", "CODE_SIGN_IDENTITY" => "Developer ID Application: Fixture", "PROVISIONING_PROFILE_SPECIFIER" => "$(UNRESOLVED_PROFILE)"}.each do |field, value|
  mutation = Marshal.load(Marshal.dump(resolved))
  mutation.first.fetch("buildSettings")[field] = value
  reject_case("wrong export #{field}") { export_options.call(mutation) }
end
["", " leading space", "line\nbreak", nil].each do |profile|
  mutation = Marshal.load(Marshal.dump(resolved))
  mutation.first.fetch("buildSettings")["PROVISIONING_PROFILE_SPECIFIER"] = profile
  reject_case("invalid export profile") { export_options.call(mutation) }
end

Dir.mktmpdir("wali-store-submission-fixtures-") do |root|
  package = File.join(root, "WALI.pkg")
  File.write(package, "signed-package-fixture")
  archive = {"source_commit" => "a" * 40, "team_id" => "ABCDEFGHIJ", "distribution" => "app_store", "app_sha256" => "b" * 64, "package_sha256" => Digest::SHA256.file(package).hexdigest, "bundle_id" => "com.wali.store.WALI", "version" => "0.1.0", "build" => "1"}
  payload = archive.slice("app_sha256", "team_id", "bundle_id", "version", "build").merge("verified_payload" => "exported_pkg", "configuration" => "AppStore")
  verify = lambda { |receipt = archive, candidate = payload| WALIStoreSubmissionSupport.verify_archive!(receipt, payload: candidate, package: package, commit: archive.fetch("source_commit"), team: archive.fetch("team_id")) }
  verify.call
  reject_case("different commit") { verify.call(archive.merge("source_commit" => "c" * 40)) }
  reject_case("different team") { verify.call(archive.merge("team_id" => "KLMNOPQRST")) }
  reject_case("non-Store archive") { verify.call(archive.merge("distribution" => "developer_id")) }
  %w[app_sha256 bundle_id version build].each do |key|
    reject_case("replaced payload #{key}") { verify.call(archive, payload.merge(key => "different")) }
  end
  File.write(package, "replacement")
  reject_case("swapped package") { verify.call }
  File.write(package, "signed-package-fixture")

  direct = archive.slice("source_commit", "team_id", "version", "build").merge("notarization" => {"app" => "11111111-1111-4111-8111-111111111111", "dmg" => "22222222-2222-4222-8222-222222222222"})
  direct["assets"] = %w[zip dmg].to_h do |format|
    name = "WALI-0.1.0-1-macOS.#{format}"
    path = File.join(root, name)
    File.write(path, "#{format} bytes")
    sha = Digest::SHA256.file(path).hexdigest
    File.write("#{path}.sha256", "#{sha}  #{name}\n")
    [format, {"name" => name, "sha256" => sha}]
  end
  direct_bytes = JSON.generate(direct)
  File.write(File.join(root, "release.json"), direct_bytes)
  expected = WALIReleaseSupport.asset_manifest(WALIReleaseSupport.verify_assets!(direct, directory: root) + [File.join(root, "release.json")])
  assets = expected.map { |name, file| {"name" => name, "state" => "uploaded", "size" => file.fetch("size"), "digest" => "sha256:#{file.fetch('sha256')}"} }
  published = {"id" => 1, "draft" => false, "published_at" => "2026-09-09T12:00:00Z", "tag_name" => "v0.1.0", "assets" => assets}
  verify_github = lambda do |release = published, tag_commit = archive.fetch("source_commit"), receipt = direct|
    WALIStoreSubmissionSupport.verify_github_release!(release, direct_receipt: receipt, direct_bytes: direct_bytes, directory: root, tag: "v0.1.0", tag_commit: tag_commit, store_receipt: archive)
  end
  verify_github.call
  reject_case("unpublished GitHub draft") { verify_github.call(published.merge("draft" => true)) }
  reject_case("different release tag") { verify_github.call(published.merge("tag_name" => "v0.2.0")) }
  reject_case("moved GitHub tag") { verify_github.call(published, "c" * 40) }
  reject_case("different GitHub build") { verify_github.call(published, archive.fetch("source_commit"), direct.merge("build" => "2")) }
  reject_case("missing published package") { verify_github.call(published.merge("assets" => assets.drop(1))) }
  replaced = Marshal.load(Marshal.dump(assets)); replaced.first["digest"] = "sha256:#{'0' * 64}"
  reject_case("replaced remote package") { verify_github.call(published.merge("assets" => replaced)) }

  metadata = File.join(root, "metadata"); screenshots = File.join(root, "screenshots")
  FileUtils.mkdir_p([File.join(metadata, "en-US"), File.join(screenshots, "en-US")])
  %w[copyright primary_category].each { |name| File.write(File.join(metadata, "#{name}.txt"), "Final fixture value") }
  %w[name description keywords].each { |name| File.write(File.join(metadata, "en-US", "#{name}.txt"), "Final fixture text") }
  %w[support_url privacy_url].each { |name| File.write(File.join(metadata, "en-US", "#{name}.txt"), "https://wali.example.com/#{name}") }
  File.write(File.join(screenshots, "en-US", "01-mac.png"), "fixture-only; image validation belongs to upload")
  packet = {"app_review_information" => {"first_name" => "Test", "last_name" => "Reviewer", "phone_number" => "+1 555 0100", "email_address" => "reviewer@wali.example.com", "notes" => "Verified walkthrough."}, "submission_information" => {"export_compliance_uses_encryption" => false, "content_rights_contains_third_party_content" => true}}
  review = File.join(root, "review.json"); File.write(review, JSON.generate(packet))
  inputs = lambda { WALIStoreSubmissionSupport.review_inputs(metadata: metadata, screenshots: screenshots, review: review) }
  _, fingerprint = inputs.call
  upload = archive.merge("status" => "uploaded_not_submitted", "review_inputs" => fingerprint, "github_release_id" => 1)
  verify_upload = lambda { |receipt = upload| WALIStoreSubmissionSupport.verify_upload!(receipt, archive: archive, fingerprint: fingerprint, github_release_id: 1) }
  verify_upload.call
  reject_case("different uploaded build") { verify_upload.call(upload.merge("build" => "2")) }
  reject_case("unconfirmed upload") { verify_upload.call(upload.merge("status" => "uploading")) }
  reject_case("changed review inputs") { verify_upload.call(upload.merge("review_inputs" => {})) }
  reject_case("different GitHub release") { verify_upload.call(upload.merge("github_release_id" => 2)) }
  File.write(File.join(metadata, "copyright.txt"), "PENDING owner")
  reject_case("draft legal metadata") { inputs.call }
  File.write(File.join(metadata, "copyright.txt"), "Final fixture value")
  invalid = Marshal.load(Marshal.dump(packet)); invalid["submission_information"]["export_compliance_uses_encryption"] = nil
  File.write(review, JSON.generate(invalid))
  reject_case("unknown encryption answer") { inputs.call }
  invalid["submission_information"]["export_compliance_uses_encryption"] = "false"
  File.write(review, JSON.generate(invalid))
  reject_case("string encryption answer") { inputs.call }
  File.write(review, JSON.generate(packet))
  File.symlink(review, File.join(metadata, "injected.txt"))
  reject_case("metadata symlink") { inputs.call }
  File.unlink(File.join(metadata, "injected.txt"))
  %w[default fr-FR review_information app_clip_review_information].each do |name|
    directory = File.join(metadata, name); FileUtils.mkdir_p(directory)
    reject_case("unreviewed metadata directory #{name}") { inputs.call }
    FileUtils.remove_dir(directory)
  end
  File.write(File.join(metadata, "en-US", "demo_password.txt"), "unreviewed fixture")
  reject_case("localized review override") { inputs.call }
  File.unlink(File.join(metadata, "en-US", "demo_password.txt"))
  inputs.call

  WALIStoreSubmissionSupport.verify_environment!(environment: {}, configuration_files: [])
  %w[DELIVER_VERIFY_ONLY DELIVER_SKIP_BINARY_UPLOAD DELIVER_SKIP_METADATA DELIVER_SKIP_SCREENSHOTS].each do |key|
    reject_case("ambient #{key}") { WALIStoreSubmissionSupport.verify_environment!(environment: {key => "true"}, configuration_files: []) }
  end
  reject_case("ambient Deliverfile") { WALIStoreSubmissionSupport.verify_environment!(environment: {}, configuration_files: [review]) }
  upload_mode = WALIStoreSubmissionSupport.delivery_options(upload: true)
  raise "Upload allows mode skipping" unless %i[verify_only skip_binary_upload skip_metadata skip_screenshots submit_for_review edit_live use_live_version].all? { |key| upload_mode.fetch(key) == false }
  submit_mode = WALIStoreSubmissionSupport.delivery_options(upload: false)
  raise "Submit does not pin an exact operating mode" unless submit_mode.fetch(:submit_for_review) && submit_mode.fetch(:skip_binary_upload) && !submit_mode.fetch(:verify_only) && !submit_mode.fetch(:automatic_release)
  encryption_build = Struct.new(:uses_non_exempt_encryption).new(nil)
  WALIStoreSubmissionSupport.verify_encryption!(encryption_build, answer: false)
  reject_case("missing final encryption declaration") { WALIStoreSubmissionSupport.verify_encryption!(encryption_build, answer: false, require_value: true) }
  encryption_build.uses_non_exempt_encryption = true
  reject_case("opposite encryption declaration") { WALIStoreSubmissionSupport.verify_encryption!(encryption_build, answer: false) }
  WALIStoreSubmissionSupport.verify_encryption!(encryption_build, answer: true, require_value: true)

  image_path = File.join(screenshots, "en-US", "01-mac.png")
  shot = Struct.new(:source_file_checksum, :file_size, :asset_delivery_state).new(Digest::MD5.file(image_path).hexdigest, File.size(image_path), {"state" => "COMPLETE"})
  set = Struct.new(:screenshot_display_type, :app_screenshots).new("APP_DESKTOP", [shot])
  WALIStoreSubmissionSupport.verify_screenshots!([set], directory: screenshots)
  reject_case("old extra screenshot") { WALIStoreSubmissionSupport.verify_screenshots!([set, set], directory: screenshots) }
  shot.source_file_checksum = "old screenshot"
  reject_case("old ten-image set instead of reviewed screenshot") { WALIStoreSubmissionSupport.verify_screenshots!([set], directory: screenshots) }
  shot.source_file_checksum = Digest::MD5.file(image_path).hexdigest
  shot.asset_delivery_state = {"state" => "FAILED"}
  reject_case("failed screenshot processing") { WALIStoreSubmissionSupport.verify_screenshots!([set], directory: screenshots) }
  shot.asset_delivery_state = {"state" => "COMPLETE"}; set.screenshot_display_type = "APP_IPHONE_67"
  reject_case("non-Mac screenshot set") { WALIStoreSubmissionSupport.verify_screenshots!([set], directory: screenshots) }

  editable = Struct.new(:version_string, :platform).new("0.1.0", "MAC_OS")
  WALIStoreSubmissionSupport.verify_editable_version!(editable, archive: archive)
  editable.version_string = "0.2.0"
  reject_case("renamed different prepared version") { WALIStoreSubmissionSupport.verify_editable_version!(editable, archive: archive) }
  reject_case("missing editable version") { WALIStoreSubmissionSupport.verify_editable_version!(nil, archive: archive) }
  localization = Struct.new(:locale, :get_app_screenshot_sets)
  english = localization.new("en-US", [set])
  french = localization.new("fr-FR", [])
  WALIStoreSubmissionSupport.verify_screenshot_scope!([english, french])
  french.get_app_screenshot_sets = [set]
  reject_case("unreviewed foreign screenshot set") { WALIStoreSubmissionSupport.verify_screenshot_scope!([english, french]) }
  french.get_app_screenshot_sets = [Struct.new(:app_screenshots).new([])]
  reject_case("unreviewed empty foreign screenshot set") { WALIStoreSubmissionSupport.verify_screenshot_scope!([english, french]) }

  version = Struct.new(:id).new("version-one")
  submission = Struct.new(:state, :platform, :app_store_version_for_review).new("WAITING_FOR_REVIEW", "MAC_OS", version)
  item = Struct.new(:app_store_version, :app_store_version_experiment, :app_store_product_page_version, :app_event).new(version, nil, nil, nil)
  verify_submission = lambda do |items = [item], selected = "build-one"|
    WALIStoreSubmissionSupport.verify_submission!(submission, items: items, version_id: "version-one", selected_build_id: selected, expected_build_id: "build-one")
  end
  verify_submission.call
  submission.state = "UNRESOLVED_ISSUES"
  reject_case("unresolved prior review") { verify_submission.call }
  submission.state = "WAITING_FOR_REVIEW"
  reject_case("extra review item") { verify_submission.call([item, item]) }
  reject_case("different selected build") { verify_submission.call([item], "build-two") }
  submission.app_store_version_for_review = Struct.new(:id).new("other-version")
  reject_case("different submitted version") { verify_submission.call }

  build = Struct.new(:processing_state, :expired, :bundle_id, :app_version, :version, :platform).new("VALID", false, "com.wali.store.WALI", "0.1.0", "1", "MAC_OS")
  WALIStoreSubmissionSupport.verify_processed_build!(build, archive: archive)
  %w[PROCESSING FAILED INVALID].each do |state|
    build.processing_state = state
    reject_case("#{state} Apple build") { WALIStoreSubmissionSupport.verify_processed_build!(build, archive: archive) }
  end
  build.processing_state = "VALID"; build.version = "2"
  reject_case("latest instead of exact Apple build") { WALIStoreSubmissionSupport.verify_processed_build!(build, archive: archive) }
  build.version = "1"; build.platform = "IOS"
  reject_case("wrong Apple platform") { WALIStoreSubmissionSupport.verify_processed_build!(build, archive: archive) }
end
puts "Store submission fixtures passed (#{$count} rejection cases plus valid archive, published release, metadata, upload and processed-build paths)."
