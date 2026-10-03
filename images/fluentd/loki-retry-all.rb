require 'fluent/plugin/out_loki'

# The pinned 1.3.0 plugin retries 429/5xx but otherwise returns successfully on
# HTTP errors, which acknowledges and discards the buffered chunk. Preserve the
# chunk on every non-2xx response; configuration errors must remain visible and
# retryable, never silently consume Nginx evidence. Network exceptions already
# propagate from the upstream client.
module MtsLokiRetryAll
  private

  def loki_http_request(body, tenant)
    response = super
    unless response.is_a?(Net::HTTPSuccess)
      raise Fluent::Plugin::LokiOutput::LogPostError,
            "Loki rejected buffered chunk: HTTP #{response.code} #{response.message}"
    end
    response
  end
end

Fluent::Plugin::LokiOutput.prepend(MtsLokiRetryAll)
