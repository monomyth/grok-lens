# frozen_string_literal: true

require "json"
require "time"

module GrokLens
  # Read-only Codex sessions from ~/.codex.
  # Home scan: session_index.jsonl + first session_meta (and nearby turn_context
  # for model) from the matching rollout file. Never parses a full rollout.
  class Codex
    UUID_RE = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i
    PREFIX_BYTES = 65_536

    def initialize(home: nil)
      @home = File.expand_path(home || Config.codex_home)
    end

    attr_reader :home

    def scan(warnings)
      return [] unless Config.codex_enabled?

      unless Dir.exist?(@home)
        warnings << "Codex home not found: #{@home}" if Config.codex_required?
        return []
      end

      index = load_index(warnings)
      rollouts = index_rollouts
      live = live_pids
      seen = {}

      sessions = []
      index.each do |row|
        id = row["id"].to_s
        next if id.empty? || seen[id]

        seen[id] = true
        path = rollouts[id]
        meta = path ? read_prefix_meta(path) : {}
        cwd = meta[:cwd].to_s
        title = row["thread_name"].to_s.strip
        title = "Codex #{id[0, 8]}" if title.empty?
        updated = parse_time(row["updated_at"]) || meta[:timestamp]
        pid = live[id]
        sessions << build_session(
          id: id,
          cwd: cwd,
          title: title,
          status: pid ? :active : :idle,
          pid: pid,
          model: meta[:model],
          created_at: meta[:timestamp],
          last_active_at: updated,
          disk_bytes: path && File.file?(path) ? File.size(path) : 0
        )
      end

      # Rollouts not listed in the index still belong in the ledger.
      rollouts.each do |id, path|
        next if seen[id]

        meta = read_prefix_meta(path)
        cwd = meta[:cwd].to_s
        title = meta[:title].to_s.strip
        title = "Codex #{id[0, 8]}" if title.empty?
        pid = live[id]
        sessions << build_session(
          id: id,
          cwd: cwd,
          title: title,
          status: pid ? :active : :idle,
          pid: pid,
          model: meta[:model],
          created_at: meta[:timestamp],
          last_active_at: file_mtime(path) || meta[:timestamp],
          disk_bytes: File.size(path)
        )
      end

      sessions
    rescue StandardError => e
      warnings << "Codex scan: #{e.class}: #{e.message}"
      []
    end

    private

    def load_index(warnings)
      path = File.join(@home, "session_index.jsonl")
      return [] unless File.file?(path)

      rows = []
      File.foreach(path) do |line|
        line = line.strip
        next if line.empty?

        begin
          obj = JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        rows << obj if obj.is_a?(Hash) && obj["id"]
      end
      rows
    rescue StandardError => e
      warnings << "Codex session_index.jsonl: #{e.message}"
      []
    end

    def index_rollouts
      map = {}
      %w[sessions archived_sessions].each do |dir|
        root = File.join(@home, dir)
        next unless Dir.exist?(root)

        Dir.glob(File.join(root, "**", "rollout-*.jsonl")).each do |path|
          id = path[UUID_RE]
          map[id] = path if id
        end
      end
      map
    end

    def read_prefix_meta(path)
      return {} unless File.file?(path)

      data = File.open(path, "rb") { |f| f.read(PREFIX_BYTES).to_s }
      meta = {}
      data.each_line do |line|
        line = line.strip
        next if line.empty?

        begin
          obj = JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        next unless obj.is_a?(Hash)

        payload = obj["payload"]
        payload = {} unless payload.is_a?(Hash)
        case obj["type"]
        when "session_meta"
          meta[:cwd] ||= payload["cwd"]
          meta[:timestamp] ||= parse_time(obj["timestamp"] || payload["timestamp"])
          meta[:title] ||= payload["thread_name"] || payload["title"]
          meta[:model] ||= payload["model"] || payload["model_id"]
        when "turn_context"
          meta[:cwd] ||= payload["cwd"]
          meta[:model] ||= payload["model"]
        end
        break if meta[:cwd] && meta[:model] && meta[:timestamp]
      end
      meta
    rescue StandardError
      {}
    end

    def live_pids
      map = {}
      `ps -ax -o pid=,command= 2>/dev/null`.to_s.each_line do |line|
        next unless line.match?(/\bcodex\b/i)

        pid = line[/\A\s*(\d+)/, 1].to_i
        next unless pid.positive?

        line.scan(UUID_RE).each { |id| map[id] = pid }
      end
      map
    rescue StandardError
      {}
    end

    def file_mtime(path)
      File.mtime(path).utc
    rescue StandardError
      nil
    end

    def parse_time(value)
      return nil if value.nil? || value.to_s.empty?
      return value.utc if value.is_a?(Time)

      Time.parse(value.to_s).utc
    rescue ArgumentError
      nil
    end

    def build_session(id:, cwd:, title:, status:, pid:, model:, created_at:, last_active_at:, disk_bytes:)
      Session.new(
        id: id,
        cwd: cwd,
        title: title,
        summary_text: "",
        status: status,
        pid: pid,
        models: [model].compact,
        current_model_id: model,
        created_at: created_at,
        last_active_at: last_active_at,
        opened_at: pid ? Time.now.utc : nil,
        num_messages: 0,
        num_chat_messages: 0,
        num_turns: 0,
        tool_counts: {},
        est_tokens: 0,
        context_tokens: nil,
        context_window: nil,
        est_source: nil,
        billed: false,
        cost_usd: nil,
        usage: nil,
        disk_bytes: disk_bytes.to_i,
        agent_name: nil,
        session_kind: nil,
        parent_id: nil,
        children: [],
        first_user_prompt: nil,
        git_root: nil,
        git_branch: nil,
        git_commit: nil,
        activity_points: [],
        detail_loaded: false,
        running_tasks: [],
        source: :codex,
        bot_section: nil,
        mcp_names: []
      )
    end
  end
end
