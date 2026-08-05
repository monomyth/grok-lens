# frozen_string_literal: true

require "json"
require "yaml"

module GrokLens
  module Config
    module_function

    DEFAULT_POLL_SECONDS = 300
    MIN_POLL_SECONDS = 15
    MAX_POLL_SECONDS = 86_400

    def grok_home
      File.expand_path(ENV.fetch("GROK_HOME", File.expand_path("~/.grok")))
    end

    def poll_seconds
      raw = ENV["GROK_LENS_POLL_SECONDS"]
      return DEFAULT_POLL_SECONDS if raw.nil? || raw.strip.empty?

      n = Integer(raw)
      n = MIN_POLL_SECONDS if n < MIN_POLL_SECONDS
      n = MAX_POLL_SECONDS if n > MAX_POLL_SECONDS
      n
    rescue ArgumentError
      DEFAULT_POLL_SECONDS
    end

    def poll_presets
      [
        [30, "30s"],
        [60, "1m"],
        [300, "5m"],
        [600, "10m"],
        [0, "Off"]
      ]
    end

    # Optional USD per 1M tokens (blended). Set GROK_LENS_USD_PER_M_TOKENS or config file.
    def usd_per_m_tokens
      raw = ENV["GROK_LENS_USD_PER_M_TOKENS"]
      return Float(raw) if raw && !raw.strip.empty?

      cfg = load_user_config
      v = cfg["usd_per_m_tokens"] || cfg.dig("cost", "usd_per_m_tokens")
      v ? Float(v) : nil
    rescue ArgumentError, TypeError
      nil
    end

    def config_path
      ENV.fetch("GROK_LENS_CONFIG", File.expand_path("~/.grok-lens.yml"))
    end

    def load_user_config
      path = config_path
      return {} unless File.file?(path)

      data = if path.end_with?(".json")
               JSON.parse(File.read(path))
             else
               YAML.safe_load(File.read(path), permitted_classes: [Symbol]) || {}
             end
      data.is_a?(Hash) ? data : {}
    rescue StandardError
      {}
    end
  end
end
