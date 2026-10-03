require 'net/http'
require 'digest'

packages = [
  ['fluentd', ENV.fetch('FLUENTD_VERSION'), ENV.fetch('FLUENTD_GEM_SHA256'), '/tmp/fluentd.gem'],
  ['fluent-plugin-grafana-loki', ENV.fetch('FLUENTD_LOKI_PLUGIN_VERSION'),
   ENV.fetch('FLUENTD_LOKI_PLUGIN_GEM_SHA256'), '/tmp/loki-plugin.gem']
]
packages.each do |name, version, checksum, path|
  uri = URI("https://rubygems.org/downloads/#{name}-#{version}.gem")
  response = Net::HTTP.get_response(uri)
  abort "Download failed: #{uri} (#{response.code})" unless response.is_a?(Net::HTTPSuccess)
  actual = Digest::SHA256.hexdigest(response.body)
  abort "Checksum mismatch for #{name} #{version} ruby package: expected #{checksum}, got #{actual}; check the shared platform-specific pin" unless actual == checksum
  File.binwrite(path, response.body)
end
