#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "optparse"
require "thread"
require "uri"

options = {requests: 120, concurrency: 8, environment: nil}
OptionParser.new do |parser|
  parser.on("--environment NAME") { |value| options[:environment] = value }
  parser.on("--requests N", Integer) { |value| options[:requests] = value }
  parser.on("--concurrency N", Integer) { |value| options[:concurrency] = value }
end.parse!

abort "only the staging environment is accepted" unless options[:environment] == "staging"
abort "requests must be 1..5000" unless (1..5_000).cover?(options[:requests])
abort "concurrency must be 1..64" unless (1..64).cover?(options[:concurrency])

base = URI.parse(ENV.fetch("WALI_CATALOG_BASE_URL"))
abort "WALI_CATALOG_BASE_URL must be an origin-only HTTPS URL" unless base.scheme == "https" && base.host &&
  base.userinfo.nil? && (base.path.empty? || base.path == "/") && base.query.nil? && base.fragment.nil?
api_key = ENV.fetch("WALI_CATALOG_API_KEY")
abort "WALI_CATALOG_API_KEY is empty" if api_key.empty?
wallpaper_id = ENV["WALI_LOAD_TEST_WALLPAPER_ID"]
abort "WALI_LOAD_TEST_WALLPAPER_ID is malformed" if wallpaper_id && !wallpaper_id.match?(/\A[0-9a-f-]{36}\z/)

requests = [
  ["catalog_home_v1", {locale: "en-US", rating_ceiling: "everyone"}],
  ["catalog_search_v1", {query: "nature", filters: {}, cursor: nil, limit: 24}]
]
requests << ["catalog_wallpaper_detail_v1", {wallpaper_id: wallpaper_id}] if wallpaper_id

queue = Queue.new
options[:requests].times { |index| queue << requests[index % requests.length] }
latencies = []
statuses = Hash.new(0)
mutex = Mutex.new

workers = options[:concurrency].times.map do
  Thread.new do
    loop do
      endpoint, body = queue.pop(true)
      uri = URI.join(base.to_s, "/rest/v1/rpc/#{endpoint}")
      request = Net::HTTP::Post.new(uri)
      request["apikey"] = api_key
      request["Authorization"] = "Bearer #{api_key}"
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request.body = JSON.generate(body)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = Net::HTTP.start(
        uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10,
        verify_mode: OpenSSL::SSL::VERIFY_PEER
      ) { |http| http.request(request) }
      elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000
      mutex.synchronize do
        latencies << elapsed
        statuses[response.code.to_i] += 1
      end
    rescue ThreadError
      break
    rescue StandardError
      mutex.synchronize { statuses[0] += 1 }
    end
  end
end
workers.each(&:join)

sorted = latencies.sort
percentile = lambda do |ratio|
  next 0.0 if sorted.empty?
  sorted[[(sorted.length * ratio).ceil - 1, 0].max]
end
errors = statuses.sum { |code, count| code.between?(200, 299) ? 0 : count }
error_rate = errors.fdiv(options[:requests])
result = {
  environment: options[:environment], host: base.host, requests: options[:requests],
  concurrency: options[:concurrency], successful_timings: sorted.length,
  median_ms: percentile.call(0.50).round(2), p95_ms: percentile.call(0.95).round(2),
  error_rate: error_rate.round(4), statuses: statuses.sort.to_h
}
puts JSON.pretty_generate(result)

abort "catalog load thresholds failed" if error_rate > 0.01 || percentile.call(0.95) > 1_500
