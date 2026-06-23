require "minitest/autorun"
require "date"
require "set"
require_relative "../../lib/devto/reconcile"

class RecorderClient
  attr_reader :created
  def initialize(existing:, responses: nil)
    @existing = existing
    @responses = responses || []
    @created = []
  end
  def existing_canonicals = @existing
  def create(payload)
    @created << payload
    @responses.shift || Devto::Response.new(201, "{}")
  end
end

class FailingListClient
  def existing_canonicals = raise("boom")
  def create(_) = raise("must not be called")
end

class ReconcileTest < Minitest::Test
  FIX = File.expand_path("../fixtures/posts", __dir__)
  SITE = "https://engineering.sailingnaturali.com"

  def reconcile(client:, dry_run: false)
    r = Devto::Reconcile.new(posts_dir: FIX, site_url: SITE, client: client,
                             dry_run: dry_run, today: Date.new(2026, 6, 1),
                             io: StringIO.new, sleep_s: 0)
    def r.sleep_for(_) = nil
    r
  end

  def test_creates_only_missing_publishable_posts
    # sample-post is the only publishable fixture; future + unpublished are skipped
    client = RecorderClient.new(existing: Set.new)
    assert_equal 0, reconcile(client: client).run
    assert_equal 1, client.created.length
    assert_equal "#{SITE}/sample-post/", client.created.first[:article][:canonical_url]
  end

  def test_skips_already_synced
    client = RecorderClient.new(existing: Set["#{SITE}/sample-post/"])
    reconcile(client: client).run
    assert_empty client.created
  end

  def test_dry_run_creates_nothing
    client = RecorderClient.new(existing: Set.new)
    reconcile(client: client, dry_run: true).run
    assert_empty client.created
  end

  def test_aborts_before_create_when_list_fails
    assert_raises(RuntimeError) { reconcile(client: FailingListClient.new).run }
  end

  def test_raises_on_non_201
    client = RecorderClient.new(existing: Set.new,
                                responses: [Devto::Response.new(422, "bad")])
    assert_raises(RuntimeError) { reconcile(client: client).run }
  end

  def test_retries_once_on_429
    client = RecorderClient.new(existing: Set.new,
                                responses: [Devto::Response.new(429, "slow"),
                                            Devto::Response.new(201, "{}")])
    assert_equal 0, reconcile(client: client).run
    assert_equal 2, client.created.length # first 429, retried to 201
  end
end
