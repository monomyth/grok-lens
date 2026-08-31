# frozen_string_literal: true

require "json"

module GrokLens
  # Read-only inventory of MCP servers from config, plugins, and session events.
  # Never reads env/headers (those can hold secrets).
  module Mcp
    Server = Data.define(
      :name,
      :transport,
      :target,
      :source,
      :plugin,
      :enabled,
      :status,          # :active | :idle | :suspended | :failed
      :error,
      :tool_count,
      :tools,
      :call_count,
      :live_session_ids,
      :session_ids,
      :session_titles
    ) do
      def active? = status == :active
      def idle? = status == :idle
      def suspended? = status == :suspended
      def failed? = status == :failed
    end

    module_function

    def inventory(grok_home:, sessions: [], ps_index: [])
      grok_home = File.expand_path(grok_home)
      defs = {}
      user_cfg = File.join(grok_home, "config.toml")
      merge_defs!(defs, parse_config(user_cfg, source: "user"))
      apply_disabled!(defs, parse_disabled_names(user_cfg))
      Array(sessions).each do |row|
        cwd = row[:cwd].to_s
        next if cwd.empty?

        proj = File.join(cwd, ".grok", "config.toml")
        merge_defs!(defs, parse_config(proj, source: "project"))
        apply_disabled!(defs, parse_disabled_names(proj))
      end
      merge_defs!(defs, parse_plugins(grok_home))
      apply_disabled!(defs, parse_disabled_names(user_cfg))

      usage = Hash.new { |h, k| h[k] = blank_usage }
      Array(sessions).each do |row|
        dir = row[:dir]
        next unless dir && File.directory?(dir)

        scan_session(dir, row, usage)
      end

      names = (defs.keys + usage.keys).uniq.sort
      ps_index = Array(ps_index)
      names.map do |name|
        spec = defs[name] || {}
        u = usage[name]
        enabled = spec.key?(:enabled) ? spec[:enabled] : true
        status, error = derive_status(enabled: enabled, usage: u, spec: spec, ps_index: ps_index)
        tools = Array(u[:tools]).uniq
        Server.new(
          name: name,
          transport: spec[:transport] || u[:transport],
          target: spec[:target] || u[:target],
          source: spec[:source] || u[:source] || "session",
          plugin: spec[:plugin],
          enabled: enabled,
          status: status,
          error: error || u[:error],
          tool_count: (u[:tool_count].to_i.positive? ? u[:tool_count].to_i : tools.size),
          tools: tools.first(24),
          call_count: u[:call_count].to_i,
          live_session_ids: Array(u[:live_ids]).uniq,
          session_ids: Array(u[:session_ids]).uniq,
          session_titles: Array(u[:titles]).uniq.first(8)
        )
      end.sort_by { |s| [status_rank(s.status), s.name.to_s] }
    end

    def parse_disabled_names(path)
      return [] unless File.file?(path)

      text = File.read(path)
      return [] unless text =~ /disabled_mcp_servers\s*=\s*\[(.*?)\]/m

      Regexp.last_match(1).scan(/"([^"]+)"|'([^']+)'/).flatten.compact
    rescue StandardError
      []
    end

    def apply_disabled!(defs, names)
      Array(names).each do |name|
        next if name.to_s.empty?

        defs[name] ||= { name: name, transport: nil, target: nil, source: "user", plugin: nil, enabled: false }
        defs[name][:enabled] = false
      end
    end

    def parse_config(path, source: "user")
      return [] unless File.file?(path)

      text = File.read(path)
      disabled = parse_disabled_names(path)

      rows = []
      text.scan(/^\[mcp_servers\.([A-Za-z0-9_-]+)\]\s*\n((?:(?!^\[).*\n)*)/) do |name, body|
        command = toml_string(body, "command")
        url = toml_string(body, "url")
        enabled_raw = toml_bool(body, "enabled")
        enabled = if disabled.include?(name)
                    false
                  elsif enabled_raw.nil?
                    true
                  else
                    enabled_raw
                  end
        args = toml_string_array(body, "args")
        transport = url ? "http" : "stdio"
        target = url || [command, *args].compact.join(" ")
        rows << {
          name: name,
          transport: transport,
          target: target,
          source: source,
          enabled: enabled,
          plugin: nil
        }
      end
      rows
    rescue StandardError
      []
    end

    def parse_plugins(grok_home)
      root = File.join(grok_home, "installed-plugins")
      return [] unless Dir.exist?(root)

      rows = []
      Dir.children(root).each do |entry|
        dir = File.join(root, entry)
        next unless File.directory?(dir)
        next if entry.start_with?(".") || entry == "registry.json"

        %w[.mcp.json mcp.json].each do |fname|
          path = File.join(dir, fname)
          next unless File.file?(path)

          data = JSON.parse(File.read(path))
          servers = data["mcpServers"] || data["mcp_servers"] || {}
          next unless servers.is_a?(Hash)

          plugin = entry.sub(/-[0-9a-f]{8}$/i, "")
          servers.each do |name, spec|
            next unless spec.is_a?(Hash)

            url = spec["url"]
            command = spec["command"]
            args = Array(spec["args"])
            transport = spec["type"] || spec["transport"] || (url ? "http" : "stdio")
            target = url || [command, *args].compact.join(" ")
            rows << {
              name: name.to_s,
              transport: transport.to_s,
              target: target.to_s,
              source: "plugin",
              plugin: plugin,
              enabled: spec.key?("enabled") ? !!spec["enabled"] : true
            }
          end
        end
      end
      rows
    rescue StandardError
      []
    end

    def status_rank(status)
      { active: 0, failed: 1, idle: 2, suspended: 3 }[status] || 9
    end

    def merge_defs!(defs, rows)
      Array(rows).each do |row|
        name = row[:name].to_s
        next if name.empty?

        prev = defs[name]
        defs[name] = if prev.nil?
                       row
                     elsif row[:source] == "project"
                       row
                     elsif prev[:source] == "user" && row[:source] == "plugin"
                       prev
                     else
                       prev.merge(row) { |_k, a, b| b.nil? || b == "" ? a : b }
                     end
      end
    end

    def blank_usage
      {
        transport: nil,
        target: nil,
        source: nil,
        tools: [],
        tool_count: 0,
        call_count: 0,
        inflight: 0,
        connected_live: false,
        failed: false,
        error: nil,
        live_ids: [],
        session_ids: [],
        titles: []
      }
    end

    def scan_session(dir, row, usage)
      events = File.join(dir, "events.jsonl")
      inflight = Hash.new(0)
      connected = {}
      if File.file?(events)
        File.foreach(events) do |line|
          next unless line.include?("mcp_")

          begin
            obj = JSON.parse(line)
          rescue JSON::ParserError
            next
          end

          type = obj["type"].to_s
          case type
          when "mcp_config_resolved"
            Array(obj["servers"]).each do |s|
              next unless s.is_a?(Hash)

              name = s["name"].to_s
              next if name.empty?

              u = usage[name]
              u[:transport] ||= s["transport"]
              u[:source] ||= s["source"]
              touch_session(u, row, client: false)
            end
          when "mcp_server_starting"
            name = obj["server_name"].to_s
            next if name.empty?

            u = usage[name]
            u[:transport] ||= obj["transport"]
            u[:target] ||= obj["target"]
            touch_session(u, row, client: false)
          when "mcp_server_connected"
            name = obj["server_name"].to_s
            next if name.empty?

            u = usage[name]
            u[:transport] ||= obj["transport"]
            u[:tool_count] = [u[:tool_count].to_i, obj["tool_count"].to_i].max
            u[:tools] |= Array(obj["tools"]).map(&:to_s)
            u[:failed] = false
            u[:error] = nil
            connected[name] = true
            u[:connected_live] = true if row[:live]
            touch_session(u, row, client: true)
          when "mcp_server_failed"
            name = obj["server_name"].to_s
            next if name.empty?

            u = usage[name]
            u[:transport] ||= obj["transport"]
            u[:target] ||= obj["target"]
            u[:failed] = true
            u[:error] = [obj["error_type"], obj["error_message"]].compact.join(": ")
            connected[name] = false
            touch_session(u, row, client: false)
          when "mcp_health_check"
            name = obj["server_name"].to_s
            next if name.empty?

            u = usage[name]
            if obj["healthy"] == false || obj["client_state"].to_s == "unavailable"
              u[:failed] = true
              u[:error] ||= obj["client_state"].to_s
            elsif obj["healthy"] == true || obj["client_state"].to_s == "ready"
              u[:failed] = false
              connected[name] = true
              u[:connected_live] = true if row[:live]
            end
            touch_session(u, row, client: obj["healthy"] == true || obj["client_state"].to_s == "ready")
          when "mcp_tool_call_started"
            name = obj["server_name"].to_s
            next if name.empty?

            u = usage[name]
            u[:call_count] += 1
            inflight[name] += 1
            u[:tools] |= [obj["tool_name"].to_s] unless obj["tool_name"].to_s.empty?
            touch_session(u, row, client: true)
          when "mcp_tool_call_completed"
            name = obj["server_name"].to_s
            next if name.empty?

            u = usage[name]
            inflight[name] -= 1 if inflight[name].positive?
            touch_session(u, row, client: true)
          end
        end
      end

      inflight.each do |name, n|
        usage[name][:inflight] += n if n.positive? && row[:live]
      end

      updates = File.join(dir, "updates.jsonl")
      scan_updates_inflight(updates, row, usage) if row[:live] && File.file?(updates)
    rescue StandardError
      nil
    end

    def touch_session(u, row, client: false)
      id = row[:id].to_s
      return if id.empty?

      u[:session_ids] << id
      u[:live_ids] << id if client && row[:live]
      title = row[:title].to_s.strip
      u[:titles] << title unless title.empty?
    end

    def scan_updates_inflight(path, row, usage)
      size = File.size(path)
      max = 1_500_000
      start = size > max ? size - max : 0
      data = File.open(path, "rb") do |f|
        f.seek(start)
        f.read
      end.to_s
      data = data.split("\n", 2).last if start.positive?
      open = {}
      data.each_line do |line|
        next unless line.include?("server_name") || line.include?('"MCP"')

        begin
          obj = JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        update = obj.dig("params", "update") || {}
        su = update["sessionUpdate"]
        next unless su == "tool_call" || su == "tool_call_update"

        cid = update["toolCallId"]
        next unless cid

        raw = update["rawOutput"]
        name = nil
        if raw.is_a?(Hash)
          name = raw["server_name"] || raw.dig("output", "server_name")
        end
        name ||= update["server_name"]
        if name
          open[cid] = { name: name.to_s, status: update["status"] }
        elsif open[cid] && update["status"]
          open[cid][:status] = update["status"]
        end
      end
      open.each_value do |info|
        next if %w[completed failed cancelled error rejected success].include?(info[:status].to_s.downcase)

        name = info[:name]
        next if name.empty?

        usage[name][:inflight] += 1
        usage[name][:connected_live] = true
        touch_session(usage[name], row, client: true)
      end
    rescue StandardError
      nil
    end

    def derive_status(enabled:, usage:, spec:, ps_index:)
      return [:suspended, nil] unless enabled

      if usage[:inflight].to_i.positive?
        return [:active, nil]
      end
      if usage[:failed] && !usage[:connected_live]
        return [:failed, usage[:error]]
      end
      if usage[:connected_live] || stdio_alive?(spec, ps_index)
        return [:idle, nil]
      end
      if usage[:failed]
        return [:failed, usage[:error]]
      end

      [:idle, nil]
    end

    def stdio_alive?(spec, ps_index)
      return false unless spec[:transport].to_s == "stdio"

      target = spec[:target].to_s
      return false if target.empty?

      needles = []
      target.split(/\s+/).each do |tok|
        base = File.basename(tok)
        needles << base if base.length >= 8 && base.include?("mcp")
        needles << tok if tok.include?("mcp") && tok.length >= 12
      end
      needles.uniq!
      return false if needles.empty?

      Array(ps_index).any? { |line| needles.any? { |n| line.include?(n) } }
    end

    def toml_string(body, key)
      if body =~ /^#{Regexp.escape(key)}\s*=\s*"([^"]*)"/
        return Regexp.last_match(1)
      end
      if body =~ /^#{Regexp.escape(key)}\s*=\s*'([^']*)'/
        return Regexp.last_match(1)
      end

      nil
    end

    def toml_bool(body, key)
      return true if body =~ /^#{Regexp.escape(key)}\s*=\s*true\b/
      return false if body =~ /^#{Regexp.escape(key)}\s*=\s*false\b/

      nil
    end

    def toml_string_array(body, key)
      return [] unless body =~ /^#{Regexp.escape(key)}\s*=\s*\[(.*?)\]/m

      Regexp.last_match(1).scan(/"([^"]*)"/).flatten
    end
  end
end
