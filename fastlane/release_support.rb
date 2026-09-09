# frozen_string_literal: true

require "digest"
require "find"
require "json"
require "open3"

module WALIReleaseSupport
  module_function

  def source_commit(root)
    output, status = Open3.capture2("git", "-C", root, "rev-parse", "HEAD")
    raise "Cannot identify the release commit" unless status.success? && output.strip.match?(/\A[0-9a-f]{40}\z/)
    %w[--cached --no-ext-diff].each do |option|
      _, clean = Open3.capture2("git", "-C", root, "diff", option, "--quiet", "HEAD", "--")
      raise "Commit tracked changes before archiving or publishing a release" unless clean.success?
    end
    untracked, status = Open3.capture2("git", "-C", root, "ls-files", "--others", "--exclude-standard", "-z")
    raise "Cannot inspect release inputs" unless status.success?
    # Branding previews are deliberately local, untracked output, never build inputs.
    raise "Commit untracked release inputs first" if untracked.split("\0").any? { |path| !path.start_with?("output/") }
    output.strip
  end

  def bundle_digest(app)
    raise "Missing app bundle: #{app}" unless File.directory?(app)
    digest = Digest::SHA256.new
    paths = []
    Find.find(app) { |path| paths << path unless path == app }
    paths.sort.each do |path|
      relative = path.delete_prefix("#{app}/")
      stat = File.lstat(path)
      kind, payload = if stat.symlink?
        ["link", File.readlink(path)]
      elsif stat.file?
        ["file", Digest::SHA256.file(path).hexdigest]
      elsif stat.directory?
        ["directory", ""]
      else
        raise "Unsupported app bundle entry: #{relative}"
      end
      digest.update(JSON.generate([relative, kind, stat.mode & 0o777, payload]))
    end
    digest.hexdigest
  end

  def verify_archive!(receipt, app:, root:)
    raise "Archive belongs to another source commit" unless receipt.fetch("source_commit") == source_commit(root)
    raise "App changed since the verified archive" unless receipt.fetch("app_sha256") == bundle_digest(app)
  end

  def verify_assets!(receipt, directory:)
    assets = receipt.fetch("assets")
    raise "Release needs both ZIP and DMG artifacts" unless assets.keys.sort == %w[dmg zip]
    assets.each_value.map do |item|
      name = item.fetch("name")
      raise "Invalid release artifact name" unless name == File.basename(name) && name.match?(/\AWALI-[A-Za-z0-9.-]+\.(zip|dmg)\z/)
      path = File.join(directory, name)
      expected = item.fetch("sha256")
      raise "Invalid artifact digest" unless expected.match?(/\A[0-9a-f]{64}\z/)
      raise "Release artifact changed: #{name}" unless File.file?(path) && Digest::SHA256.file(path).hexdigest == expected
      raise "Checksum sidecar does not match: #{name}" unless File.read("#{path}.sha256") == "#{expected}  #{name}\n"
      [path, "#{path}.sha256"]
    end.flatten
  end

  def verify_ci!(runs, commit:)
    required = %w[source contracts swift backend media]
    missing = required.reject do |name|
      runs.any? do |run|
        run["name"] == name && run["head_sha"] == commit &&
          run["status"] == "completed" && run["conclusion"] == "success" &&
          run.fetch("app", {})["slug"] == "github-actions"
      end
    end
    raise "Release commit still needs successful CI: #{missing.join(', ')}" unless missing.empty?
  end

  def asset_manifest(paths)
    entries = paths.map do |path|
      [File.basename(path), {"size" => File.size(path), "sha256" => Digest::SHA256.file(path).hexdigest}]
    end
    raise "Duplicate release asset names" unless entries.map(&:first).uniq.length == entries.length
    entries.to_h
  end

  def verify_uploaded_assets!(uploaded, expected:)
    raise "Draft upload asset set does not match" unless uploaded.map { |asset| asset.fetch("name") }.sort == expected.keys.sort
    uploaded.each do |asset|
      file = expected.fetch(asset.fetch("name"))
      unless asset["state"] == "uploaded" && asset["size"] == file.fetch("size") && asset["digest"] == "sha256:#{file.fetch('sha256')}"
        raise "Uploaded release bytes do not match: #{asset.fetch('name')}"
      end
    end
  end

  def verify_package_manifest!(manifest, receipt:, receipt_bytes:)
    receipt.fetch("assets").each_value do |asset|
      name = asset.fetch("name")
      sha = asset.fetch("sha256")
      raise "Package changed after preflight: #{name}" unless manifest.fetch(name).fetch("sha256") == sha
      checksum = "#{sha}  #{name}\n"
      sidecar = manifest.fetch("#{name}.sha256")
      unless sidecar.fetch("size") == checksum.bytesize && sidecar.fetch("sha256") == Digest::SHA256.hexdigest(checksum)
        raise "Checksum changed after preflight: #{name}"
      end
    end
    expected_receipt = {"size" => receipt_bytes.bytesize, "sha256" => Digest::SHA256.hexdigest(receipt_bytes)}
    raise "Release receipt changed after preflight" unless manifest.fetch("release.json") == expected_receipt
  end
end
