#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "swift-dependency-inventory"

root = Pathname.new(__dir__).parent
abort "usage: ruby scripts/verify-third-party-licenses.rb /path/to/WALI.app" unless ARGV.length == 1

begin
  packages = SwiftDependencyInventory.load(root)
  source = root / "Resources/ThirdPartyLicenses"
  app = Pathname.new(ARGV.fetch(0))
  %w[Contents Contents/Resources Contents/Resources/ThirdPartyLicenses].each do |component|
    directory = app / component
    unless directory.directory? && !directory.symlink?
      raise "License resource directory must be stored inside the app: #{component}"
    end
  end
  destination = app / "Contents/Resources/ThirdPartyLicenses"
  source.children.sort.each do |file|
    next unless file.file?
    bundled = destination / file.basename
    unless bundled.file? && !bundled.symlink? && Digest::SHA256.file(file) == Digest::SHA256.file(bundled)
      raise "Missing or altered bundled license resource: #{file.basename}"
    end
  end
  puts "Verified bundled license notices for #{packages.length} resolved Swift packages"
rescue StandardError => error
  abort "license resources: #{error.message}"
end
