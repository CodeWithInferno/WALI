#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"

options = {}
OptionParser.new do |parser|
  parser.on("--configuration VALUE") { |value| options[:configuration] = value }
  parser.on("--label VALUE") { |value| options[:label] = value }
  parser.on("--bundle-identifier VALUE") { |value| options[:bundle_identifier] = value }
  parser.on("--team VALUE") { |value| options[:team] = value }
  parser.on("--app-group VALUE") { |value| options[:app_group] = value }
end.parse!

required = %i[configuration label bundle_identifier team app_group]
missing = required.reject { |key| options.key?(key) }
abort("signature metadata validator missing options: #{missing.join(', ')}") if missing.any?
abort("signature metadata validator only accepts Development metadata") unless options[:configuration] == "Development"
abort("Development signature metadata requires a nonempty team") if options[:team].to_s.empty?

begin
  metadata = JSON.parse($stdin.read)
rescue JSON::ParserError => exception
  abort("invalid signature metadata JSON: #{exception.message}")
end

label = options.fetch(:label)
team = options.fetch(:team)
expected_application_identifier = "#{team}.#{options.fetch(:bundle_identifier)}"
expected_group = options.fetch(:app_group)
entitlements = metadata["entitlements"]
entitlements = {} unless entitlements.is_a?(Hash)

failure =
  if metadata["sealed"] != true
    "#{label} must have a bundle seal"
  elsif metadata["strict_valid"] != true
    "#{label} failed strict code-signature validation"
  elsif metadata["signature"] == "adhoc"
    "Development verification rejects ad-hoc signature for #{label}"
  elsif !Array(metadata["authorities"]).any? { |authority| authority.start_with?("Apple Development:") }
    "#{label} must be signed by an Apple Development: authority"
  elsif metadata["team_identifier"] != team
    "#{label} TeamIdentifier must equal DEVELOPMENT_TEAM #{team}"
  elsif metadata["runtime"] != true
    "#{label} signed configuration is missing hardened runtime"
  end

team_entitlement = entitlements["com.apple.developer.team-identifier"]
application_identifier =
  entitlements["com.apple.application-identifier"] ||
  entitlements["application-identifier"]
groups = entitlements["com.apple.security.application-groups"]

if failure.nil? && !expected_group.empty?
  failure =
    if team_entitlement.to_s.empty?
      "#{label} team entitlement is required"
    elsif team_entitlement != team
      "#{label} team entitlement must equal DEVELOPMENT_TEAM #{team}"
    elsif application_identifier.to_s.empty?
      "#{label} application identifier is required"
    elsif application_identifier != expected_application_identifier
      "#{label} application identifier must be #{expected_application_identifier}"
    elsif groups != [expected_group]
      "#{label} signed application group must be #{expected_group}"
    end
elsif failure.nil?
  failure =
    if groups.is_a?(Array) && !groups.empty?
      "#{label} must not claim an application group"
    elsif !groups.nil? && groups != []
      "#{label} must not claim an application group"
    elsif !team_entitlement.nil? && team_entitlement != team
      "#{label} team entitlement must equal DEVELOPMENT_TEAM #{team}"
    elsif !application_identifier.nil? &&
          application_identifier != expected_application_identifier
      "#{label} application identifier must be #{expected_application_identifier}"
    end
end

abort(failure) if failure
puts "Validated #{label} Development signature metadata"
