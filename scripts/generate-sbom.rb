#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require_relative "swift-dependency-inventory"

ROOT = Pathname.new(__dir__).parent.freeze
OUTPUT = ROOT / "sbom/wali-marketplace.spdx.json"

LICENSES = {
  "annotated-doc" => "MIT", "anyio" => "MIT", "click" => "BSD-3-Clause",
  "certifi" => "MPL-2.0", "charset-normalizer" => "MIT", "colorama" => "BSD-3-Clause",
  "filelock" => "Unlicense", "fsspec" => "BSD-3-Clause", "hf-xet" => "Apache-2.0",
  "h11" => "MIT", "httpcore" => "BSD-3-Clause", "httpx" => "BSD-3-Clause",
  "huggingface-hub" => "Apache-2.0", "idna" => "BSD-3-Clause", "iniconfig" => "MIT",
  "jinja2" => "BSD-3-Clause", "markupsafe" => "BSD-3-Clause", "mpmath" => "BSD-3-Clause",
  "markdown-it-py" => "MIT", "mdurl" => "MIT",
  "networkx" => "BSD-3-Clause", "numpy" => "BSD-3-Clause", "packaging" => "Apache-2.0 OR BSD-2-Clause",
  "pillow" => "HPND", "pluggy" => "MIT", "pygments" => "BSD-2-Clause", "pytest" => "MIT",
  "pyyaml" => "MIT", "regex" => "Apache-2.0", "requests" => "Apache-2.0", "rich" => "MIT",
  "safetensors" => "Apache-2.0", "setuptools" => "MIT", "sympy" => "BSD-3-Clause",
  "shellingham" => "ISC",
  "tokenizers" => "Apache-2.0", "torch" => "BSD-3-Clause", "tqdm" => "MPL-2.0 AND MIT",
  "transformers" => "Apache-2.0", "typer" => "MIT", "typing-extensions" => "PSF-2.0",
  "urllib3" => "MIT",
  "wali-classifier" => "Apache-2.0",
  "github.com/jackc/pgx/v5" => "MIT", "github.com/jackc/pgpassfile" => "MIT",
  "github.com/jackc/pgservicefile" => "MIT", "github.com/jackc/puddle/v2" => "MIT",
  "golang.org/x/crypto" => "BSD-3-Clause", "golang.org/x/sync" => "BSD-3-Clause",
  "golang.org/x/text" => "BSD-3-Clause", "fastlane" => "MIT",
  "ffmpeg" => "LGPL-2.1-or-later", "kvazaar" => "BSD-3-Clause",
  "google/siglip-base-patch16-224" => "Apache-2.0",
  "docker.io/library/debian:bookworm-slim" => "LicenseRef-Debian-Image-Mixed"
}.freeze

def package(name:, version:, ecosystem:, checksum: nil, download: "NOASSERTION", license: nil)
  license ||= LICENSES.fetch(name, "NOASSERTION")
  identifier = "SPDXRef-Package-#{ecosystem}-#{name.gsub(/[^A-Za-z0-9.-]/, "-")}-#{version.gsub(/[^A-Za-z0-9.-]/, "-")}"
  result = {
    "SPDXID" => identifier,
    "name" => name,
    "versionInfo" => version,
    "downloadLocation" => download,
    "filesAnalyzed" => false,
    "licenseConcluded" => license,
    "licenseDeclared" => license,
    "supplier" => "NOASSERTION",
    "primaryPackagePurpose" => ecosystem == "oci" ? "CONTAINER" : "LIBRARY",
    "externalRefs" => [{
      "referenceCategory" => "PACKAGE-MANAGER",
      "referenceType" => "purl",
      "referenceLocator" => "pkg:#{ecosystem}/#{name}@#{version}"
    }]
  }
  if checksum
    result["checksums"] = [{"algorithm" => "SHA256", "checksumValue" => checksum}]
  end
  result
end

packages = []

go_mod = (ROOT / "Services/WALIMediaWorker/go.mod").read
go_mod.scan(/^\s*([^\s()]+)\s+(v[^\s]+)(?:\s+\/\/ indirect)?$/).each do |name, version|
  next if name == "go"
  packages << package(name: name, version: version, ecosystem: "golang")
end

uv_lock = (ROOT / "Services/WALIClassifier/uv.lock").read
uv_lock.scan(/^\[\[package\]\]\n(.*?)(?=^\[\[package\]\]|\z)/m).flatten.each do |block|
  name = block[/^name = "([^"]+)"$/, 1]
  version = block[/^version = "([^"]+)"$/, 1]
  packages << package(name: name, version: version, ecosystem: "pypi") if name && version
end

begin
  SwiftDependencyInventory.load(ROOT).each do |pin|
    packages << package(
      name: pin.fetch("identity"), version: pin.fetch("state").fetch("version"),
      ecosystem: "swift", license: pin.fetch("license"),
      download: "git+#{pin.fetch('location')}@#{pin.fetch('state').fetch('revision')}"
    )
  end
rescue StandardError => error
  abort "Swift dependency inventory: #{error.message}"
end

# Git-sourced release tooling has no RubyGems artifact checksum. Preserve its
# immutable upstream source in the inventory, including Fastlane's Rubyzip fix.
(ROOT / "Gemfile.lock").read.scan(/^GIT\n(.*?)(?=^\S|\z)/m).flatten.each do |source|
  remote = source[/^  remote: (https:\/\/\S+)$/, 1]
  revision = source[/^  revision: ([0-9a-f]{40})$/, 1]
  abort "Git-sourced Ruby tool must have an HTTPS source and exact revision" unless remote && revision
  source.scan(/^    ([^\s(]+) \(([^)]+)\)$/).each do |name, version|
    packages << package(name: name, version: version, ecosystem: "gem", download: "git+#{remote}@#{revision}")
  end
end

sandbox = (ROOT / "Services/WALIMediaSandbox/Containerfile").read
sandbox.scan(/^ARG (FFMPEG|KVAZAAR)_VERSION=([^\s]+)\nARG \1_SHA256=([a-f0-9]{64})/).each do |name, version, digest|
  dependency = name == "FFMPEG" ? "ffmpeg" : "kvazaar"
  packages << package(name: dependency, version: version, ecosystem: "generic", checksum: digest)
end
sandbox.scan(/^FROM(?:\s+--platform=\S+)?\s+([^@\s]+)@sha256:([a-f0-9]{64})/).uniq.each do |image, digest|
  packages << package(name: image, version: "sha256:#{digest}", ecosystem: "oci", checksum: digest)
end

model = JSON.parse((ROOT / "Services/WALIClassifier/model-manifest.json").read)
packages << package(
  name: model.fetch("model_id"), version: model.fetch("upstream_revision"), ecosystem: "generic",
  checksum: model.fetch("artifact_set_digest"), download: "https://huggingface.co/#{model.fetch("model_id")}"
)

packages.uniq! { |item| item.fetch("SPDXID") }
packages.sort_by! { |item| item.fetch("SPDXID") }

document = {
  "spdxVersion" => "SPDX-2.3",
  "dataLicense" => "CC0-1.0",
  "SPDXID" => "SPDXRef-DOCUMENT",
  "name" => "WALI marketplace dependency inventory",
  "documentNamespace" => "https://github.com/TryCleanMcp/WALI/sbom/wali-marketplace-v1",
  "creationInfo" => {
    "created" => "2026-09-01T00:00:00Z",
    "creators" => ["Organization: WALI contributors"],
    "licenseListVersion" => "3.26"
  },
  "documentDescribes" => packages.map { |item| item.fetch("SPDXID") },
  "packages" => packages
}

rendered = JSON.pretty_generate(document) + "\n"
if ARGV.include?("--check")
  abort "SBOM is missing; run scripts/generate-sbom.sh" unless OUTPUT.file?
  abort "SBOM is stale; run scripts/generate-sbom.sh" unless OUTPUT.read == rendered
else
  OUTPUT.dirname.mkpath
  OUTPUT.write(rendered)
end
