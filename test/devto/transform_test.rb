require "minitest/autorun"
require_relative "../../lib/devto/transform"

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
