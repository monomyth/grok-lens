# frozen_string_literal: true

module GrokLens
  module Config
    module_function

    # Default poll interval: 5 minutes. Scans are ~20–40ms on a typical install,
    # so 30–60s is safe if you want snappier updates (UI allows override).
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
  end
end
