require "date"
require "stringio"
require_relative "post"
require_relative "transform"
require_relative "client"

module Devto
  class Reconcile
    def initialize(posts_dir:, site_url:, client:, dry_run: false,
                   today: Date.today, io: $stdout, sleep_s: 3)
      @posts_dir = posts_dir
      @site_url = site_url
      @client = client
      @dry_run = dry_run
      @today = today
      @io = io
      @sleep_s = sleep_s
    end

    def run
      existing = @client.existing_canonicals # raises -> aborts before any create
      to_create = publishable_posts.reject do |post|
        existing.include?(post.canonical_url(@site_url))
      end

      @io.puts "#{publishable_posts.length} publishable, " \
               "#{existing.length} on dev.to, #{to_create.length} to create"

      to_create.each_with_index do |post, i|
        payload = Transform.build_payload(post, @site_url)
        canonical = post.canonical_url(@site_url)
        if @dry_run
          @io.puts "would create: #{canonical} tags=#{payload[:article][:tags].inspect}"
          next
        end
        res = create_with_retry(payload)
        raise "create failed for #{canonical}: HTTP #{res.code} #{res.body}" unless res.code == 201
        @io.puts "created: #{canonical}"
        sleep_for(@sleep_s) unless i == to_create.length - 1
      end
      0
    end

    # Overridable so tests don't actually sleep.
    def sleep_for(seconds)
      sleep(seconds) if seconds.positive?
    end

    private

    def publishable_posts
      @publishable_posts ||=
        Dir.glob(File.join(@posts_dir, "*.md"))
           .map { |p| Post.parse(p) }
           .select { |post| post.publishable?(today: @today) }
           .sort_by(&:date)
    end

    def create_with_retry(payload)
      res = @client.create(payload)
      if res.code == 429
        sleep_for(@sleep_s)
        res = @client.create(payload)
      end
      res
    end
  end
end
