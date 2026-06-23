require "minitest/autorun"
require "json"
require_relative "../../lib/devto/client"

class FakeTransport
  attr_reader :posted
  def initialize(get_response:, post_response: nil)
    @get_response = get_response
    @post_response = post_response
    @posted = []
  end

  def get(url, headers)
    @get_url = url
    @get_headers = headers
    @get_response
  end

  def post(url, headers, body)
    @posted << { url: url, headers: headers, body: body }
    @post_response
  end
end

class ClientTest < Minitest::Test
  def test_existing_canonicals_collects_non_nil
    body = JSON.generate([
      { "canonical_url" => "https://x/a/" },
      { "canonical_url" => nil },
      { "canonical_url" => "https://x/b/" }
    ])
    t = FakeTransport.new(get_response: Devto::Response.new(200, body))
    client = Devto::Client.new("KEY", transport: t)
    assert_equal Set["https://x/a/", "https://x/b/"], client.existing_canonicals
  end

  def test_existing_canonicals_raises_on_non_200
    t = FakeTransport.new(get_response: Devto::Response.new(401, "no"))
    client = Devto::Client.new("KEY", transport: t)
    assert_raises(RuntimeError) { client.existing_canonicals }
  end

  def test_create_posts_json_with_api_key
    t = FakeTransport.new(get_response: Devto::Response.new(200, "[]"),
                          post_response: Devto::Response.new(201, "{}"))
    client = Devto::Client.new("KEY", transport: t)
    res = client.create({ article: { title: "T" } })
    assert_equal 201, res.code
    sent = t.posted.first
    assert_equal "https://dev.to/api/articles", sent[:url]
    assert_equal "KEY", sent[:headers]["api-key"]
    assert_equal "application/json", sent[:headers]["Content-Type"]
    assert_equal({ "article" => { "title" => "T" } }, JSON.parse(sent[:body]))
  end
end
