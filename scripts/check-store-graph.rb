#!/usr/bin/env ruby
# frozen_string_literal: true
require 'json'
require 'open3'
require 'psych'
require 'set'

# XcodeGen resolves includes. Its parsed-json serializer drops package product names,
# so expand our target templates in the lossless JSON form, using XcodeGen merge rules.
module WALIProjectSpec
  def self.merge(base, overlay)
    result = Marshal.load(Marshal.dump(base))
    overlay.each do |key, value|
      if key.end_with?(':REPLACE')
        result[key.delete_suffix(':REPLACE')] = value
      elsif result[key].is_a?(Hash) && value.is_a?(Hash)
        result[key] = merge(result[key], value)
      elsif result[key].is_a?(Array) && value.is_a?(Array)
        result[key] += value
      else
        result[key] = value
      end
    end
    result
  end
  def self.load(root, name)
    path = File.join(root, name)
    raw = Psych.safe_load(File.read(path), aliases: false)
    return raw unless raw.key?('include') || raw.key?('targetTemplates')
    generator = ENV.fetch('XCODEGEN_BIN', 'xcodegen')
    output, errors, status = Open3.capture3(generator, 'dump', '--spec', path, '--project-root', root, '--type', 'json', '--no-env')
    raise "XcodeGen could not resolve #{name}: #{errors}" unless status.success?
    resolved = JSON.parse(output)
    templates = resolved.fetch('targetTemplates', {})
    expand = lambda do |target, stack|
      base = Array(target['templates']).reduce({}) do |memo, key|
        raise "Unknown or cyclic target template #{key}" if stack.include?(key) || !templates.key?(key)
        merge(memo, expand.call(templates.fetch(key), stack + [key]))
      end
      merge(base, target.reject { |key, _| key == 'templates' })
    end
    resolved['targets'] = resolved.fetch('targets').transform_values { |target| expand.call(target, []) }
    resolved
  end
end

class StoreGraphChecker
  class Error < StandardError; end
  CONFIGS = {'StoreDevelopment'=>'store.development', 'AppStore'=>'store'}.freeze
  PRODUCTION = %w[WALI WALIAppRuntime WALICatalogRuntime WALIAgent WALIAgentRuntime WALITranscoder WALITranscoderRuntime WALIUI].freeze
  TESTS = %w[WALIAppTests WALICatalogRuntimeTests WALIAgentTests WALITranscoderTests WALIUITests WALIEndToEndTests].freeze
  def initialize(root)
    @root = File.expand_path(root)
  end
  def check!
    @project = WALIProjectSpec.load(@root, 'project-store.yml')
    direct = WALIProjectSpec.load(@root, 'project.yml')
    @targets = @project.fetch('targets')
    require_value(@project['name']=='WALIStore', 'Store project identity')
    require_value(@project.fetch('configs')=={'StoreDevelopment'=>'debug', 'AppStore'=>'release'}, 'Store configurations')
    require_value(@targets.keys.sort==(PRODUCTION+TESTS).sort, 'Store target registry contains helper or unknown target')
    require_value(@project['packages']==direct['packages'], 'Store package pins must match direct distribution')
    flags=@project.dig('settings','base','SWIFT_ACTIVE_COMPILATION_CONDITIONS').to_s.split
    require_value(flags.include?('WALI_APP_STORE'), 'WALI_APP_STORE is required for every Store target')
    require_value(@project.dig('settings', 'configs').to_h.values.none? { |scope| scope.key?('SWIFT_ACTIVE_COMPILATION_CONDITIONS') }, 'Store configurations must inherit WALI_APP_STORE')
    @targets.each do |name,target|
      require_value(!JSON.generate(target).match?(/WALILockScreen|Config\/LaunchAgents|Sources\/WALILockScreen/i), "#{name} contains helper dependency, resource, source, or Info metadata")
      scopes = [target.dig('settings', 'base')] + target.dig('settings', 'configs').to_h.values
      require_value(scopes.compact.none? { |scope| scope.key?('SWIFT_ACTIVE_COMPILATION_CONDITIONS') }, "#{name} must inherit WALI_APP_STORE")
      expected=Array(direct.dig('targets',name,'dependencies')).reject{|d|[d['target'],d['product']].compact.any?{|v|v.start_with?('WALILockScreen')}}
      require_value(dependencies(target)==dependencies({'dependencies'=>expected}), "#{name} Store dependencies differ from approved helper-free direct graph")
    end
    require_value(@targets.dig('WALI', 'postBuildScripts') == [{
      'name' => 'Embed selected Store launch agent', 'path' => 'scripts/embed-store-launch-agent.sh',
      'inputFiles' => ['$(SRCROOT)/Config/StoreLaunchAgents/$(WALI_AGENT_BUNDLE_IDENTIFIER).plist'],
      'outputFiles' => ['$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Library/LaunchAgents/com.wali.store.development.WALIAgent.plist', '$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Library/LaunchAgents/com.wali.store.WALIAgent.plist'],
      'basedOnDependencyAnalysis' => false
    }], 'Store must embed only the selected launch plist')
    agent_sources=@targets.dig('WALIAgentRuntime','sources')
    require_value(agent_sources.length==1 && agent_sources.first['path']=='Sources/WALIAgentRuntime' && agent_sources.first['excludes']==['LockScreen/**'], 'Store agent must exclude LockScreen/** at source membership')
    require_value(@targets.dig('WALIAgentTests','sources').any?{|s|s['excludes'].include?('WALIAgentTests.swift')}, 'Store tests must exclude the direct helper suite')
    expected={'WALI'=>['WALIAgent','Contents/Library/LoginItems'],'WALIAgent'=>['WALITranscoder','Contents/XPCServices']}
    PRODUCTION.each do |name|
      embedded=Array(@targets[name]['dependencies']).select{|d|d['embed']==true}
      if expected[name]
        child,path=expected[name]
        require_value(embedded.length==1 && embedded.first['target']==child && embedded.first['link']==false && embedded.first['codeSign']==true && embedded.first['copy']=={'destination'=>'wrapper','subpath'=>path}, "#{name} embedding contract")
      else
        require_value(embedded.empty?, "#{name} unexpected embedded executable")
      end
    end
    groups=['$(WALI_APP_GROUP_IDENTIFIER)']
    sandbox={'com.apple.security.app-sandbox'=>true}
    app=sandbox.merge('com.apple.security.application-groups'=>groups,'com.apple.security.network.client'=>true,'com.apple.security.files.user-selected.read-only'=>true,'com.apple.security.files.bookmarks.app-scope'=>true,'com.apple.developer.applesignin'=>['Default'])
    agent=sandbox.merge('com.apple.security.application-groups'=>groups,'com.apple.security.files.bookmarks.app-scope'=>true)
    {'WALI'=>[app,'app sandbox entitlements'],'WALIAgent'=>[agent,'agent entitlements'],'WALITranscoder'=>[sandbox,'worker entitlements']}.each do |name,(expected,label)|
      path="Config/Store-#{name}.entitlements"
      require_value(@targets.dig(name,'settings','base','CODE_SIGN_ENTITLEMENTS')==path, "#{name} Store entitlements setting")
      require_value(plist(path)==expected,label)
      require_value(@targets.dig(name,'info','properties','WALIDistribution')=='store', "#{name} distribution metadata")
    end
    require_value(@targets.dig('WALI','info','properties','WALIExpectedAgentBundleIdentifier')=='$(WALI_AGENT_BUNDLE_IDENTIFIER)', 'foreground exact agent identity')
    require_value(@targets.dig('WALIAgent','info','properties','WALIExpectedClientBundleIdentifier')=='$(WALI_APP_BUNDLE_IDENTIFIER)', 'agent exact client identity')
    CONFIGS.each do |config,part|
      require_value(@project.dig('configFiles',config)=="Config/#{config}.xcconfig", "#{config} config file")
      settings=xcconfig("Config/#{config}.xcconfig")
      require_value(settings.keys.none?{|k|k.include?('LOCK_SCREEN_HELPER')}, "#{config} helper configuration")
      %w[APP AGENT TRANSCODER].zip(%w[WALI WALIAgent WALITranscoder]).each do |role,name|
        require_value(settings["WALI_#{role}_BUNDLE_IDENTIFIER"]=="com.wali.#{part}.#{name}", "#{config} #{name} bundle identity")
      end
      group="group.com.wali.#{part}.shared"
      require_value(settings['WALI_APP_GROUP_IDENTIFIER']==group,'Store app group identity')
      require_value(settings['WALI_AGENT_CONTROL_SERVICE_NAME']==group+'.agent-control','Store group-prefixed service identity')
      launch=plist("Config/StoreLaunchAgents/com.wali.#{part}.WALIAgent.plist")
      require_value(launch['RunAtLoad']==false,'Store RunAtLoad must be false')
      require_value(launch['KeepAlive']=={'Crashed'=>true},'Store KeepAlive must only restart crashes')
      require_value(launch['Label']=="com.wali.#{part}.WALIAgent" && launch['MachServices']=={group+'.agent-control'=>true},'Store launch service identity')
      require_value(launch['BundleProgram']=='Contents/Library/LoginItems/WALIAgent.app/Contents/MacOS/WALIAgent','Store launch BundleProgram')
      require_value(launch.keys.sort==%w[Label BundleProgram MachServices RunAtLoad KeepAlive ProcessType].sort,'Store launch plist key set')
    end
    true
  rescue Error
    raise
  rescue StandardError => e
    raise Error, e.message
  end
  private
  def require_value(value,message)
    raise Error,message unless value
  end
  def dependencies(target)
    Array(target['dependencies']).map{|d|d.reject{|_,v|v.nil?}}.sort_by{|d|JSON.generate(d.sort.to_h)}
  end
  def plist(relative)
    out,err,status=Open3.capture3('/usr/bin/plutil','-convert','json','-o','-',File.join(@root,relative))
    raise Error,"invalid #{relative}: #{err}" unless status.success?
    JSON.parse(out)
  end
  def xcconfig(relative, stack=[])
    path=File.expand_path(relative,@root)
    require_value(path.start_with?(@root+'/') && !stack.include?(path),'Store xcconfig include escapes root or cycles')
    result={}
    File.readlines(path).each do |line|
      if (m=line.match(/^#include(\?)? "([^"]+)"/))
        child=File.expand_path(m[2],File.dirname(path))
        # Optional local provisioning files are intentionally not policy authority.
        next if m[1] && m[2].end_with?('.local.xcconfig')
        result.merge!(xcconfig(child,stack+[path]))
      elsif (m=line.match(/^([A-Z_]+) = (.*)$/))
        result[m[1]]=m[2].strip
      end
    end
    result
  end
end
if $PROGRAM_NAME==__FILE__
  begin
    StoreGraphChecker.new(ARGV[0] || File.expand_path('..',__dir__)).check!
    puts 'Store graph checks passed (structural evidence only; signed sandbox feasibility remains required)'
  rescue StoreGraphChecker::Error => e
    warn "Store graph violation: #{e.message}"
    exit 1
  end
end
