module Devto
  module Transform
    module_function

    def derive_tags(tags)
      Array(tags)
        .map { |t| t.to_s.downcase.gsub(/[^a-z0-9]/, "") }
        .reject(&:empty?)
        .uniq
        .first(4)
    end

    # Markdown link/image: ](/path  — single leading slash only (not //)
    MD_LINK = %r{(!?\[[^\]]*\]\()(/(?!/)[^)\s]+)}
    # HTML attribute: src="/path" or href='/path'
    HTML_ATTR = %r{((?:src|href)=["'])(/(?!/)[^"']+)}

    # A line that is only a Jekyll {% raw %} / {% endraw %} guard
    RAW_TAG_LINE = /\A\s*\{%\s*(?:end)?raw\s*%\}\s*\z/

    # Posts wrap their bodies in {% raw %}…{% endraw %} so Jekyll's Liquid
    # pass doesn't eat template syntax ({{ … }}) in code blocks. dev.to gets
    # the raw markdown, where those tags would show up literally (dev.to has
    # its own Liquid-tag syntax) — drop them. Fence-aware so a code block
    # demonstrating the tags themselves is left alone.
    def strip_raw_tags(body)
      in_fence = false
      body.each_line.reject do |line|
        in_fence = !in_fence if line.lstrip.start_with?("```", "~~~")
        !in_fence && line.match?(RAW_TAG_LINE)
      end.join
    end

    def absolutize(body, site_url)
      in_fence = false
      body.each_line.map do |line|
        if line.lstrip.start_with?("```", "~~~")
          in_fence = !in_fence
          next line
        end
        next line if in_fence
        line
          .gsub(MD_LINK) { "#{$1}#{site_url}#{$2}" }
          .gsub(HTML_ATTR) { "#{$1}#{site_url}#{$2}" }
      end.join
    end

    def build_payload(post, site_url)
      {
        article: {
          title: post.title,
          body_markdown: absolutize(strip_raw_tags(post.body), site_url),
          canonical_url: post.canonical_url(site_url),
          tags: derive_tags(post.tags),
          published: true
        }
      }
    end
  end
end
