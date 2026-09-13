#!/usr/bin/env ruby
# frozen_string_literal: true

# Run with bundle exec to check the locked Fastlane action, without building.
require "fastlane"
require "fastlane/actions/build_mac_app"
require "ripper"

root = File.expand_path("../..", __dir__)
tree = Ripper.sexp(File.read(File.join(root, "fastlane/Fastfile")))
raise "Fastfile is not valid Ruby" unless tree
calls = []
visit = lambda do |node|
  next unless node.is_a?(Array)
  if node[0] == :method_add_arg && node.dig(1, 0) == :fcall && node.dig(1, 1, 1) == "build_mac_app"
    pairs = node.dig(2, 1, 1, 0, 1)
    raise "Expected explicit build_mac_app keyword arguments" unless pairs.is_a?(Array)
    options = pairs.to_h do |pair|
      raise "Expected named build_mac_app option" unless pair[0] == :assoc_new && pair.dig(1, 0) == :@label
      [pair[1][1].delete_suffix(":").to_sym, pair[2]]
    end
    calls << options if options.dig(:configuration, 1, 1, 1) == "AppStore"
  end
  node.each { |child| visit.call(child) }
end
visit.call(tree)
raise "Expected exactly one AppStore archive action" unless calls.length == 1
options = calls.fetch(0)
accepted = Fastlane::Actions::BuildMacAppAction.available_options.map(&:key)
unsupported = options.keys - accepted
raise "Unsupported pinned build_mac_app options: #{unsupported.join(', ')}" unless unsupported.empty?
raise "Store archive must export its PKG" unless options.dig(:skip_package_pkg, 1, 1) == "false"
raise "Store archive must retain App Store export" unless options.dig(:export_method, 1, 1, 1) == "app-store"
puts "Store archive uses #{options.length} supported pinned Fastlane options and requires an App Store PKG."
