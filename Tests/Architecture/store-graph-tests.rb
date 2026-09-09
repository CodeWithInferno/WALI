#!/usr/bin/env ruby
# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "psych"
require_relative "../../scripts/check-store-graph"

class StoreGraphTests < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def fixture
    Dir.mktmpdir("wali-store-graph-") do |root|
      %w[project.yml project-common.yml project-store.yml].each { |name| FileUtils.cp(File.join(ROOT, name), root) }
      FileUtils.mkdir_p(File.join(root, "Config"))
      %w[Base.xcconfig StoreDevelopment.xcconfig AppStore.xcconfig Store-WALI.entitlements Store-WALIAgent.entitlements Store-WALITranscoder.entitlements].each do |name|
        FileUtils.cp(File.join(ROOT, "Config", name), File.join(root, "Config", name))
      end
      FileUtils.cp_r(File.join(ROOT, "Config", "StoreLaunchAgents"), File.join(root, "Config"))
      yield root
    end
  end

  def mutate(root, file = "project-store.yml")
    path = File.join(root, file)
    data = Psych.safe_load(File.read(path), aliases: false)
    yield data
    File.write(path, Psych.dump(data))
  end

  def rejected(message)
    fixture do |root|
      yield root
      error = assert_raises(StoreGraphChecker::Error) { StoreGraphChecker.new(root).check! }
      assert_includes error.message, message
    end
  end

  def test_valid_store_graph
    fixture { |root| assert StoreGraphChecker.new(root).check! }
  end

  def test_helper_dependency_is_rejected
    rejected("helper") do |root|
      mutate(root) { |d| d["targets"]["WALI"]["dependencies"] = [{"target" => "WALILockScreenHelper", "embed" => true, "link" => false}] }
    end
  end

  def test_helper_wire_dependency_is_rejected
    rejected("helper") do |root|
      mutate(root) { |d| d["targets"]["WALIAgentRuntime"]["dependencies"] = [{"package" => "WALICore", "product" => "WALILockScreenWire"}] }
    end
  end

  def test_recursive_lock_screen_sources_are_rejected
    rejected("LockScreen") do |root|
      mutate(root) { |d| d["targets"]["WALIAgentRuntime"]["sources:REPLACE"] = [{"path" => "Sources/WALIAgentRuntime"}] }
    end
  end

  def test_helper_info_is_rejected
    rejected("helper") do |root|
      mutate(root) { |d| d["targets"]["WALI"]["info"]["properties"]["WALILockScreenHelperLaunchAgentPlistName"] = "helper.plist" }
    end
  end

  def test_worker_group_is_rejected
    rejected("worker entitlements") do |root|
      path = File.join(root, "Config", "Store-WALITranscoder.entitlements")
      File.write(path, File.read(path).sub("</dict>", "<key>com.apple.security.application-groups</key><array><string>group.com.wali.store.shared</string></array></dict>"))
    end
  end

  def test_agent_network_is_rejected
    rejected("agent entitlements") do |root|
      path = File.join(root, "Config", "Store-WALIAgent.entitlements")
      File.write(path, File.read(path).sub("</dict>", "<key>com.apple.security.network.client</key><true/></dict>"))
    end
  end

  def test_sandbox_false_is_rejected
    rejected("sandbox") do |root|
      path = File.join(root, "Config", "Store-WALI.entitlements")
      File.write(path, File.read(path).sub("<key>com.apple.security.app-sandbox</key>\n    <true/>", "<key>com.apple.security.app-sandbox</key>\n    <false/>"))
    end
  end

  def test_group_service_identity_is_enforced
    rejected("service") do |root|
      path = File.join(root, "Config", "AppStore.xcconfig")
      File.write(path, File.read(path).sub("group.com.wali.store.shared.agent-control", "com.wali.WALIAgent.control"))
    end
  end

  def test_store_has_no_automatic_launch
    rejected("RunAtLoad") do |root|
      path = File.join(root, "Config", "StoreLaunchAgents", "com.wali.store.WALIAgent.plist")
      File.write(path, File.read(path).sub("<key>RunAtLoad</key>\n    <false/>", "<key>RunAtLoad</key>\n    <true/>"))
    end
  end

  def test_source_flag_cannot_be_removed
    rejected("WALI_APP_STORE") do |root|
      mutate(root) { |d| d["settings"]["base"]["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited)" }
    end
  end
  def test_configuration_cannot_erase_store_condition
    rejected("WALI_APP_STORE") do |root|
      mutate(root) { |d| d["targets"]["WALIAgent"]["settings"]["configs"]["AppStore"]["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "" }
    end
  end

  def test_worker_network_is_rejected
    rejected("worker entitlements") do |root|
      path = File.join(root, "Config", "Store-WALITranscoder.entitlements")
      File.write(path, File.read(path).sub("</dict>", "<key>com.apple.security.network.client</key><true/></dict>"))
    end
  end

  def test_worker_cannot_be_embedded_in_foreground
    rejected("dependencies") do |root|
      mutate(root) { |d| d["targets"]["WALI"]["dependencies"] = [{"target" => "WALITranscoder", "embed" => true, "link" => false}] }
    end
  end

  def test_group_identity_cannot_cross_distribution
    rejected("group identity") do |root|
      path = File.join(root, "Config", "AppStore.xcconfig")
      File.write(path, File.read(path).sub("WALI_APP_GROUP_IDENTIFIER = group.com.wali.store.shared", "WALI_APP_GROUP_IDENTIFIER = group.com.wali.shared"))
    end
  end

  def test_selected_launch_plist_cannot_be_replaced_by_all_channels
    rejected("selected launch plist") do |root|
      mutate(root) { |d| d["targets"]["WALI"].delete("postBuildScripts") }
    end
  end

end
