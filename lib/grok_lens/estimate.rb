# frozen_string_literal: true

module GrokLens
  module Estimate
    module_function

    # Rough token estimate from artifact sizes. Always label as est. in UI.
    # est_tokens ≈ (chat_history_bytes + events_bytes * 0.25) / 4
    def tokens(chat_history_bytes:, events_bytes:)
      ((chat_history_bytes.to_f + events_bytes.to_f * 0.25) / 4.0).round
    end

    def format_tokens(n)
      return "—" if n.nil? || n <= 0

      if n >= 1_000_000
        format("~%.1fM", n / 1_000_000.0)
      elsif n >= 1_000
        format("~%.0fk", n / 1_000.0)
      else
        "~#{n}"
      end
    end

    def format_bytes(n)
      return "—" if n.nil? || n <= 0

      if n >= 1_000_000_000
        format("%.1f GB", n / 1_000_000_000.0)
      elsif n >= 1_000_000
        format("%.1f MB", n / 1_000_000.0)
      elsif n >= 1_000
        format("%.1f KB", n / 1_000.0)
      else
        "#{n} B"
      end
    end
  end
end
