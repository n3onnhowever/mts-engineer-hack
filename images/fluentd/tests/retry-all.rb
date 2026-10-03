require '/opt/mts-fluentd/loki-retry-all'

# Exercise the real pinned output's public write/acknowledgement path without
# opening a network connection or sending any fabricated entries to Loki.
class Fluent::Plugin::LokiOutput
  attr_accessor :test_response

  private

  def loki_http_request(_body, _tenant)
    test_response
  end
end

output = Fluent::Plugin::LokiOutput.new
def output.generic_to_loki(_chunk)
  []
end
quiet_log = Object.new
def quiet_log.debug(*)
end
def quiet_log.warn(*)
end
output.define_singleton_method(:log) { quiet_log }

[[Net::HTTPOK, 200], [Net::HTTPBadRequest, 400], [Net::HTTPUnauthorized, 401],
 [Net::HTTPTooManyRequests, 429], [Net::HTTPInternalServerError, 500]].each do |klass, code|
  output.test_response = klass.new('1.1', code.to_s, 'test response')
  raised = false
  begin
    output.write(nil)
  rescue Fluent::Plugin::LokiOutput::LogPostError
    raised = true
  end
  abort "Incorrect chunk acknowledgement for HTTP #{code}" unless raised == (code != 200)
end
puts 'PASS Loki output: 2xx acknowledges; 400/401/429/500 preserve chunk for retries (no HTTP traffic)'
