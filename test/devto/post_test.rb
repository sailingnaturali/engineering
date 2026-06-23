require "minitest/autorun"
require "date"
require_relative "../../lib/devto/post"

class PostTest < Minitest::Test
  FIX = File.expand_path("../fixtures/posts", __dir__)

  def sample
    Devto::Post.parse(File.join(FIX, "2026-01-02-sample-post.md"))
  end

  def test_parses_title_slug_date_tags
    p = sample
    assert_equal "A sample post about MCP and SignalK", p.title
    assert_equal "sample-post", p.slug
    assert_equal Date.new(2026, 1, 2), p.date
    assert_equal %w[mcp signalk voice-assistant ai llm], p.tags
  end

  def test_body_excludes_front_matter
    p = sample
    refute_includes p.body, "layout: post"
    assert_includes p.body, "Body line one."
  end

  def test_canonical_url
    p = sample
    assert_equal "https://engineering.sailingnaturali.com/sample-post/",
                 p.canonical_url("https://engineering.sailingnaturali.com")
  end

  def test_publishable_true_for_past_published
    assert sample.publishable?(today: Date.new(2026, 6, 1))
  end

  def test_future_dated_not_publishable
    p = Devto::Post.parse(File.join(FIX, "2026-12-31-future-post.md"))
    refute p.publishable?(today: Date.new(2026, 6, 1))
  end

  def test_unpublished_not_publishable
    p = Devto::Post.parse(File.join(FIX, "2026-01-03-unpublished-post.md"))
    refute p.publishable?(today: Date.new(2026, 6, 1))
  end
end
