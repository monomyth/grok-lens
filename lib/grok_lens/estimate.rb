# frozen_string_literal: true

require "json"

module GrokLens
  module Estimate
    module_function

    # Hybrid token estimate:
    # - Prefer signals.json (contextTokensUsed, turnCount, toolCallCount) when present
    # - Blend with on-disk size heuristic for lifetime proxy
    # Always label as est. in UI except raw context_tokens which Grok records.
    def for_session(session_dir:, chat_history_bytes:, events_bytes:, num_messages: 0)
      size_est = size_based(chat_history_bytes: chat_history_bytes, events_bytes: events_bytes)
      signals = read_signals(session_dir)
      ctx = signals && positive_int(signals["contextTokensUsed"])
      turns = signals ? positive_int(signals["turnCount"]).to_i : 0
      tools = signals ? positive_int(signals["toolCallCount"]).to_i : 0
      window = signals && positive_int(signals["contextWindowTokens"])

      lifetime =
        if ctx
          # Current window is a floor; lifetime proxy grows with turns/tools.
          signal_life = ctx + (turns * [ctx / 8, 500].max) + (tools * 200)
          msg_floor = num_messages.to_i * 400
          blend = (size_est * 0.35 + signal_life * 0.65).round
          [blend, ctx, msg_floor, size_est / 2].max
        else
          msg_floor = num_messages.to_i * 400
          [size_est, msg_floor].max
        end

      {
        est_tokens: lifetime.round,
        context_tokens: ctx,
        context_window: window,
        est_source: ctx ? "hybrid" : "size"
      }
    end

    def size_based(chat_history_bytes:, events_bytes:)
      ((chat_history_bytes.to_f + events_bytes.to_f * 0.25) / 4.0).round
    end

    # Back-compat shim
    def tokens(chat_history_bytes:, events_bytes:)
      size_based(chat_history_bytes: chat_history_bytes, events_bytes: events_bytes)
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

    def format_context(used, window = nil)
      return "—" if used.nil? || used <= 0

      if window && window.positive?
        pct = ((used.to_f / window) * 100).round
        "#{format_tokens(used).delete_prefix('~')} / #{format_tokens(window).delete_prefix('~')} (#{pct}%)"
      else
        format_tokens(used)
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

    def cost_usd(tokens, rate_per_m_tokens)
      return nil if tokens.nil? || tokens <= 0 || rate_per_m_tokens.nil? || rate_per_m_tokens <= 0

      tokens.to_f / 1_000_000.0 * rate_per_m_tokens
    end

    def format_cost(usd)
      return "—" if usd.nil?

      format("$%.4f", usd)
    end

    def read_signals(session_dir)
      path = File.join(session_dir, "signals.json")
      return nil unless File.file?(path)

      JSON.parse(File.read(path))
    rescue StandardError
      nil
    end

    def positive_int(v)
      n = v.to_i
      n.positive? ? n : nil
    end
  end
end
