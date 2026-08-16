# frozen_string_literal: true

require "json"
require "time"

module GrokLens
  # Read-only adapter for the Grok Bot desktop app.
  # Roster rows are *agents* (not Grok Build sessions). One local transcript
  # replica per agent today. Never writes. Never reads credential files.
  class Bot
    TABLE32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

    def initialize(app_support: nil, bot_home: nil)
      @app_support = File.expand_path(app_support || Config.grok_bot_app_support)
      @bot_home = File.expand_path(bot_home || Config.grok_bot_home)
    end

    attr_reader :app_support, :bot_home

    def persistence_dir
      File.join(@app_support, "sand-client-persistence")
    end

    def available?
      Dir.exist?(persistence_dir)
    end

    def scan(warnings)
      return [] unless Config.grok_bot_enabled?
      unless available?
        warnings << "Grok Bot persistence not found: #{persistence_dir}" if Config.grok_bot_required?
        return []
      end

      blobs = index_blobs
      roster_path = blobs[:roster]
      unless roster_path && File.file?(roster_path)
        warnings << "Grok Bot roster blob missing under #{persistence_dir}"
        return []
      end

      roster = read_json(roster_path)
      rows = roster.dig("value", "rows")
      unless rows.is_a?(Array)
        warnings << "Grok Bot roster has no rows"
        return []
      end

      selected = selected_agent_id(blobs[:selection])
      sections = section_map(blobs[:sidebar])
      section_order = sections[:order] || []
      _app_pid, app_alive = app_liveness

      agents = rows.filter_map do |row|
        id = row["id"].to_s
        next if id.empty?

        replica = blobs[:replicas][id]
        sid, sname = (sections[:by_agent] || {})[id] || ["unassigned", "Unassigned"]
        name = row["name"].to_s.strip
        name = "Agent #{id[0, 8]}" if name.empty?
        desc = row["description"].to_s.strip
        last_text = row.dig("lastEntry", "text").to_s.strip
        awaiting = truthy?(row["awaitingUserResponse"])
        work = replica_work(replica, app_alive)
        status = work[:working] ? :working : :idle
        activity = status == :working ? work[:activity] : nil

        BotAgent.new(
          id: id,
          name: name,
          description: desc,
          section_id: sid,
          section: sname,
          status: status,
          awaiting: awaiting,
          selected: selected == id,
          activity: activity,
          last_entry: last_text.empty? ? nil : clip(last_text, 280),
          created_at: ms_time(row["createdAt"]),
          last_active_at: ms_time(row["lastActivityAt"] || row["updatedAt"]),
          app_alive: app_alive
        )
      rescue StandardError => e
        warnings << "Grok Bot agent #{row.is_a?(Hash) ? row["id"] : "?"}: #{e.class}: #{e.message}"
        nil
      end

      rank = {}
      section_order.each_with_index { |sid, i| rank[sid] = i }
      agents.sort_by do |a|
        [rank.fetch(a.section_id, 999), a.working? ? 0 : 1, -(a.last_active_at&.to_i || 0), a.name.to_s.downcase]
      end
    end

    def grouped(agents)
      groups = []
      agents.group_by(&:section_id).each do |sid, list|
        groups << { id: sid, name: list.first.section, agents: list }
      end
      groups
    end

    def self.encode_key(str)
      bytes = str.to_s.b.bytes
      bits = bytes.map { |b| format("%08b", b) }.join
      pad = (5 - (bits.length % 5)) % 5
      bits += "0" * pad
      bits.scan(/.{5}/).map { |chunk| TABLE32[chunk.to_i(2)] }.join.downcase
    end

    def self.decode_key(stem)
      s = stem.to_s.upcase.gsub(/[^A-Z2-7]/, "")
      return "" if s.empty?

      bits = +""
      s.each_char do |c|
        i = TABLE32.index(c)
        return "" unless i

        bits << format("%05b", i)
      end
      bytes = bits.scan(/.{8}/).map { |b| b.to_i(2) }
      bytes.pack("C*").force_encoding("UTF-8")
    rescue StandardError
      ""
    end

    private

    def index_blobs
      index = { replicas: {} }
      return index unless Dir.exist?(persistence_dir)

      Dir.children(persistence_dir).each do |name|
        next unless name.end_with?(".blob")

        key = self.class.decode_key(File.basename(name, ".blob"))
        path = File.join(persistence_dir, name)
        if key.end_with?("roster.last-roster")
          index[:roster] = path
        elsif key.end_with?("selection.last-agent")
          index[:selection] = path
        elsif key.end_with?("sidebar.last-sections")
          index[:sidebar] = path
        elsif key.include?(".transcript.replicas.")
          id = key.split(".").last
          index[:replicas][id] = path if id && !id.empty?
        end
      end
      index
    end

    def replica_path_for(id)
      index_blobs.dig(:replicas, id)
    end

    def selected_agent_id(path)
      return nil unless path && File.file?(path)

      read_json(path).dig("value", "agentId").to_s.then { |s| s.empty? ? nil : s }
    end

    def section_map(path)
      by_agent = {}
      order = []
      return { by_agent: by_agent, order: order } unless path && File.file?(path)

      Array(read_json(path).dig("value", "sections")).each do |sec|
        next unless sec.is_a?(Hash)

        sid = sec["id"].to_s
        next if sid.empty? || sid == "__agents__"

        sname = sec["name"].to_s
        sname = sid if sname.empty?
        order << sid unless order.include?(sid)
        Array(sec["agentIds"]).each { |aid| by_agent[aid.to_s] = [sid, sname] }
      end
      { by_agent: by_agent, order: order }
    end

    def replica_work(path, app_alive)
      empty = { working: false, activity: nil }
      return empty unless app_alive
      return empty unless path && File.file?(path)
      return empty if File.size(path) > 2_000_000

      entries = Array(read_json(path).dig("value", "entries"))
      streaming = false
      last_stream = nil
      last_assistant = nil
      entries.each do |entry|
        next unless entry.is_a?(Hash)

        text = entry_text(entry)
        if entry["isStreaming"] == true
          streaming = true
          last_stream = text unless text.empty?
        end
        if entry["kind"].to_s == "message" && entry["role"].to_s == "assistant"
          last_assistant = text unless text.empty?
        end
      end
      activity = last_stream || last_assistant
      {
        working: streaming,
        activity: activity ? clip(activity, 220) : nil
      }
    rescue StandardError
      empty
    end

    def entry_text(entry)
      raw = entry["content"]
      raw = entry.dig("message", "content") if raw.to_s.empty?
      raw = entry["text"] if raw.to_s.empty?
      raw.to_s.gsub(/\s+/, " ").strip
    end

    def truthy?(value)
      value == true || value.to_s == "true"
    end

    def app_liveness
      marker = File.join(@app_support, "sand-session-marker.json")
      return [nil, false] unless File.file?(marker)

      data = read_json(marker)
      pid = data["pid"].to_i
      return [nil, false] unless pid.positive?

      [pid, pid_alive?(pid)]
    rescue StandardError
      [nil, false]
    end

    def pid_alive?(pid)
      Process.kill(0, pid.to_i)
      true
    rescue Errno::ESRCH, Errno::EPERM, TypeError
      false
    end

    def ms_time(value)
      return nil if value.nil?

      n = value.to_i
      return nil unless n.positive?

      Time.at(n / 1000.0).utc
    end

    def read_json(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError, Errno::ENOENT
      {}
    end

    def clip(text, max)
      t = text.to_s.gsub(/\s+/, " ").strip
      return t if t.length <= max

      "#{t[0, max - 1]}…"
    end
  end
end
