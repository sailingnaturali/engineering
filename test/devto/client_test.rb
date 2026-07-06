require "minitest/autorun"
require "json"
require_relative "../../lib/devto/client"

class FakeTransport
  attr_reader :posted, :get_url, :get_headers
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

class PagingTransport
  def get(url, _headers)
    page = url[/[?&]page=(\d+)/, 1].to_i
    pages = [
      [{ "canonical_url" => "https://x/a/" }, { "canonical_url" => "https://x/b/" }], # full page (==per_page)
      [{ "canonical_url" => "https://x/c/" }]                                          # short page -> stop
    ]
    Devto::Response.new(200, JSON.generate(pages[page - 1] || []))
  end
  def post(*) = raise "not used"
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
    assert_includes t.get_url, "/articles/me/all"
    assert_includes t.get_url, "per_page=1000"
    assert_equal "KEY", t.get_headers["api-key"]
  end

  def test_existing_canonicals_raises_on_non_200
    t = FakeTransport.new(get_response: Devto::Response.new(401, "no"))
    client = Devto::Client.new("KEY", transport: t)
    assert_raises(RuntimeError) { client.existing_canonicals }
  end

  def test_existing_canonicals_paginates
    client = Devto::Client.new("KEY", transport: PagingTransport.new, per_page: 2)
    assert_equal Set["https://x/a/", "https://x/b/", "https://x/c/"], client.existing_canonicals
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

class ClientCommentsTest < Minitest::Test
  def test_comments_for_fetches_and_parses
    body = JSON.generate([{ "id_code" => "abc", "body_html" => "<p>hi</p>", "children" => [] }])
    t = FakeTransport.new(get_response: Devto::Response.new(200, body))
    client = Devto::Client.new("KEY", transport: t)
    comments = client.comments_for(123)
    assert_equal "abc", comments.first["id_code"]
    assert_includes t.get_url, "/comments?a_id=123"
    assert_equal "KEY", t.get_headers["api-key"]
  end

  def test_comments_for_raises_on_non_200
    t = FakeTransport.new(get_response: Devto::Response.new(500, "boom"))
    client = Devto::Client.new("KEY", transport: t)
    assert_raises(RuntimeError) { client.comments_for(123) }
  end

  def test_my_articles_returns_full_objects
    body = JSON.generate([{ "id" => 1, "title" => "T", "comments_count" => 2, "canonical_url" => "https://x/a/" }])
    t = FakeTransport.new(get_response: Devto::Response.new(200, body))
    client = Devto::Client.new("KEY", transport: t)
    articles = client.my_articles
    assert_equal 2, articles.first["comments_count"]
    assert_equal Set["https://x/a/"], client.existing_canonicals
  end
end
