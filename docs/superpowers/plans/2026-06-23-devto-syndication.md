# dev.to Syndication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cross-post engineering-blog posts to dev.to with `canonical_url` back to the blog, fired automatically after each successful Pages deploy, create-only and idempotent.

**Architecture:** A dependency-free Ruby library (`lib/devto/`) of focused units — `Post` (parse a `_posts/*.md` file), `Transform` (tags / link-absolutization / payload), `Client` (dev.to HTTP via an injectable transport), `Reconcile` (diff local posts against what's already on dev.to and create the missing ones). A thin CLI (`bin/crosspost-devto`) wires them together. A separate GitHub Actions workflow (`crosspost.yml`) runs the CLI after the existing `pages.yml` deploy succeeds.

**Tech Stack:** Ruby 3.x standard library only (`net/http`, `json`, `yaml`, `uri`, `set`, `date`), Minitest (a Ruby default gem) for tests. No Gemfile changes, no new gems.

## Global Constraints

- **Ruby standard library + default gems only.** No new gems, no Gemfile changes. `require "minitest/autorun"` is allowed (default gem).
- **Blog stays canonical.** Every dev.to article sets `canonical_url` to `https://engineering.sailingnaturali.com/<slug>/`. Never modify Jekyll post front matter.
- **Create-only / idempotent.** Never update or delete existing dev.to articles. Re-running must be a no-op once everything is synced.
- **Abort before create on read failure.** If listing existing dev.to articles fails, do not POST anything.
- **dev.to tag rules:** max 4 tags, lowercase, non-alphanumerics stripped. Take the post's first 4 tags after sanitizing.
- **Rate limit:** space article creates ≥3s apart; on HTTP 429, back off once and retry, then fail.
- **Site URL is read from `_config.yml` (`url:`)**, not hardcoded in logic.
- All `require`s between project files use `require_relative` (no load-path flags needed at runtime).

---

### Task 1: `Devto::Post` — parse a post file

**Files:**
- Create: `lib/devto/post.rb`
- Create: `test/devto/post_test.rb`
- Create (fixtures): `test/fixtures/posts/2026-01-02-sample-post.md`, `test/fixtures/posts/2026-12-31-future-post.md`, `test/fixtures/posts/2026-01-03-unpublished-post.md`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Devto::Post.parse(path) -> Devto::Post`
  - `Devto::Post#title -> String`
  - `Devto::Post#slug -> String` (filename minus `YYYY-MM-DD-` prefix and `.md`)
  - `Devto::Post#date -> Date`
  - `Devto::Post#tags -> Array<String>` (raw, from front matter)
  - `Devto::Post#body -> String` (everything after the front-matter block)
  - `Devto::Post#publishable?(today: Date.today) -> Boolean` (false if `published: false` or `date > today`)
  - `Devto::Post#canonical_url(site_url) -> String` → `"#{site_url}/#{slug}/"`

- [ ] **Step 1: Create the three fixtures**

`test/fixtures/posts/2026-01-02-sample-post.md`:
```markdown
---
layout: post
title: "A sample post about MCP and SignalK"
description: "Fixture."
date: 2026-01-02
tags:
  - mcp
  - signalk
  - voice-assistant
  - ai
  - llm
---

Body line one. See [the docs](/launchd-minimal-path/) for more.

```ruby
# a code fence containing a link that must NOT be rewritten: [x](/keep-me)
puts "hi"
```

External [link](https://example.com) and an [anchor](#section) stay as-is.
```

`test/fixtures/posts/2026-12-31-future-post.md`:
```markdown
---
layout: post
title: "A future-dated post"
date: 2026-12-31
tags:
  - ai
---

Should be skipped because it is in the future.
```

`test/fixtures/posts/2026-01-03-unpublished-post.md`:
```markdown
---
layout: post
title: "An unpublished post"
date: 2026-01-03
published: false
tags:
  - ai
---

Should be skipped because published is false.
```

- [ ] **Step 2: Write the failing test**

`test/devto/post_test.rb`:
```ruby
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
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `ruby test/devto/post_test.rb`
Expected: FAIL — `cannot load such file -- .../lib/devto/post`

- [ ] **Step 4: Implement `lib/devto/post.rb`**

```ruby
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
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `ruby test/devto/post_test.rb`
Expected: PASS (6 runs, 0 failures)

- [ ] **Step 6: Commit**

```bash
git add lib/devto/post.rb test/devto/post_test.rb test/fixtures/posts/
git commit -m "feat(crosspost): Devto::Post parses post files"
```

---

### Task 2: `Devto::Transform.derive_tags`

**Files:**
- Create: `lib/devto/transform.rb`
- Create: `test/devto/transform_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Devto::Transform.derive_tags(tags) -> Array<String>` — lowercase each tag, strip `[^a-z0-9]`, drop empties, dedupe (first occurrence wins), keep the first 4.

- [ ] **Step 1: Write the failing test**

`test/devto/transform_test.rb`:
```ruby
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `ruby test/devto/transform_test.rb`
Expected: FAIL — `cannot load such file -- .../lib/devto/transform`

- [ ] **Step 3: Implement `lib/devto/transform.rb`**

```ruby
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `ruby test/devto/transform_test.rb`
Expected: PASS (4 runs, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add lib/devto/transform.rb test/devto/transform_test.rb
git commit -m "feat(crosspost): derive_tags sanitizes to dev.to's 4-tag rule"
```

---

### Task 3: `Devto::Transform.absolutize` (fence-aware)

**Files:**
- Modify: `lib/devto/transform.rb`
- Modify: `test/devto/transform_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Devto::Transform.absolutize(body, site_url) -> String` — rewrite root-relative Markdown links/images (`](/path)`) and HTML `src=`/`href="/path"` to `site_url + path`; leave external (`http(s)://`), protocol-relative (`//`), and in-page anchors (`#`) untouched; **never** rewrite inside fenced code blocks (lines between ```` ``` ```` fences).

- [ ] **Step 1: Add the failing test**

Append to `test/devto/transform_test.rb`:
```ruby
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `ruby test/devto/transform_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'absolutize'`

- [ ] **Step 3: Implement `absolutize` in `lib/devto/transform.rb`**

Add inside `module Transform` (after `derive_tags`):
```ruby
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `ruby test/devto/transform_test.rb`
Expected: PASS (8 runs, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add lib/devto/transform.rb test/devto/transform_test.rb
git commit -m "feat(crosspost): fence-aware absolutize for root-relative links"
```

---

### Task 4: `Devto::Transform.build_payload`

**Files:**
- Modify: `lib/devto/transform.rb`
- Modify: `test/devto/transform_test.rb`

**Interfaces:**
- Consumes: `Devto::Post` (Task 1), `derive_tags` (Task 2), `absolutize` (Task 3).
- Produces: `Devto::Transform.build_payload(post, site_url) -> Hash` →
  `{ article: { title:, body_markdown:, canonical_url:, tags:, published: true } }`

- [ ] **Step 1: Add the failing test**

Append to `test/devto/transform_test.rb`:
```ruby
require_relative "../../lib/devto/post"

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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `ruby test/devto/transform_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'build_payload'`

- [ ] **Step 3: Implement `build_payload` in `lib/devto/transform.rb`**

Add inside `module Transform`:
```ruby
    def build_payload(post, site_url)
      {
        article: {
          title: post.title,
          body_markdown: absolutize(post.body, site_url),
          canonical_url: post.canonical_url(site_url),
          tags: derive_tags(post.tags),
          published: true
        }
      }
    end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `ruby test/devto/transform_test.rb`
Expected: PASS (9 runs, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add lib/devto/transform.rb test/devto/transform_test.rb
git commit -m "feat(crosspost): build_payload assembles the dev.to article body"
```

---

### Task 5: `Devto::Client` — dev.to HTTP with injectable transport

**Files:**
- Create: `lib/devto/client.rb`
- Create: `test/devto/client_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Devto::HTTP` default transport with `#get(url, headers) -> Devto::Response` and `#post(url, headers, body) -> Devto::Response`.
  - `Devto::Response = Struct.new(:code, :body)` where `code` is an Integer.
  - `Devto::Client.new(api_key, transport: Devto::HTTP.new)`
  - `Devto::Client#existing_canonicals -> Set<String>` — GET `https://dev.to/api/articles/me/all?per_page=1000`; raises on non-200; returns the set of non-nil `canonical_url` values.
  - `Devto::Client#create(payload) -> Devto::Response` — POST `https://dev.to/api/articles` with the JSON body.

- [ ] **Step 1: Write the failing test**

`test/devto/client_test.rb`:
```ruby
require "minitest/autorun"
require "json"
require_relative "../../lib/devto/client"

class FakeTransport
  attr_reader :posted
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
  end

  def test_existing_canonicals_raises_on_non_200
    t = FakeTransport.new(get_response: Devto::Response.new(401, "no"))
    client = Devto::Client.new("KEY", transport: t)
    assert_raises(RuntimeError) { client.existing_canonicals }
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `ruby test/devto/client_test.rb`
Expected: FAIL — `cannot load such file -- .../lib/devto/client`

- [ ] **Step 3: Implement `lib/devto/client.rb`**

```ruby
require "net/http"
require "uri"
require "json"
require "set"

module Devto
  API_BASE = "https://dev.to/api".freeze
  Response = Struct.new(:code, :body)

  class HTTP
    def get(url, headers)
      request(Net::HTTP::Get.new(URI(url)), URI(url), headers)
    end

    def post(url, headers, body)
      req = Net::HTTP::Post.new(URI(url))
      req.body = body
      request(req, URI(url), headers)
    end

    private

    def request(req, uri, headers)
      headers.each { |k, v| req[k] = v }
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
      Response.new(res.code.to_i, res.body)
    end
  end

  class Client
    def initialize(api_key, transport: HTTP.new)
      @api_key = api_key
      @transport = transport
    end

    def existing_canonicals
      res = @transport.get("#{API_BASE}/articles/me/all?per_page=1000",
                           { "api-key" => @api_key })
      raise "dev.to list failed: HTTP #{res.code} #{res.body}" unless res.code == 200
      JSON.parse(res.body).map { |a| a["canonical_url"] }.compact.to_set
    end

    def create(payload)
      @transport.post("#{API_BASE}/articles",
                      { "api-key" => @api_key, "Content-Type" => "application/json" },
                      JSON.generate(payload))
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `ruby test/devto/client_test.rb`
Expected: PASS (3 runs, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add lib/devto/client.rb test/devto/client_test.rb
git commit -m "feat(crosspost): Devto::Client with injectable transport"
```

---

### Task 6: `Devto::Reconcile` — diff and create

**Files:**
- Create: `lib/devto/reconcile.rb`
- Create: `test/devto/reconcile_test.rb`

**Interfaces:**
- Consumes: `Devto::Post` (Task 1), `Devto::Transform` (Tasks 2–4), `Devto::Response` (Task 5), any object responding to `#existing_canonicals` and `#create(payload)`.
- Produces:
  - `Devto::Reconcile.new(posts_dir:, site_url:, client:, dry_run: false, today: Date.today, io: $stdout, sleep_s: 3)`
  - `Devto::Reconcile#run -> Integer` — loads publishable posts from `posts_dir`, computes the set already on dev.to (calls `client.existing_canonicals` **first**, so a raise aborts before any create), creates the missing ones (skips POST when `dry_run`), spacing real creates by `sleep_s` and retrying once on HTTP 429. Returns `0`. Raises on a non-201 create. Sleeps via an overridable `#sleep_for` so tests run fast.

- [ ] **Step 1: Write the failing test**

`test/devto/reconcile_test.rb`:
```ruby
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `ruby test/devto/reconcile_test.rb`
Expected: FAIL — `cannot load such file -- .../lib/devto/reconcile`

- [ ] **Step 3: Implement `lib/devto/reconcile.rb`**

```ruby
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `ruby test/devto/reconcile_test.rb`
Expected: PASS (6 runs, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add lib/devto/reconcile.rb test/devto/reconcile_test.rb
git commit -m "feat(crosspost): Reconcile diffs posts and creates missing"
```

---

### Task 7: `bin/crosspost-devto` CLI

**Files:**
- Create: `bin/crosspost-devto`
- Modify: `_config.yml` (add `bin` to `exclude:` so Jekyll doesn't publish it)

**Interfaces:**
- Consumes: `Devto::Client`, `Devto::Reconcile`, env `DEVTO_API_KEY`, `_config.yml` `url:`.
- Produces: an executable that exits non-zero on failure. Flags: `--dry-run`.

- [ ] **Step 1: Implement `bin/crosspost-devto`**

```ruby
#!/usr/bin/env ruby
require "yaml"
require_relative "../lib/devto/client"
require_relative "../lib/devto/reconcile"

dry_run = ARGV.include?("--dry-run")

api_key = ENV["DEVTO_API_KEY"]
if api_key.nil? || api_key.empty?
  warn "DEVTO_API_KEY is not set"
  exit 1
end

root = File.expand_path("..", __dir__)
config = YAML.safe_load_file(File.join(root, "_config.yml"))
site_url = config.fetch("url").chomp("/")

reconcile = Devto::Reconcile.new(
  posts_dir: File.join(root, "_posts"),
  site_url: site_url,
  client: Devto::Client.new(api_key),
  dry_run: dry_run
)

exit reconcile.run
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x bin/crosspost-devto`

- [ ] **Step 3: Exclude `bin/` from the Jekyll build**

In `_config.yml`, add `bin` under the existing `exclude:` list (alongside `Gemfile`, `README.md`, etc.):
```yaml
exclude:
  - Gemfile
  - Gemfile.lock
  - vendor
  - README.md
  - .jekyll-cache
  - bin
  - lib
  - test
  - docs
```

- [ ] **Step 4: Smoke-test the missing-key guard**

Run: `env -u DEVTO_API_KEY ruby bin/crosspost-devto --dry-run; echo "exit=$?"`
Expected: prints `DEVTO_API_KEY is not set` and `exit=1`

- [ ] **Step 5: Verify the local Jekyll build still succeeds**

Run: `bundle exec jekyll build --trace`
Expected: build completes with no errors; `_site/` does not contain `bin/`, `lib/`, or `test/`.

- [ ] **Step 6: Commit**

```bash
git add bin/crosspost-devto _config.yml
git commit -m "feat(crosspost): CLI entrypoint + exclude tooling dirs from Jekyll"
```

---

### Task 8: GitHub Actions workflow + docs

**Files:**
- Create: `.github/workflows/crosspost.yml`
- Modify: `README.md` (add a "Syndication to dev.to" section)

**Interfaces:**
- Consumes: `bin/crosspost-devto`, repo secret `DEVTO_API_KEY`, the existing `pages.yml` workflow (named `Deploy site to Pages`).
- Produces: an Actions workflow that runs the test suite, then the CLI, after each successful Pages deploy on `main` (and on manual dispatch with a dry-run option).

- [ ] **Step 1: Create `.github/workflows/crosspost.yml`**

```yaml
# Cross-post published blog posts to dev.to after the site deploys.
#
# Chained AFTER "Deploy site to Pages" (pages.yml) via workflow_run so the
# canonical URL is already live before dev.to is told about it, and a failed
# build never cross-posts. Create-only + idempotent: re-runs are no-ops.
# The DEVTO_API_KEY secret stays out of the Pages-permissioned deploy job.
name: Cross-post to dev.to

on:
  workflow_run:
    workflows: ["Deploy site to Pages"]
    types: [completed]
  workflow_dispatch:
    inputs:
      dry_run:
        description: "List what would be created without posting"
        type: boolean
        default: false

permissions:
  contents: read

jobs:
  crosspost:
    runs-on: ubuntu-latest
    # Manual dispatch always allowed; auto-run only after a successful main deploy.
    if: >-
      github.event_name == 'workflow_dispatch' ||
      (github.event.workflow_run.conclusion == 'success' &&
       github.event.workflow_run.head_branch == 'main')
    steps:
      - uses: actions/checkout@v5
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.3"
      - name: Run tests
        run: ruby -e 'Dir.glob("test/**/*_test.rb").each { |f| require File.expand_path(f) }'
      - name: Cross-post to dev.to
        run: bin/crosspost-devto ${{ (github.event_name == 'workflow_dispatch' && inputs.dry_run) && '--dry-run' || '' }}
        env:
          DEVTO_API_KEY: ${{ secrets.DEVTO_API_KEY }}
```

- [ ] **Step 2: Validate the workflow YAML parses**

Run: `ruby -ryaml -e 'YAML.safe_load_file(".github/workflows/crosspost.yml"); puts "ok"'`
Expected: prints `ok`

- [ ] **Step 3: Run the full test suite once more**

Run: `ruby -e 'Dir.glob("test/**/*_test.rb").each { |f| require File.expand_path(f) }'`
Expected: all tests pass (0 failures, 0 errors)

- [ ] **Step 4: Document syndication in `README.md`**

Add this section after "The Scribe workflow":
````markdown
## Syndication to dev.to

Published posts are mirrored to [dev.to](https://dev.to) as a distribution
channel; **the blog stays canonical** (each dev.to article sets `canonical_url`
back here). `.github/workflows/crosspost.yml` runs after a successful Pages
deploy and calls `bin/crosspost-devto`, which:

- lists what's already on dev.to and creates only the missing posts (idempotent,
  create-only — re-runs are no-ops, edits are not re-pushed),
- sets `canonical_url`, derives ≤4 dev.to tags from the post's front matter
  (first four, lowercased, non-alphanumerics stripped), and rewrites
  root-relative links to absolute.

One-time setup: generate a dev.to API key (dev.to → Settings → Extensions →
API Keys) and add it as the repo secret `DEVTO_API_KEY`
(`gh secret set DEVTO_API_KEY`). Dry-run anytime via the workflow's manual
"Run workflow" button (check *dry_run*) or locally:

```bash
DEVTO_API_KEY=... bin/crosspost-devto --dry-run
```

Logic lives in `lib/devto/`; tests in `test/devto/` run with
`ruby -e 'Dir.glob("test/**/*_test.rb").each { |f| require File.expand_path(f) }'`.
````

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/crosspost.yml README.md
git commit -m "ci(crosspost): run after Pages deploy; document dev.to syndication"
```

---

## Notes for the implementer

- **dev.to API key for a real run:** the workflow needs the `DEVTO_API_KEY` repo secret before the first non-dry run will do anything. Until it's set, the job fails fast on the missing-key guard — that's expected.
- **First real run backfills everything:** all currently-published posts (16 at time of writing) get created in one run, spaced 3s apart to stay under dev.to's create rate limit.
- **Do not** add `canonical_url` to any Jekyll post front matter — the blog is self-canonical via `jekyll-seo-tag`; canonical is set only on the dev.to side.
