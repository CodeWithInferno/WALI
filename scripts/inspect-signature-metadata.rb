#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "rexml/document"
require "rexml/xpath"

bundle_path = ARGV.fetch(0)
seal_path = File.join(bundle_path, "Contents", "_CodeSignature", "CodeResources")

_verify_stdout, _verify_stderr, verify_status = Open3.capture3(
  "/usr/bin/codesign", "--verify", "--strict", bundle_path
)
_details_stdout, details_stderr, details_status = Open3.capture3(
  "/usr/bin/codesign", "-dvvv", bundle_path
)
unless details_status.success?
  warn "could not inspect code-signature details for #{bundle_path}"
  exit 1
end

entitlements_stdout, _entitlements_stderr, entitlements_status = Open3.capture3(
  "/usr/bin/codesign", "-d", "--entitlements", ":-", bundle_path
)

details = details_stderr.lines.map(&:strip)
detail_value = lambda do |key|
  prefix = "#{key}="
  details.find { |line| line.start_with?(prefix) }&.delete_prefix(prefix)
end

entitlements = {}
if entitlements_status.success? && !entitlements_stdout.strip.empty?
  begin
    document = REXML::Document.new(entitlements_stdout)
    dictionary = REXML::XPath.first(document, "/plist/dict")
    elements = dictionary ? dictionary.elements.to_a : []
    elements.each_with_index do |element, index|
      next unless element.name == "key"

      value = elements[index + 1]
      next unless value

      entitlements[element.text.to_s] =
        case value.name
        when "string"
          value.text.to_s
        when "array"
          REXML::XPath.match(value, "string").map { |item| item.text.to_s }
        when "true"
          true
        when "false"
          false
        end
    end
  rescue REXML::ParseException => exception
    warn "could not parse code-signature entitlements for #{bundle_path}: #{exception.message}"
    exit 1
  end
end

metadata = {
  "sealed" => File.file?(seal_path) && !File.symlink?(seal_path),
  "strict_valid" => verify_status.success?,
  "signature" => detail_value.call("Signature"),
  "authorities" => details.map do |line|
    line.delete_prefix("Authority=") if line.start_with?("Authority=")
  end.compact,
  "team_identifier" => detail_value.call("TeamIdentifier"),
  "runtime" => details.any? do |line|
    line.start_with?("flags=") && line.match?(/\bruntime\b/)
  end,
  "entitlements" => entitlements
}

puts JSON.generate(metadata)
