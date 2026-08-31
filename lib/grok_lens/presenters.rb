# frozen_string_literal: true

require "cgi"
require "shellwords"
require "time"
require "uri"

module GrokLens
  module Presenters
    module_function

    def h(text)
      CGI.escape_html(text.to_s)
    end

    def home_query(src: nil, sort: "last_active", running: false)
      q = {}
      q["src"] = src unless src.to_s.empty?
      q["sort"] = sort unless sort.to_s.empty? || sort.to_s == "last_active"
      q["running"] = "1" if running
      q.empty? ? "/" : "/?#{URI.encode_www_form(q)}"
    end

    # CLI to reopen a session in Grok Build TUI.
    # Prefer UUID resume with explicit cwd so it works outside the original directory.
    def resume_command(session)
      src = session.respond_to?(:source_key) ? session.source_key : :grok
      return nil if src == :cursor || src == :bot
      if src == :codex
        return "codex resume #{Shellwords.escape(session.id.to_s)}"
      end

      cwd = session.cwd.to_s
      id = session.id.to_s
      if cwd.empty?
        "grok --resume #{Shellwords.escape(id)}"
      else
        "grok --cwd #{Shellwords.escape(cwd)} --resume #{Shellwords.escape(id)}"
      end
    end

    def continue_command(session)
      cwd = session.cwd.to_s
      return "grok --continue" if cwd.empty?

      "grok --cwd #{Shellwords.escape(cwd)} --continue"
    end

    def duration_label(session)
      a = session.created_at
      b = session.last_active_at
      return "—" unless a && b

      secs = (b - a).to_i
      return "—" if secs < 0

      if secs < 3600
        "#{secs / 60}m"
      elsif secs < 86_400
        "#{secs / 3600}h"
      else
        "#{secs / 86_400}d"
      end
    end

    def short_path(path, home: Dir.home)
      return "" if path.nil? || path.empty?

      path = path.to_s
      if path.start_with?(home)
        "~#{path[home.length..]}"
      else
        path
      end
    end

    def relative_time(time, now: Time.now.utc)
      return "—" unless time

      t = time.is_a?(Time) ? time : (Time.parse(time.to_s) rescue nil)
      return "—" unless t

      t = t.utc
      now = now.utc
      secs = (now - t).to_i
      return "just now" if secs < 60
      return "#{secs / 60}m" if secs < 3600
      return "#{secs / 3600}h" if secs < 86_400
      return "#{secs / 86_400}d" if secs < 86_400 * 30

      t.strftime("%Y-%m-%d")
    end

    def status_label(status)
      case status
      when :active then "live"
      when :stale then "stale"
      else "idle"
      end
    end

    def mcp_status_label(status)
      case status.to_sym
      when :active then "active"
      when :idle then "idle"
      when :suspended then "suspended"
      when :failed then "failed"
      else status.to_s
      end
    end

    def sparkline_svg(points, width: 120, height: 24)
      pts = Array(points).map(&:to_f)
      return %(<svg class="spark" width="#{width}" height="#{height}"></svg>) if pts.size < 2

      min = pts.min
      max = pts.max
      range = (max - min).zero? ? 1.0 : (max - min)
      step = width.to_f / (pts.size - 1)
      coords = pts.each_with_index.map do |v, i|
        x = i * step
        y = height - 2 - ((v - min) / range) * (height - 4)
        "#{x.round(2)},#{y.round(2)}"
      end.join(" ")
      %(<svg class="spark" viewBox="0 0 #{width} #{height}" width="#{width}" height="#{height}" preserveAspectRatio="none" aria-hidden="true"><polyline fill="none" stroke="currentColor" stroke-width="1.2" points="#{coords}"/></svg>)
    end

    def model_bars(hist, max_width: 100)
      hist = hist.to_h
      return "" if hist.empty?

      max = hist.values.max.to_f
      max = 1.0 if max.zero?
      hist.sort_by { |_, c| -c }.first(6).map do |model, count|
        w = ((count / max) * max_width).round
        <<~HTML
          <div class="model-row">
            <span class="model-name">#{h(model)}</span>
            <span class="model-bar"><span style="width:#{w}%"></span></span>
            <span class="num">#{count}</span>
          </div>
        HTML
      end.join
    end

    def tool_bars(counts, limit: 12)
      counts = counts.to_h
      return %(<p class="muted">No tool calls recorded.</p>) if counts.empty?

      max = counts.values.max.to_f
      max = 1.0 if max.zero?
      counts.sort_by { |_, c| -c }.first(limit).map do |name, count|
        w = ((count / max) * 100).round
        <<~HTML
          <div class="model-row">
            <span class="model-name">#{h(name)}</span>
            <span class="model-bar"><span style="width:#{w}%"></span></span>
            <span class="num">#{count}</span>
          </div>
        HTML
      end.join
    end
  end
end
