require "yaml"
require "date"

module Devto
  class Post
    attr_reader :title, :slug, :date, :tags, :body

    def self.parse(path)
      content = File.read(path)
      m = content.match(/\A---\s*\n(.*?\n)---\s*\n(.*)\z/m)
      raise "no front matter in #{path}" unless m
      fm = YAML.safe_load(m[1], permitted_classes: [Date, Time]) || {}
      body = m[2]
      basename = File.basename(path, ".md")
      slug = basename.sub(/\A\d{4}-\d{2}-\d{2}-/, "")
      file_date = Date.parse(basename[/\A\d{4}-\d{2}-\d{2}/])
      date = fm["date"].is_a?(Date) ? fm["date"] : file_date
      new(title: fm["title"], slug: slug, date: date,
          tags: Array(fm["tags"]), body: body,
          published_flag: fm.key?("published") ? fm["published"] : nil)
    end

    def initialize(title:, slug:, date:, tags:, body:, published_flag:)
      @title = title
      @slug = slug
      @date = date
      @tags = tags
      @body = body
      @published_flag = published_flag
    end

    def publishable?(today: Date.today)
      @published_flag != false && @date <= today
    end

    def canonical_url(site_url)
      "#{site_url}/#{slug}/"
    end
  end
end
