# frozen_string_literal: true

require "json"
require "time"

module GrokLens
  # Read-only adapter for the Grok Bot desktop app.
  # Sessions are agents in `roster.last-roster`; chat replicas live beside it
  # as `transcript.replicas.<uuid>` blobs. Never writes. Never reads
  # local-exec-daemon-connection.json or other credential files.
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
      app_pid, app_alive = app_liveness
      now = Time.now.utc

      rows.filter_map do |row|
        id = row["id"].to_s
        next if id.empty?

        replica = blobs[:replicas][id]
        replica_bytes = replica && File.file?(replica) ? File.size(replica) : 0
        section_id, section_name = sections[id] || ["unassigned", "Grok Bot"]
        title = row["name"].to_s.strip
        title = "Bot #{id[0, 8]}" if title.empty?
        desc = row["description"].to_s.strip
        last_text = row.dig("lastEntry", "text").to_s.strip
        created = ms_time(row["createdAt"])
        updated = ms_time(row["lastActivityAt"] || row["updatedAt"])
        awaiting = !row["awaitingUserResponse"].nil? && row["awaitingUserResponse"] != false
        status = bot_status(app_alive, selected, id, awaiting)
        pid = (status == :active) ? app_pid : nil

        Session.new(
          id: id,
          cwd: "grok-bot://#{section_id}",
          title: title,
          summary_text: desc,
          status: status,
          pid: pid,
          models: [],
          current_model_id: nil,
          created_at: created,
          last_active_at: updated,
          opened_at: status == :active ? now : nil,
          num_messages: 0,
          num_chat_messages: 0,
          num_turns: 0,
          tool_counts: {},
          est_tokens: Estimate.size_based(chat_history_bytes: replica_bytes, events_bytes: 0),
          context_tokens: nil,
          context_window: nil,
          est_source: replica_bytes.positive? ? "size" : nil,
          disk_bytes: replica_bytes,
          agent_name: title,
          session_kind: "bot",
          parent_id: nil,
          children: [],
          first_user_prompt: last_text.empty? ? nil : clip(last_text, 500),
          git_root: nil,
          git_branch: nil,
          git_commit: nil,
          activity_points: [],
          detail_loaded: false,
          running_tasks: [],
          source: :bot,
          bot_section: section_name
        )
      rescue StandardError => e
        warnings << "Grok Bot agent #{row.is_a?(Hash) ? row["id"] : "?"}: #{e.class}: #{e.message}"
        nil
      end
    end

    def enrich(session)
      return session if session.nil? || session.detail_loaded

      replica = replica_path_for(session.id)
      return session.with(detail_loaded: true) unless replica && File.file?(replica)
      return session.with(detail_loaded: true) if File.size(replica) > 2_000_000

      data = read_json(replica)
      entries = data.dig("value", "entries")
      entries = [] unless entries.is_a?(Array)

      first = nil
      counts = Hash.new(0)
      models = []
      streaming = false
      entries.each do |entry|
        next unless entry.is_a?(Hash)

        kind = entry["kind"].to_s
        counts[kind] += 1
        models << entry["model"] if entry["model"]
        models << entry["modelId"] if entry["modelId"]
        streaming ||= entry["isStreaming"] == true
        next if first
        next unless kind == "message" && entry["role"].to_s == "user"

        text = entry["content"].to_s
        if text =~ %r{<user_query>\s*([\s\S]*?)\s*</user_query>}i
          text = Regexp.last_match(1)
        end
        first = clip(text, 500) unless text.to_s.strip.empty?
      end

      msgs = counts["message"].to_i
      tasks = []
      if streaming
        tasks << RunningTask.new(
          id: "#{session.id}:stream",
          kind: :tool,
          title: "streaming",
          status: "running",
          tool_name: nil,
          live: true
        )
      end

      session.with(
        first_user_prompt: first || session.first_user_prompt,
        num_messages: msgs,
        num_chat_messages: msgs,
        models: models.compact.uniq,
        current_model_id: session.current_model_id || models.compact.last,
        running_tasks: tasks,
        detail_loaded: true
      )
    rescue StandardError
      session.with(detail_loaded: true)
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
      map = {}
      return map unless path && File.file?(path)

      Array(read_json(path).dig("value", "sections")).each do |sec|
        next unless sec.is_a?(Hash)

        sid = sec["id"].to_s
        sname = sec["name"].to_s
        sname = sid if sname.empty?
        Array(sec["agentIds"]).each { |aid| map[aid.to_s] = [sid, sname] }
      end
      map
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

    def bot_status(app_alive, selected, id, awaiting)
      return :idle unless app_alive
      return :active if awaiting
      return :active if selected && selected == id

      :idle
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
