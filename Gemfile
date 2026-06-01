source "https://rubygems.org"

# Pin to the github-pages gem so local builds match what GitHub Pages serves
# (native Pages build — no custom Actions workflow). This locks Jekyll, the
# theme, and the plugin whitelist to GitHub's supported versions.
gem "github-pages", group: :jekyll_plugins

# Faster incremental rebuilds locally; harmless on Pages.
gem "webrick", "~> 1.8"

# Windows / JRuby tzinfo support (no-op on macOS, kept for parity).
platforms :mingw, :x64_mingw, :mswin, :jruby do
  gem "tzinfo", ">= 1", "< 3"
  gem "tzinfo-data"
end

gem 'liquid', '~> 4.0.4'

gem "bigdecimal", "~> 4.1"

gem "csv", "~> 3.3"
