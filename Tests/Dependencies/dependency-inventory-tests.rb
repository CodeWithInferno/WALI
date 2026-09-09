#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"

ROOT = Pathname.new(__dir__).parent.parent
INPUTS = %w[
  project.yml Config/Package.resolved Gemfile.lock LICENSE NOTICE
  Services/WALIMediaWorker/go.mod Services/WALIClassifier/uv.lock
  Services/WALIClassifier/model-manifest.json Services/WALIMediaSandbox/Containerfile
].freeze

def fixture
  Dir.mktmpdir("wali-dependency-tests-") do |directory|
    root = Pathname.new(directory)
    files = INPUTS + Dir.glob(ROOT / "scripts/*dependency*.rb").map { |path| Pathname.new(path).relative_path_from(ROOT).to_s }
    files += %w[scripts/generate-sbom.rb scripts/verify-third-party-licenses.rb].select { |path| (ROOT / path).file? }
    files.each do |path|
      (root / path).dirname.mkpath
      FileUtils.cp(ROOT / path, root / path)
    end
    (root / "Resources").mkpath
    FileUtils.cp_r(ROOT / "Resources/ThirdPartyLicenses", root / "Resources/ThirdPartyLicenses")
    yield root
  end
end

def generate(root)
  Open3.capture3(RbConfig.ruby, (root / "scripts/generate-sbom.rb").to_s)
end

def edit_json(path)
  value = JSON.parse(path.read)
  yield value
  path.write(JSON.pretty_generate(value) + "\n")
end

def assert(condition, message)
  raise message unless condition
end

tests = {
  "inventories every resolved Swift package including transitive dependencies" => lambda do |root|
    _, error, status = generate(root)
    assert(status.success?, error)
    document = JSON.parse((root / "sbom/wali-marketplace.spdx.json").read)
    actual = document.fetch("packages").select { |item| item.fetch("SPDXID").start_with?("SPDXRef-Package-swift-") }
    expected = JSON.parse((root / "Config/Package.resolved").read).fetch("pins")
    assert(actual.map { |item| item.fetch("name") }.sort == expected.map { |pin| pin.fetch("identity") }.sort,
           "SBOM omits resolved Swift dependencies")
    assert(actual.find { |item| item["name"] == "supabase-swift" }.fetch("licenseDeclared") == "MIT", "Supabase license must be MIT")
    expected.each do |pin|
      item = actual.find { |candidate| candidate["name"] == pin["identity"] }
      assert(item["versionInfo"] == pin.dig("state", "version"), "resolved version changed")
      assert(item["downloadLocation"].include?(pin.dig("state", "revision")), "resolved revision missing")
    end
  end,
  "records the Git-pinned Fastlane revision" => lambda do |root|
    _, error, status = generate(root)
    assert(status.success?, error)
    document = JSON.parse((root / "sbom/wali-marketplace.spdx.json").read)
    item = document.fetch("packages").find { |candidate| candidate["name"] == "fastlane" }
    revision = (root / "Gemfile.lock").read[/^  revision: ([0-9a-f]{40})$/, 1]
    assert(item && item["downloadLocation"] == "git+https://github.com/fastlane/fastlane.git@#{revision}", "Fastlane Git source is missing")
  end,
  "rejects a project root version different from the canonical lock" => lambda do |root|
    path = root / "project.yml"
    path.write(path.read.sub(/exactVersion: \S+/, "exactVersion: 0.0.1"))
    _, error, status = generate(root)
    assert(!status.success? && error.include?("exactVersion"), "mismatched root version was accepted")
  end,
  "rejects a root dependency missing from the canonical lock" => lambda do |root|
    edit_json(root / "Config/Package.resolved") { |value| value["pins"].reject! { |pin| pin["identity"] == "supabase-swift" } }
    _, error, status = generate(root)
    assert(!status.success? && error.include?("supabase-swift"), "missing root dependency was accepted")
  end,
  "rejects a transitive dependency without reviewed license records" => lambda do |root|
    edit_json(root / "Resources/ThirdPartyLicenses/manifest.json") { |value| value["packages"].reject! { |item| item["identity"] == "swift-clocks" } }
    _, error, status = generate(root)
    assert(!status.success? && error.include?("swift-clocks"), "unlicensed transitive dependency was accepted")
  end,
  "rejects a changed upstream license file" => lambda do |root|
    (root / "Resources/ThirdPartyLicenses/supabase-swift-LICENSE.txt").write("truncated license\n")
    _, error, status = generate(root)
    assert(!status.success? && error.include?("supabase-swift-LICENSE.txt"), "tampered license file was accepted")
  end,
  "rejects license directories linked outside the application" => lambda do |root|
    %w[Contents Contents/Resources Contents/Resources/ThirdPartyLicenses].each_with_index do |component, index|
      app = root / "linked-#{index}.app"
      (app / "Contents/Resources").mkpath
      FileUtils.cp_r(root / "Resources/ThirdPartyLicenses", app / "Contents/Resources/ThirdPartyLicenses")
      external = root / "external-#{index}"
      FileUtils.mv(app / component, external)
      File.symlink(external, app / component)
      _, error, status = Open3.capture3(RbConfig.ruby, (root / "scripts/verify-third-party-licenses.rb").to_s, app.to_s)
      assert(!status.success? && error.include?("inside the app"), "external license directory was accepted through #{component}")
    end
  end,
  "verifies actual app resources and rejects a missing bundled notice" => lambda do |root|
    app = root / "WALI.app"
    (app / "Contents/Resources").mkpath
    FileUtils.cp_r(root / "Resources/ThirdPartyLicenses", app / "Contents/Resources/ThirdPartyLicenses")
    command = [RbConfig.ruby, (root / "scripts/verify-third-party-licenses.rb").to_s, app.to_s]
    _, error, status = Open3.capture3(*command)
    assert(status.success?, error)
    (app / "Contents/Resources/ThirdPartyLicenses/swift-crypto-NOTICE.txt").delete
    _, error, status = Open3.capture3(*command)
    assert(!status.success? && error.include?("swift-crypto-NOTICE.txt"), "missing bundled notice was accepted")
  end
}

failures = 0
tests.each do |name, test|
  begin
    fixture { |root| test.call(root) }
    puts "PASS: #{name}"
  rescue StandardError => error
    failures += 1
    warn "FAIL: #{name}: #{error.message}"
  end
end
abort "#{failures} dependency inventory checks failed" unless failures.zero?
puts "#{tests.length} dependency inventory checks passed"
