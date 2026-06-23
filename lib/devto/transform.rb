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
  end
end
