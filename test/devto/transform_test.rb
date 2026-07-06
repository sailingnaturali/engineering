require "minitest/autorun"
require_relative "../../lib/devto/transform"
require_relative "../../lib/devto/post"

class TransformTagsTest < Minitest::Test
  def test_squashes_hyphens_and_uppercase
    assert_equal %w[homeassistant selfhosted voiceassistant ai],
                 Devto::Transform.derive_tags(%w[HomeAssistant self-hosted voice-assistant ai hassil])
  end

  def test_truncates_to_four
    assert_equal 4, Devto::Transform.derive_tags(%w[a b c d e f]).length
  end

  def test_dedupes_after_squashing
    # "self-hosted" and "selfhosted" collapse to one; result keeps first 4 distinct
    assert_equal %w[selfhosted ai mcp signalk],
                 Devto::Transform.derive_tags(%w[self-hosted selfhosted ai mcp signalk])
  end

  def test_drops_empty_after_squash
    assert_equal %w[ai mcp], Devto::Transform.derive_tags(["---", "ai", "  ", "mcp"])
  end
end

class TransformAbsolutizeTest < Minitest::Test
  SITE = "https://engineering.sailingnaturali.com"

  def test_rewrites_root_relative_link
    out = Devto::Transform.absolutize("See [docs](/launchd-minimal-path/).", SITE)
    assert_includes out, "[docs](#{SITE}/launchd-minimal-path/)"
  end

  def test_rewrites_root_relative_image_and_html_src
    md = "![pic](/img/a.png) and <img src=\"/img/b.png\">"
    out = Devto::Transform.absolutize(md, SITE)
    assert_includes out, "![pic](#{SITE}/img/a.png)"
    assert_includes out, "src=\"#{SITE}/img/b.png\""
  end

  def test_leaves_external_anchor_and_protocol_relative
    md = "[x](https://example.com) [y](#sec) [z](//cdn.example.com/a.js)"
    assert_equal md, Devto::Transform.absolutize(md, SITE)
  end

  def test_does_not_rewrite_inside_code_fence
    md = "before [a](/foo)\n```\n[b](/keep-me)\n```\nafter [c](/bar)"
    out = Devto::Transform.absolutize(md, SITE)
    assert_includes out, "[a](#{SITE}/foo)"
    assert_includes out, "[b](/keep-me)"      # untouched inside fence
    assert_includes out, "[c](#{SITE}/bar)"
  end
end

class TransformStripRawTest < Minitest::Test
  def test_strips_standalone_raw_and_endraw_lines
    md = "{% raw %}\nbody with {{ value_json.trace_id }}\n{% endraw %}\n"
    assert_equal "body with {{ value_json.trace_id }}\n",
                 Devto::Transform.strip_raw_tags(md)
  end

  def test_keeps_raw_tags_inside_code_fence
    md = "{% raw %}\n```\n{% raw %}\n```\n{% endraw %}\n"
    assert_equal "```\n{% raw %}\n```\n", Devto::Transform.strip_raw_tags(md)
  end

  def test_noop_without_raw_tags
    md = "plain body\n```\ncode\n```\n"
    assert_equal md, Devto::Transform.strip_raw_tags(md)
  end
end

class TransformPayloadTest < Minitest::Test
  SITE = "https://engineering.sailingnaturali.com"

  def sample_post
    path = File.expand_path("../fixtures/posts/2026-01-02-sample-post.md", __dir__)
    Devto::Post.parse(path)
  end

  def test_payload_shape
    payload = Devto::Transform.build_payload(sample_post, SITE)
    art = payload[:article]
    assert_equal "A sample post about MCP and SignalK", art[:title]
    assert_equal "#{SITE}/sample-post/", art[:canonical_url]
    assert_equal true, art[:published]
    assert_equal %w[mcp signalk voiceassistant ai], art[:tags]
    assert_includes art[:body_markdown], "[the docs](#{SITE}/launchd-minimal-path/)"
    assert_includes art[:body_markdown], "[x](/keep-me)" # fence preserved
  end
end
