# frozen_string_literal: true

if RUBY_VERSION.split(".").first.to_i < 4
  raise "Grok Lens requires Ruby 4.0+ (running #{RUBY_VERSION})"
end

require_relative "grok_lens/config"
require_relative "grok_lens/models"
require_relative "grok_lens/estimate"
require_relative "grok_lens/presenters"
require_relative "grok_lens/catalog"
require_relative "grok_lens/search"
require_relative "grok_lens/store"
require_relative "grok_lens/bot"
require_relative "grok_lens/app"

module GrokLens
  VERSION = "0.4.1"
end
