# frozen_string_literal: true

require "json"

module GrokLens
  module Estimate
    # Grok usage.json stores USD as integer ticks (10^10 ticks per dollar).
    COST_USD_TICKS = 10_000_000_000.0
    MAX_USAGE_TURNS = 100

    module_function

    # Token figure for a session:
    # - Prefer usage.json session totals when the ledger covers the session
    # - If usage.json exists but only covers later turns (Grok 1.0.14+ on an
    #   older conversation), keep the lifetime hybrid estimate and attach the
    #   recorded bucket as partial
    # - Else hybrid: signals.json context + turns/tools + on-disk size
    # Label billed totals without "~"; estimates stay prefixed.
    def for_session(session_dir:, chat_history_bytes:, events_bytes:, num_messages: 0, num_turns: 0)
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

      recorded = read_usage(session_dir)
      session_turns = [num_turns.to_i, turns].max
      if recorded && (recorded[:total_tokens].to_i.positive? || recorded[:model_calls].to_i.positive?)
        recorded_turns = recorded[:recorded_turns].to_i
        incomplete = session_turns.positive? && recorded_turns.positive? && recorded_turns < session_turns
        usage = recorded.merge(incomplete: incomplete)
        if incomplete
          return {
            est_tokens: lifetime.round,
            context_tokens: ctx,
            context_window: window,
            est_source: ctx ? "hybrid" : "size",
            billed: false,
            cost_usd: nil,
            usage: usage
          }
        end

        return {
          est_tokens: recorded[:total_tokens].to_i,
          context_tokens: ctx,
          context_window: window,
          est_source: "usage",
          billed: true,
          cost_usd: recorded[:cost_usd],
          usage: usage
        }
      end

      {
        est_tokens: lifetime.round,
        context_tokens: ctx,
        context_window: window,
        est_source: ctx ? "hybrid" : "size",
        billed: false,
        cost_usd: nil,
        usage: nil
      }
    end

    def size_based(chat_history_bytes:, events_bytes:)
      ((chat_history_bytes.to_f + events_bytes.to_f * 0.25) / 4.0).round
    end

    # Back-compat shim
    def tokens(chat_history_bytes:, events_bytes:)
      size_based(chat_history_bytes: chat_history_bytes, events_bytes: events_bytes)
    end

    def format_tokens(n, approx: true)
      return "—" if n.nil? || n <= 0

      body =
        if n >= 1_000_000
          format("%.1fM", n / 1_000_000.0)
        elsif n >= 1_000
          format("%.0fk", n / 1_000.0)
        else
          n.to_s
        end
      approx ? "~#{body}" : body
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

    def cost_from_ticks(ticks)
      return nil if ticks.nil?

      ticks.to_f / COST_USD_TICKS
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

    def read_usage(session_dir)
      path = File.join(session_dir, "usage.json")
      return nil unless File.file?(path)

      data = JSON.parse(File.read(path))
      sess = data["session"]
      return nil unless sess.is_a?(Hash)

      totals = parse_usage_bucket(sess)
      return nil unless totals[:total_tokens].to_i.positive? || totals[:model_calls].to_i.positive?

      turns = Array(data["turns"]).filter_map do |row|
        next unless row.is_a?(Hash)

        parse_usage_bucket(row).merge(
          turn_number: row["turnNumber"] || row["turn_number"],
          ended_at: row["endedAt"] || row["ended_at"]
        )
      end
      turns = turns.last(MAX_USAGE_TURNS) if turns.size > MAX_USAGE_TURNS
      model_usage = {}
      raw_models = sess["modelUsage"] || sess["model_usage"] || {}
      raw_models.each { |k, v| model_usage[k.to_s] = parse_usage_bucket(v) } if raw_models.is_a?(Hash)

      totals.merge(
        recorded_turns: [totals[:turn_count].to_i, turns.size].max,
        updated_at: data["updatedAt"] || data["updated_at"],
        turns: turns,
        model_usage: model_usage
      )
    rescue StandardError
      nil
    end

    def parse_usage_bucket(h)
      return {} unless h.is_a?(Hash)

      input = int_field(h, "inputTokens", "input_tokens")
      output = int_field(h, "outputTokens", "output_tokens")
      total = int_field(h, "totalTokens", "total_tokens")
      total = input + output if total.zero? && (input.positive? || output.positive?)
      ticks = h["costUsdTicks"] || h["cost_usd_ticks"]
      {
        input_tokens: input,
        output_tokens: output,
        cached_read_tokens: int_field(h, "cachedReadTokens", "cached_read_tokens"),
        cache_creation_tokens: int_field(h, "cacheCreationTokens", "cache_creation_tokens"),
        reasoning_tokens: int_field(h, "reasoningTokens", "reasoning_tokens"),
        total_tokens: total,
        model_calls: int_field(h, "modelCalls", "model_calls"),
        turn_count: int_field(h, "turnCount", "turn_count"),
        cost_usd: ticks.nil? ? nil : cost_from_ticks(ticks),
        primary_model_id: h["primaryModelId"] || h["primary_model_id"]
      }
    end

    def int_field(h, *keys)
      keys.each do |k|
        return h[k].to_i if h.key?(k)
      end
      0
    end

    def positive_int(v)
      n = v.to_i
      n.positive? ? n : nil
    end
  end
end
