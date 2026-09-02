#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "pathname"
require "set"
require "yaml"

root = Pathname.new(__dir__).parent
policy = YAML.safe_load((root / "docs/security/dependency-policy.yml").read)
sbom = JSON.parse((root / "sbom/wali-marketplace.spdx.json").read)

permitted = policy.fetch("license_policy").fetch("permitted_by_default")
reviewed = policy.fetch("license_policy").fetch("reviewed_exceptions", {}).keys
unknown = []
unapproved = []

sbom.fetch("packages").each do |item|
  expression = item.fetch("licenseDeclared")
  if expression == "NOASSERTION"
    unknown << item.fetch("name")
    next
  end
  licenses = expression.scan(/[A-Za-z0-9.-]+/).reject { |token| %w[AND OR WITH].include?(token) }
  next if licenses.all? { |license| permitted.include?(license) || reviewed.include?(license) }
  unapproved << "#{item.fetch("name")}: #{expression}"
end

violations = []
violations << "unknown licenses: #{unknown.sort.join(", ")}" unless unknown.empty?
violations << "unapproved licenses: #{unapproved.sort.join(", ")}" unless unapproved.empty?

project = (root / "project.yml").read
violations << "Swift dependency must use an exact version" if project.match?(/^\s+(branch|revision|from):/)

Dir.glob(root / ".github/workflows/*.{yml,yaml}").each do |path|
  workflow = File.read(path)
  workflow.scan(/^\s*-?\s*uses:\s*([^@\s]+)@([^\s#]+)/).each do |action, revision|
    next if action.start_with?("./")
    unless revision.match?(/\A[0-9a-f]{40}\z/)
      violations << "GitHub Action is not SHA-pinned in #{Pathname.new(path).relative_path_from(root)}: #{action}@#{revision}"
    end
  end
  violations << "pull_request_target is forbidden in #{path}" if workflow.match?(/^\s*pull_request_target:/)
  violations << "write-all workflow permissions are forbidden in #{path}" if workflow.include?("permissions: write-all")
end

Dir.glob(root / "Services/**/Containerfile").each do |path|
  stages = Set.new
  arguments = {}
  File.readlines(path).each do |line|
    if (match = line.match(/^ARG\s+([A-Z][A-Z0-9_]*)=([^\s]+)\s*$/))
      arguments[match[1]] = match[2]
      next
    end
    match = line.match(/^FROM(?:\s+--platform=\S+)?\s+([^\s]+)(?:\s+AS\s+([A-Za-z0-9_.-]+))?/i)
    next unless match

    source = match[1]
    pinned = source.include?("@sha256:") || stages.include?(source)
    if (argument = source.match(/^\$\{([A-Z][A-Z0-9_]*)\}$/))
      # The classifier's ordinary build selects an earlier, pinned internal
      # model-free stage. Production overrides are accepted only through the
      # separately reviewed digest-only WALI_MODEL_IMAGE release contract.
      pinned ||= argument[1] == "WALI_MODEL_IMAGE" && stages.include?(arguments[argument[1]])
    end
    violations << "mutable OCI base in #{path}: #{line.strip}" unless pinned
    stages << match[2] if match[2]
  end
end

media_runbook = (root / "docs/runbooks/media-worker.md").read
unless media_runbook.include?("WALI_MODEL_IMAGE=registry/repository@sha256:<64-hex-digest>")
  violations << "classifier model-image override must document a digest-only release contract"
end

go_mod = (root / "Services/WALIMediaWorker/go.mod").read
violations << "Go module replace directives require review" if go_mod.match?(/^replace\s/m)

seed = YAML.safe_load((root / "docs/content/seed-catalog.yml").read)
seed.fetch("items").each do |item|
  missing = seed.fetch("required_item_fields").reject { |field| item.key?(field) && !item[field].to_s.empty? }
  violations << "seed item #{item["id"] || "unknown"} missing #{missing.join(", ")}" unless missing.empty?
end

media_roots = %w[Fixtures Sources Resources Assets].map do |name|
  path = root / name
  path if path.exist?
end.compact
prohibited = policy.fetch("content_exclusions").fetch("prohibited_sources")
media_roots.each do |path|
  Dir.glob(path / "**/*", File::FNM_DOTMATCH).each do |entry|
    next unless File.file?(entry)
    next if File.size(entry) > 2_000_000
    value = File.binread(entry).scrub
    prohibited.each do |name|
      violations << "prohibited source reference in #{entry.relative_path_from(root)}" if value.downcase.include?(name.downcase)
    end
  end
end

unless violations.empty?
  warn violations.map { |message| "license/provenance: #{message}" }.join("\n")
  exit 1
end

puts "license/provenance checks passed for #{sbom.fetch("packages").count} packages"
