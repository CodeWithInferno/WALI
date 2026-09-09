# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "uri"
require "yaml"

# Reviewed source inputs, independent of Xcode's ignored/generated workspace.
module SwiftDependencyInventory
  module_function

  def load(root)
    lock = JSON.parse((root / "Config/Package.resolved").read)
    raise "Unsupported canonical Swift lock format" unless lock["version"] == 3 && lock["pins"].is_a?(Array)

    pins = unique_records(lock.fetch("pins"), "canonical Swift lock")
    pins.each_value do |pin|
      state = pin.fetch("state")
      unless pin["kind"] == "remoteSourceControl" &&
             state["revision"].is_a?(String) && state["revision"].match?(/\A[0-9a-f]{40}\z/) &&
             state["version"].is_a?(String) && state["version"].match?(/\A\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?\z/)
        raise "#{pin['identity']}: Swift dependency must have an exact version and revision"
      end
      uri = URI.parse(pin.fetch("location"))
      unless uri.is_a?(URI::HTTPS) && uri.host && !uri.userinfo && !uri.query && !uri.fragment
        raise "#{pin['identity']}: unsupported Swift dependency source"
      end
    end

    project = YAML.safe_load((root / "project.yml").read)
    project.fetch("packages").each do |name, declaration|
      next if declaration.key?("path")

      url = declaration.fetch("url")
      identity = File.basename(URI.parse(url).path).sub(/\.git\z/, "").downcase
      pin = pins[identity]
      raise "#{identity}: project dependency is missing from Config/Package.resolved" unless pin
      unless declaration["exactVersion"] == pin.dig("state", "version") && pin["location"] == url
        raise "#{name}: project exactVersion/source differs from Config/Package.resolved"
      end
    end
    raise "Canonical Swift lock must not be empty" if pins.empty?

    directory = root / "Resources/ThirdPartyLicenses"
    %w[LICENSE NOTICE].each do |name|
      copy = directory / "WALI-#{name}.txt"
      unless copy.file? && !copy.symlink? && copy.binread == (root / name).binread
        raise "Bundled WALI #{name} differs from the project notice"
      end
    end
    manifest = JSON.parse((directory / "manifest.json").read)
    raise "Unsupported Swift license manifest" unless manifest["schema_version"] == 1
    notices = unique_records(manifest.fetch("packages"), "Swift license manifest")
    missing = pins.keys - notices.keys
    stale = notices.keys - pins.keys
    raise "Missing Swift license records: #{missing.sort.join(', ')}" unless missing.empty?
    raise "Unresolved Swift license records: #{stale.sort.join(', ')}" unless stale.empty?

    pins.values.sort_by { |pin| pin.fetch("identity") }.map do |pin|
      record = notices.fetch(pin.fetch("identity"))
      unless record["version"] == pin.dig("state", "version") &&
             record["revision"] == pin.dig("state", "revision") && record["source_url"] == pin["location"]
        raise "#{pin['identity']}: license provenance differs from the resolved Swift dependency"
      end
      raise "#{pin['identity']}: missing license expression" unless record["license"].is_a?(String) && !record["license"].empty?
      files = record.fetch("files")
      raise "#{pin['identity']}: missing upstream license files" unless files.is_a?(Array) && !files.empty?
      files.each do |file|
        name = file.fetch("path")
        unless name.is_a?(String) && name.match?(/\A[A-Za-z0-9_.-]+\.txt\z/) && !name.start_with?(".")
          raise "#{pin['identity']}: unsafe license filename"
        end
        path = directory / name
        unless path.file? && !path.symlink? && Digest::SHA256.file(path).hexdigest == file.fetch("sha256")
          raise "Missing or altered upstream license: #{name}"
        end
      end
      pin.merge("license" => record.fetch("license"))
    end
  end

  def unique_records(records, label)
    raise "#{label} must be an array" unless records.is_a?(Array)
    records.each_with_object({}) do |record, result|
      identity = record.fetch("identity")
      unless identity.is_a?(String) && identity.match?(/\A[a-z0-9][a-z0-9.-]*\z/)
        raise "#{label} has an invalid package identity"
      end
      raise "#{label} repeats #{identity}" if result.key?(identity)
      result[identity] = record
    end
  end
end
