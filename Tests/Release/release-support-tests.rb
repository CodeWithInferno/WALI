#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "../../fastlane/release_support"

def assert(value, message)
  raise message unless value
end

def rejects(message)
  begin
    yield
  rescue RuntimeError, KeyError, Errno::ENOENT
    return
  end
  raise "Accepted #{message}"
end

def git(root, *arguments)
  output, status = Open3.capture2e("git", "-C", root, *arguments)
  raise output unless status.success?
  output.strip
end

Dir.mktmpdir("wali-release-fixtures-") do |directory|
  root = File.join(directory, "repo")
  FileUtils.mkdir_p(root)
  git(root, "init", "-q")
  File.write(File.join(root, "source.swift"), "original\n")
  git(root, "add", "source.swift")
  git(root, "-c", "user.name=Release Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "Release fixture")
  commit = WALIReleaseSupport.source_commit(root)
  assert(commit.match?(/\A[0-9a-f]{40}\z/), "Missing clean commit")

  File.write(File.join(root, "source.swift"), "edited\n")
  rejects("unstaged release input") { WALIReleaseSupport.source_commit(root) }
  git(root, "add", "source.swift")
  rejects("staged release input") { WALIReleaseSupport.source_commit(root) }
  git(root, "restore", "--source=HEAD", "--staged", "--worktree", "source.swift")
  File.write(File.join(root, "new.swift"), "untracked\n")
  rejects("untracked release input") { WALIReleaseSupport.source_commit(root) }
  File.unlink(File.join(root, "new.swift"))
  FileUtils.mkdir_p(File.join(root, "output"))
  File.write(File.join(root, "output", "preview.txt"), "local preview\n")
  assert(WALIReleaseSupport.source_commit(root) == commit, "Preview blocks source verification")

  app = File.join(directory, "WALI.app")
  FileUtils.mkdir_p(File.join(app, "Contents", "MacOS"))
  executable = File.join(app, "Contents", "MacOS", "WALI")
  File.write(executable, "fixture executable\n")
  File.chmod(0o755, executable)
  link = File.join(app, "Contents", "current")
  File.symlink("MacOS/WALI", link)
  receipt = {"source_commit" => commit, "app_sha256" => WALIReleaseSupport.bundle_digest(app)}
  WALIReleaseSupport.verify_archive!(receipt, app: app, root: root)
  rejects("another source commit") { WALIReleaseSupport.verify_archive!(receipt.merge("source_commit" => "0" * 40), app: app, root: root) }
  File.write(executable, "different executable\n")
  rejects("changed bundle bytes") { WALIReleaseSupport.verify_archive!(receipt, app: app, root: root) }
  File.write(executable, "fixture executable\n")
  File.chmod(0o644, executable)
  rejects("changed executable mode") { WALIReleaseSupport.verify_archive!(receipt, app: app, root: root) }
  File.chmod(0o755, executable)
  File.unlink(link)
  File.symlink("other-target", link)
  rejects("changed symlink target") { WALIReleaseSupport.verify_archive!(receipt, app: app, root: root) }

  assets = %w[zip dmg].to_h do |format|
    name = "WALI-0.1.0-1-macOS.#{format}"
    path = File.join(directory, name)
    File.write(path, "#{format} fixture\n")
    digest = Digest::SHA256.file(path).hexdigest
    File.write("#{path}.sha256", "#{digest}  #{name}\n")
    [format, {"name" => name, "sha256" => digest}]
  end
  manifest = {"assets" => assets}
  assert(WALIReleaseSupport.verify_assets!(manifest, directory: directory).length == 4, "Missing artifact or sidecar")
  rejects("missing DMG") { WALIReleaseSupport.verify_assets!({"assets" => {"zip" => assets.fetch("zip")}}, directory: directory) }
  traversal = Marshal.load(Marshal.dump(manifest))
  traversal["assets"]["zip"]["name"] = "../WALI-sibling.zip"
  rejects("artifact path traversal") { WALIReleaseSupport.verify_assets!(traversal, directory: directory) }
  zip = File.join(directory, assets.fetch("zip").fetch("name"))
  File.write(zip, "replaced\n")
  rejects("replaced release ZIP") { WALIReleaseSupport.verify_assets!(manifest, directory: directory) }
  File.write(zip, "zip fixture\n")
  File.write("#{zip}.sha256", "incorrect checksum\n")
  rejects("mismatched sidecar") { WALIReleaseSupport.verify_assets!(manifest, directory: directory) }

  runs = %w[source history-secrets contracts swift store backend media].map do |name|
    {"name" => name, "head_sha" => commit, "status" => "completed", "conclusion" => "success", "app" => {"slug" => "github-actions"}}
  end
  WALIReleaseSupport.verify_ci!(runs, commit: commit)
  rejects("missing history scan") { WALIReleaseSupport.verify_ci!(runs.reject { |run| run["name"] == "history-secrets" }, commit: commit) }
  rejects("missing Store check") { WALIReleaseSupport.verify_ci!(runs.reject { |run| run["name"] == "store" }, commit: commit) }
  rejects("missing security check") { WALIReleaseSupport.verify_ci!(runs.drop(1), commit: commit) }
  rejects("checks from an older commit") { WALIReleaseSupport.verify_ci!(runs, commit: "0" * 40) }
  %w[failure skipped].each do |conclusion|
    changed = Marshal.load(Marshal.dump(runs))
    changed.first["conclusion"] = conclusion
    rejects("#{conclusion} security check") { WALIReleaseSupport.verify_ci!(changed, commit: commit) }
  end
  changed = Marshal.load(Marshal.dump(runs))
  changed.first["status"] = "in_progress"
  rejects("unfinished security check") { WALIReleaseSupport.verify_ci!(changed, commit: commit) }
  changed = Marshal.load(Marshal.dump(runs))
  changed.first["app"]["slug"] = "other-app"
  rejects("untrusted check provider") { WALIReleaseSupport.verify_ci!(changed, commit: commit) }

  expected = WALIReleaseSupport.asset_manifest([zip])
  uploaded = expected.map { |name, file| {"name" => name, "size" => file.fetch("size"), "digest" => "sha256:#{file.fetch('sha256')}", "state" => "uploaded"} }
  WALIReleaseSupport.verify_uploaded_assets!(uploaded, expected: expected)
  changed = Marshal.load(Marshal.dump(uploaded))
  changed.first["digest"] = "sha256:#{'0' * 64}"
  rejects("same-name swapped remote bytes") { WALIReleaseSupport.verify_uploaded_assets!(changed, expected: expected) }
  changed = Marshal.load(Marshal.dump(uploaded))
  changed.first.delete("digest")
  rejects("unverified remote digest") { WALIReleaseSupport.verify_uploaded_assets!(changed, expected: expected) }
  changed = Marshal.load(Marshal.dump(uploaded))
  changed.first["size"] += 1
  rejects("wrong uploaded size") { WALIReleaseSupport.verify_uploaded_assets!(changed, expected: expected) }
  rejects("missing remote artifact") { WALIReleaseSupport.verify_uploaded_assets!([], expected: expected) }

  File.write("#{zip}.sha256", "#{assets.fetch('zip').fetch('sha256')}  #{File.basename(zip)}\n")
  receipt_bytes = JSON.generate(manifest)
  receipt_file = File.join(directory, "release.json")
  File.write(receipt_file, receipt_bytes)
  paths = WALIReleaseSupport.verify_assets!(manifest, directory: directory) + [receipt_file]
  expected = WALIReleaseSupport.asset_manifest(paths)
  WALIReleaseSupport.verify_package_manifest!(expected, receipt: manifest, receipt_bytes: receipt_bytes)
  File.write(zip, "replacement after preflight\n")
  changed = WALIReleaseSupport.asset_manifest(paths)
  rejects("replacement adopted by a later asset manifest") { WALIReleaseSupport.verify_package_manifest!(changed, receipt: manifest, receipt_bytes: receipt_bytes) }
  changed = Marshal.load(Marshal.dump(expected))
  changed.fetch("release.json")["sha256"] = "0" * 64
  rejects("replaced receipt adopted by a later manifest") { WALIReleaseSupport.verify_package_manifest!(changed, receipt: manifest, receipt_bytes: receipt_bytes) }
end

puts "Release provenance fixtures passed (clean/dirty source, bundle bytes/modes/links, artifacts and sidecars)."
