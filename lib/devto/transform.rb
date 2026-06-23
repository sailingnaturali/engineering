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
  end
end
