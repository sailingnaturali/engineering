require "net/http"
require "uri"
require "json"
require "set"

module Devto
  API_BASE = "https://dev.to/api".freeze
  Response = Struct.new(:code, :body)

  class HTTP
    def get(url, headers)
      request(Net::HTTP::Get.new(URI(url)), URI(url), headers)
    end

    def post(url, headers, body)
      req = Net::HTTP::Post.new(URI(url))
      req.body = body
      request(req, URI(url), headers)
    end

    private

    def request(req, uri, headers)
      headers.each { |k, v| req[k] = v }
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
      Response.new(res.code.to_i, res.body)
    end
  end

  class Client
    def initialize(api_key, transport: HTTP.new)
      @api_key = api_key
      @transport = transport
    end

    def existing_canonicals
      res = @transport.get("#{API_BASE}/articles/me/all?per_page=1000",
                           { "api-key" => @api_key })
      raise "dev.to list failed: HTTP #{res.code} #{res.body}" unless res.code == 200
      JSON.parse(res.body).map { |a| a["canonical_url"] }.compact.to_set
    end

    def create(payload)
      @transport.post("#{API_BASE}/articles",
                      { "api-key" => @api_key, "Content-Type" => "application/json" },
                      JSON.generate(payload))
    end
  end
end
