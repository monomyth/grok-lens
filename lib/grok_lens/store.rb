# frozen_string_literal: true

require "json"
require "cgi"
require "digest"
require "time"

module GrokLens
  class Store
    UUID_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

    def initialize(grok_home: nil)
      @grok_home = File.expand_path(grok_home || ENV.fetch("GROK_HOME", File.expand_path("~/.grok")))
    end

    attr_reader :grok_home

    def scan
      warnings = []
      unless Dir.exist?(@grok_home)
        return empty_snapshot(missing: true, warnings: ["GROK_HOME not found: #{@grok_home}"])
      end

      active_map = load_active(warnings)
      search_titles = load_search_titles(warnings)
      sessions = []

      sessions_root = File.join(@grok_home, "sessions")
      if Dir.exist?(sessions_root)
        Dir.children(sessions_root).each do |entry|
          next if entry.end_with?(".sqlite") || entry.start_with?(".")

          project_dir = File.join(sessions_root, entry)
          next unless File.directory?(project_dir)

          cwd_from_dir = decode_cwd(entry)
          Dir.children(project_dir).each do |sid|
            next unless sid.match?(UUID_RE)

            session_dir = File.join(project_dir, sid)
            next unless File.directory?(session_dir)

            begin
              sessions << load_session_light(session_dir, sid, cwd_from_dir, active_map, search_titles)
            rescue StandardError => e
              warnings << "session #{sid}: #{e.class}: #{e.message}"
            end
          end
        end
      else
        warnings << "No sessions directory under #{@grok_home}"
      end

      nest!(sessions)
      # Attach live running tasks for sessions that might have in-flight work:
      # live OS process, or a child / meta.json still marked running.
      ps_index = process_command_index
      sessions.map! do |s|
        dir = session_dir_for(s)
        next s unless dir

        metas = load_subagent_metas(dir)
        needs_tasks = s.active? ||
                      Array(s.children).any?(&:active?) ||
                      metas.any? { |_id, meta| subagent_running?(meta["status"]) }
        next s unless needs_tasks

        tasks = load_running_tasks(dir, s, ps_index, metas: metas)
        s.with(running_tasks: tasks)
      end

      assemble_snapshot(sessions, warnings, missing: false)
    end

    def enrich_session(session)
      return session if session.nil? || session.detail_loaded

      dir = session_dir_for(session)
      return session.with(detail_loaded: true) unless dir && Dir.exist?(dir)

      tool_counts = Hash.new(0)
      models = session.models.dup
      activity = []
      events_path = File.join(dir, "events.jsonl")
      if File.file?(events_path)
        each_jsonl(events_path) do |obj|
          case obj["type"]
          when "turn_started"
            models << obj["model_id"] if obj["model_id"]
            activity << 1
          when "tool_started", "tool_completed"
            name = obj["tool_name"] || obj["name"]
            tool_counts[name] += 1 if name
            activity << 0.5
          when "first_token"
            activity << 0.3
          end
        end
      end

      first_prompt = session.first_user_prompt
      chat_path = File.join(dir, "chat_history.jsonl")
      if (first_prompt.nil? || first_prompt.empty?) && File.file?(chat_path)
        first_prompt = extract_first_user_prompt(chat_path)
      end

      tasks = session.running_tasks
      if tasks.nil? || tasks.empty?
        tasks = load_running_tasks(dir, session, process_command_index)
      end

      session.with(
        models: models.compact.uniq,
        tool_counts: tool_counts,
        first_user_prompt: first_prompt,
        activity_points: downsample(activity, 48),
        detail_loaded: true,
        running_tasks: tasks
      )
    end

    private

    def assemble_snapshot(sessions, warnings, missing:)
      sessions_by_id = sessions.to_h { |s| [s.id, s] }
      primaries = sessions.select(&:primary?).sort_by { |s| s.last_active_at || s.created_at || Time.at(0) }.reverse
      projects = build_projects(primaries, warnings)
      active = primaries.select { |s| s.active? || s.stale? || s.running_count.positive? }
                        .sort_by { |s| s.opened_at || s.last_active_at || Time.at(0) }.reverse

      total_est = sessions.sum { |s| s.est_tokens.to_i }
      models_hist = Hash.new(0)
      primaries.each do |s|
        (s.models.empty? ? [s.current_model_id].compact : s.models).each { |m| models_hist[m] += 1 }
      end

      Snapshot.new(
        scanned_at: Time.now.utc,
        grok_home: @grok_home,
        projects: projects,
        sessions_by_id: sessions_by_id,
        primary_sessions: primaries,
        active_sessions: active,
        warnings: warnings,
        total_est_tokens: total_est,
        models_hist: models_hist,
        missing_home: missing
      )
    end

    def empty_snapshot(missing:, warnings:)
      Snapshot.new(
        scanned_at: Time.now.utc,
        grok_home: @grok_home,
        projects: [],
        sessions_by_id: {},
        primary_sessions: [],
        active_sessions: [],
        warnings: warnings,
        total_est_tokens: 0,
        models_hist: {},
        missing_home: missing
      )
    end

    def decode_cwd(encoded)
      CGI.unescape(encoded)
    rescue StandardError
      encoded
    end

    def load_active(warnings)
      map = {}
      path = File.join(@grok_home, "active_sessions.json")
      if File.file?(path)
        begin
          data = JSON.parse(File.read(path))
          Array(data).each do |row|
            id = row["session_id"]
            next unless id

            map[id] = {
              pid: row["pid"],
              cwd: row["cwd"],
              opened_at: parse_time(row["opened_at"]),
              source: "active_sessions"
            }
          end
        rescue StandardError => e
          warnings << "active_sessions.json: #{e.message}"
        end
      end

      # Grok sometimes leaves a live process out of active_sessions.json
      # (e.g. `grok --resume <uuid>`). Discover those from the process table.
      resolve_registry_pid_ownership(map)
      discover_live_from_processes(map, warnings)
      map
    end

    UUID_INLINE = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i

    # Registry rows often share a still-living PID after resume. If that
    # process's command line names a different session UUID, drop the stale claim.
    def resolve_registry_pid_ownership(map)
      by_pid = Hash.new { |h, k| h[k] = [] }
      map.each do |id, info|
        pid = info[:pid].to_i
        next unless pid.positive?

        by_pid[pid] << id
      end

      by_pid.each do |pid, ids|
        next unless pid_alive?(pid)

        cmd = pid_command(pid)
        next if cmd.strip.empty?
        next unless grok_like_process?(cmd)

        mentioned = cmd.scan(UUID_INLINE)
        if mentioned.any?
          mentioned_down = mentioned.map(&:downcase)
          ids.each do |id|
            map.delete(id) unless mentioned_down.include?(id.downcase)
          end
        end

        remain = ids.select { |id| map.key?(id) }
        next if remain.size <= 1

        keep =
          if mentioned.any?
            hit = mentioned.find { |u| remain.any? { |id| id.casecmp?(u) } }
            remain.find { |id| id.casecmp?(hit.to_s) } if hit
          end
        keep ||= remain.max_by { |id| map[id][:opened_at] || Time.at(0) }
        remain.each { |id| map.delete(id) unless id == keep }
      end
    end

    def grok_like_process?(cmd)
      s = cmd.to_s
      s.match?(%r{(?:^|[/\s])grok(?:\s|$)}i) || s.include?("--resume") || s.include?("--continue")
    end

    def process_table
      `ps -ax -o pid=,command= 2>/dev/null`.to_s
    end

    def pid_command(pid)
      return "" if pid.nil?

      `ps -p #{pid.to_i} -o command= 2>/dev/null`.to_s
    rescue StandardError
      ""
    end

    def discover_live_from_processes(map, warnings)
      out = process_table
      return if out.nil? || out.empty?

      out.each_line do |line|
        line = line.strip
        next if line.empty?
        next unless line.match?(/\bgrok\b/i)
        next if line.include?("ps -ax")

        pid = line[/\A\s*(\d+)/, 1]&.to_i
        next unless pid&.positive?

        ids = line.scan(UUID_INLINE)
        next if ids.empty?

        ids.each do |id|
          existing = map[id]
          # Prefer a live process pid over a stale registry entry
          if existing.nil? || !pid_alive?(existing[:pid])
            map[id] = {
              pid: pid,
              cwd: existing&.dig(:cwd),
              opened_at: existing&.dig(:opened_at),
              source: "process"
            }
          end
        end
      end
    rescue StandardError => e
      warnings << "process scan: #{e.message}"
    end

    def load_search_titles(warnings)
      path = File.join(@grok_home, "sessions", "session_search.sqlite")
      return {} unless File.file?(path)

      require "sqlite3"
      db = SQLite3::Database.new(path, readonly: true)
      rows = db.execute("SELECT session_id, title FROM session_docs")
      rows.to_h
    rescue LoadError
      warnings << "sqlite3 gem unavailable; skipping search index"
      {}
    rescue StandardError => e
      warnings << "session_search.sqlite: #{e.message}"
      {}
    ensure
      db&.close
    end

    def load_session_light(session_dir, sid, cwd_from_dir, active_map, search_titles)
      summary_path = File.join(session_dir, "summary.json")
      summary = {}
      if File.file?(summary_path)
        summary = JSON.parse(File.read(summary_path))
      end

      info = summary["info"] || {}
      cwd = info["cwd"] || cwd_from_dir
      title = summary["generated_title"].to_s
      title = summary["session_summary"].to_s if title.empty?
      title = search_titles[sid].to_s if title.empty?
      title = "Untitled #{sid[0, 8]}" if title.empty?

      summary_text = summary["session_summary"].to_s
      chat_bytes = file_size(File.join(session_dir, "chat_history.jsonl"))
      events_bytes = file_size(File.join(session_dir, "events.jsonl"))
      disk = dir_size(session_dir)
      num_messages = summary["num_messages"].to_i
      tok = Estimate.for_session(
        session_dir: session_dir,
        chat_history_bytes: chat_bytes,
        events_bytes: events_bytes,
        num_messages: num_messages
      )

      active = active_map[sid]
      status =
        if active
          pid_alive?(active[:pid]) ? :active : :stale
        else
          :idle
        end

      kind = summary["session_kind"]
      parent_id = summary["parent_session_id"]
      # Subagent sessions sometimes lack parent_session_id; leave parent nil and attach via subagents/ later if needed
      models = [summary["current_model_id"]].compact

      Session.new(
        id: sid,
        cwd: cwd,
        title: title.strip,
        summary_text: summary_text.strip,
        status: status,
        pid: active&.dig(:pid),
        models: models,
        current_model_id: summary["current_model_id"],
        created_at: parse_time(summary["created_at"]),
        last_active_at: parse_time(summary["last_active_at"] || summary["updated_at"]),
        opened_at: active&.dig(:opened_at),
        num_messages: num_messages,
        num_chat_messages: summary["num_chat_messages"].to_i,
        num_turns: summary["next_trace_turn"].to_i,
        tool_counts: {},
        est_tokens: tok[:est_tokens],
        context_tokens: tok[:context_tokens],
        context_window: tok[:context_window],
        est_source: tok[:est_source],
        disk_bytes: disk,
        agent_name: summary["agent_name"],
        session_kind: kind,
        parent_id: parent_id,
        children: [],
        first_user_prompt: nil,
        git_root: summary["git_root_dir"],
        git_branch: summary["head_branch"],
        git_commit: summary["head_commit"],
        activity_points: [],
        detail_loaded: false,
        running_tasks: [],
        source: :grok,
        bot_section: nil
      )
    end

    TERMINAL_STATUSES = %w[completed failed cancelled error rejected success].freeze
    FOREGROUND_STALE_SECS = 180

    SUBAGENT_RUNNING = %w[running in_progress started active].freeze

    def load_running_tasks(session_dir, session, ps_index = nil, metas: nil)
      ps_index ||= process_command_index
      tasks = []
      updates = File.join(session_dir, "updates.jsonl")
      if File.file?(updates)
        open_calls = parse_open_tool_calls(updates)
        open_calls.each do |cid, info|
          live = task_live?(info, ps_index, session)
          next unless live

          title = short_task_title(info)
          kind = info[:bg] ? :bg_shell : :tool
          tasks << RunningTask.new(
            id: cid,
            kind: kind,
            title: title,
            status: info[:status].to_s.empty? ? "running" : info[:status].to_s,
            tool_name: info[:tool_name],
            live: true
          )
        end
      end

      # Live subagents under this session (own OS pid, or in-process via meta.json)
      Array(session.children).each do |child|
        next unless child.active?

        tasks << RunningTask.new(
          id: child.id,
          kind: :subagent,
          title: child.title.to_s.empty? ? "subagent #{child.id[0, 8]}" : child.title,
          status: "live",
          tool_name: child.current_model_id,
          live: true
        )
      end

      metas = load_subagent_metas(session_dir) if metas.nil?
      metas.each do |cid, meta|
        next unless subagent_running?(meta["status"])
        next if tasks.any? { |t| t.id == cid }

        desc = meta["description"].to_s.strip
        tasks << RunningTask.new(
          id: cid,
          kind: :subagent,
          title: desc.empty? ? "subagent #{cid[0, 8]}" : clip_sentence(desc, 100),
          status: meta["status"].to_s,
          tool_name: meta["effective_model_id"],
          live: true
        )
      end

      tasks
    rescue StandardError
      []
    end

    def load_subagent_metas(session_dir)
      root = File.join(session_dir, "subagents")
      return {} unless Dir.exist?(root)

      metas = {}
      Dir.children(root).each do |cid|
        next unless cid.match?(UUID_RE)

        path = File.join(root, cid, "meta.json")
        next unless File.file?(path)

        begin
          metas[cid] = JSON.parse(File.read(path))
        rescue JSON::ParserError, Errno::ENOENT
          next
        end
      end
      metas
    end

    def subagent_running?(status)
      SUBAGENT_RUNNING.include?(status.to_s.downcase)
    end

    def parse_open_tool_calls(updates_path, max_bytes: 2_500_000)
      size = File.size(updates_path)
      start = size > max_bytes ? size - max_bytes : 0
      data = File.open(updates_path, "rb") do |f|
        f.seek(start)
        f.read
      end.to_s
      # drop partial first line when mid-file
      data = data.split("\n", 2).last if start.positive?

      calls = {}
      data.each_line do |line|
        line = line.strip
        next if line.empty?

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

        info = calls[cid] || { first_ts: obj["timestamp"], last_ts: obj["timestamp"] }
        info[:last_ts] = obj["timestamp"] if obj["timestamp"]
        info[:title] = update["title"] if update["title"]
        info[:status] = update["status"] if update["status"]
        raw = update["rawInput"]
        if raw.is_a?(Hash)
          info[:command] = raw["command"].to_s if raw["command"]
          info[:description] = raw["description"].to_s if raw["description"]
          info[:bg] = true if raw["background"] == true || raw["background"].to_s == "true"
        end
        meta = update["_meta"]
        if meta.is_a?(Hash)
          tool = meta["x.ai/tool"] || meta["tool"]
          if tool.is_a?(Hash)
            info[:tool_name] = tool["name"] || tool["label"]
            input = tool["input"]
            if input.is_a?(Hash)
              info[:command] ||= input["command"].to_s
              info[:description] ||= input["description"].to_s
              info[:bg] = true if input["background"] == true
            end
          end
        end
        title = info[:title].to_s
        info[:bg] = true if title.include?("[bg") || title.match?(/\(0[0-9a-f]{7}/i)
        calls[cid] = info
      end

      # drop finished
      calls.reject! do |_cid, info|
        TERMINAL_STATUSES.include?(info[:status].to_s.downcase)
      end
      calls
    end

    def task_live?(info, ps_index, session)
      # TUI "tasks running" ≈ background work still attached to a live process.
      # Foreground tool chatter is only shown on detail when very recent.
      if info[:bg] || info[:tool_name].to_s == "run_terminal_command"
        return command_appears_running?(info, ps_index, session)
      end

      return false unless session.active?

      ts = info[:last_ts]
      return false if ts.nil?

      age = (Time.now.to_i - ts.to_i).abs
      age <= FOREGROUND_STALE_SECS
    end

    def command_appears_running?(info, ps_index, session = nil)
      cmd = info[:command].to_s
      title = info[:title].to_s
      hay = "#{cmd}\n#{title}"

      # Prefer descendants of the session's grok pid when known
      if session&.pid && pid_alive?(session.pid)
        kids = descendant_commands(session.pid)
        return true if kids.any? { |line| command_matches_line?(info, line) }
      end

      # Port listeners (rackup/puma etc.)
      ports = hay.scan(/(?:PORT=|[:-]p\s+|port\s+|:)(\d{4,5})\b/i).flatten
      ports += hay.scan(/\b(8\d{3}|9\d{3}|3\d{3})\b/).flatten # common dev ports
      ports.uniq.each do |port|
        next unless port.to_i.between?(1024, 65_535)
        return true if port_listening?(port)
      end

      needles = command_needles(info)
      needles.any? { |n| ps_index.any? { |line| line.include?(n) } }
    end

    def command_matches_line?(info, line)
      command_needles(info).any? { |n| line.include?(n) } ||
        (info[:command].to_s.include?("rackup") && line.include?("puma") && line.include?("grok-lens"))
    end

    def command_needles(info)
      cmd = info[:command].to_s
      title = info[:title].to_s
      needles = []
      cmd.each_line do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")
        next if line.length < 20
        next if line.match?(/\A(export|cd|sleep|echo|PIDS=|if |for |then|fi|done|true|false|\[)\b/)

        needles << line[0, 40]
      end
      if needles.empty? && title.length > 16
        t = title.sub(/\A\[bg\]\s*/i, "").sub(/\s*\(0[0-9a-f]{7}[^)]*\)\s*\z/i, "")
        needles << t[0, 40] if t.length >= 16
      end
      needles.uniq
    end

    def descendant_commands(root_pid, depth = 3)
      lines = []
      frontier = [root_pid.to_i]
      depth.times do
        break if frontier.empty?

        next_gen = []
        frontier.each do |pid|
          out = `pgrep -P #{pid} 2>/dev/null`
          out.to_s.split.each do |cpid|
            cpid = cpid.to_i
            next unless cpid.positive?

            next_gen << cpid
            cmd = `ps -p #{cpid} -o command= 2>/dev/null`.to_s.strip
            lines << cmd unless cmd.empty?
          end
        end
        frontier = next_gen
      end
      lines
    rescue StandardError
      []
    end

    def port_listening?(port)
      out = `lsof -nP -iTCP:#{port} -sTCP:LISTEN 2>/dev/null`
      return true if out && !out.strip.empty?

      process_command_index.any? { |l| l.include?(":#{port}") || l.include?(" #{port}") }
    rescue StandardError
      false
    end

    def process_command_index
      @process_command_index ||= begin
        out = `ps -ax -o pid=,command= 2>/dev/null`
        out.to_s.each_line.map(&:strip).reject(&:empty?)
      rescue StandardError
        []
      end
    end

    def short_task_title(info)
      if info[:description].to_s.strip != ""
        return clip_sentence(info[:description], 100)
      end

      title = info[:title].to_s.sub(/\A\[bg\]\s*/i, "")
      title = title.sub(/\s*\(0[0-9a-f]{7}[^)]*\)\s*\z/i, "")
      # collapse multi-line shell into first useful line
      line = title.each_line.map(&:strip).find { |l| !l.empty? && !l.start_with?("#") } || title
      clip_sentence(line, 100)
    end

    def nest!(sessions)
      by_id = sessions.to_h { |s| [s.id, s] }
      parent_of = {}

      sessions.each do |s|
        parent_of[s.id] = s.parent_id if s.parent_id && by_id[s.parent_id]
      end

      running_from_meta = {}
      sessions.each do |s|
        dir = session_dir_for(s)
        next unless dir

        sub_root = File.join(dir, "subagents")
        next unless Dir.exist?(sub_root)

        Dir.children(sub_root).each do |cid|
          next unless cid.match?(UUID_RE)
          next unless by_id[cid]

          parent_of[cid] = s.id
        end

        load_subagent_metas(dir).each do |cid, meta|
          parent_of[cid] = s.id if by_id[cid]
          running_from_meta[cid] = true if subagent_running?(meta["status"])
        end
      end

      children_map = Hash.new { |h, k| h[k] = [] }
      parent_of.each do |child_id, parent_id|
        children_map[parent_id] << child_id
      end

      sessions.map! do |s|
        parent_id = parent_of[s.id]
        kind = s.session_kind
        kind = "subagent" if parent_id && kind.to_s.empty?
        kids = children_map[s.id].filter_map { |cid| by_id[cid] }
          .map { |c|
            live = c.active? || running_from_meta[c.id]
            c.with(
              parent_id: s.id,
              session_kind: c.session_kind || "subagent",
              status: live ? :active : c.status
            )
          }
          .sort_by { |c| c.last_active_at || Time.at(0) }.reverse
        own_status = running_from_meta[s.id] ? :active : s.status
        s.with(parent_id: parent_id, session_kind: kind, children: kids, status: own_status)
      end
    end

    def build_projects(primaries, warnings)
      groups = primaries.group_by(&:cwd)
      groups.map do |path, sess|
        name = File.basename(path.to_s)
        name = path if name.nil? || name.empty?
        last = sess.map { |s| s.last_active_at }.compact.max
        est = sess.sum { |s| s.est_tokens.to_i + s.children.sum { |c| c.est_tokens.to_i } }
        disk = sess.sum { |s| s.disk_bytes.to_i + s.children.sum { |c| c.disk_bytes.to_i } }
        hist = Hash.new(0)
        sess.each do |s|
          ([s.current_model_id] + s.models).compact.uniq.each { |m| hist[m] += 1 }
        end
        desc = project_description(path, sess)
        Project.new(
          id: project_id(path),
          path: path,
          name: name,
          description: desc,
          sessions: sess.sort_by { |s| s.last_active_at || Time.at(0) }.reverse,
          session_count: sess.size,
          est_tokens: est,
          models_hist: hist,
          last_active_at: last,
          disk_bytes: disk
        )
      end.sort_by { |p| p.last_active_at || Time.at(0) }.reverse
    end

    def project_id(path)
      raw = path.to_s
      slug = raw.gsub(%r{[^a-zA-Z0-9]+}, "-").gsub(/\A-+|-+\z/, "")
      slug = "project" if slug.empty?
      digest = Digest::SHA256.hexdigest(raw)[0, 8]
      "#{slug}-#{digest}"
    end

    def project_description(path, sessions)
      newest = sessions.max_by { |s| s.last_active_at || Time.at(0) }
      if newest
        text = newest.summary_text
        text = newest.title if text.nil? || text.empty?
        return clip_sentence(text, 240) if text && !text.empty?
      end

      readme = File.join(path, "README.md")
      if File.file?(readme)
        body = File.read(readme, 4000)
        para = body.lines.map(&:strip).reject { |l| l.empty? || l.start_with?("#") }.first
        return clip_sentence(para, 240) if para
      end

      "No description yet"
    rescue StandardError
      "No description yet"
    end

    def clip_sentence(text, max)
      t = text.to_s.gsub(/\s+/, " ").strip
      return t if t.length <= max

      "#{t[0, max - 1]}…"
    end

    def session_dir_for(session)
      sessions_root = File.join(@grok_home, "sessions")
      return nil unless Dir.exist?(sessions_root)

      encoded = session.cwd.to_s.gsub("/", "%2F")
      candidate = File.join(sessions_root, encoded, session.id)
      return candidate if Dir.exist?(candidate)

      Dir.children(sessions_root).each do |entry|
        next if entry.end_with?(".sqlite")

        d = File.join(sessions_root, entry, session.id)
        return d if Dir.exist?(d)
      end
      nil
    end

    def pid_alive?(pid)
      return false if pid.nil?

      Process.kill(0, pid.to_i)
      true
    rescue Errno::ESRCH, Errno::EPERM, TypeError
      false
    end

    def parse_time(value)
      return nil if value.nil? || value.to_s.empty?
      return value if value.is_a?(Time)

      Time.parse(value.to_s).utc
    rescue ArgumentError
      nil
    end

    def file_size(path)
      File.file?(path) ? File.size(path) : 0
    end

    def dir_size(dir)
      total = 0
      Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).each do |f|
        next unless File.file?(f)

        base = File.basename(f)
        next if base == "updates.jsonl"
        next if base.end_with?(".lock")
        next if f.include?("#{File::SEPARATOR}terminal#{File::SEPARATOR}")

        total += File.size(f)
      rescue StandardError
        next
      end
      total
    end

    def each_jsonl(path, max_bytes: 50_000_000)
      size = File.size(path)
      return if size > max_bytes && max_bytes.positive?

      File.foreach(path) do |line|
        line = line.strip
        next if line.empty?

        yield JSON.parse(line)
      rescue JSON::ParserError
        next
      end
    end

    def extract_first_user_prompt(chat_path, max_bytes: 2_000_000)
      return nil unless File.file?(chat_path)

      read = 0
      File.foreach(chat_path) do |line|
        read += line.bytesize
        obj = JSON.parse(line)
        if obj["type"] == "user"
          text = flatten_content(obj["content"])
          cleaned = scrub_prompt_wrappers(text)
          return clip_sentence(cleaned, 500) unless cleaned.nil? || cleaned.empty?
        end
        break if read >= max_bytes
      rescue JSON::ParserError
        next
      end
      nil
    end

    # Strip TUI envelope tags so skim shows only the human text.
    def scrub_prompt_wrappers(text)
      s = text.to_s
      return nil if s.strip.empty?

      # Prefer explicit user_query body when present
      if s =~ %r{<user_query>\s*([\s\S]*?)\s*</user_query>}i
        s = Regexp.last_match(1)
      end

      s = s.gsub(%r{<user_info>[\s\S]*?</user_info>}i, "")
           .gsub(%r{<system-reminder>[\s\S]*?</system-reminder>}i, "")
           .gsub(%r{</?user_query>}i, "")
           .gsub(%r{</?user_info>}i, "")
           .gsub(%r{</?system-reminder>}i, "")
           .strip

      # Skip pure-metadata synthetic turns
      return nil if s.empty?
      return nil if s.start_with?("<") && !s.match?(/[a-zA-Z]{3,}/)

      s
    end

    def flatten_content(content)
      case content
      when String then content
      when Array
        content.map do |part|
          if part.is_a?(Hash)
            part["text"] || part["content"] || ""
          else
            part.to_s
          end
        end.join("\n")
      else
        content.to_s
      end
    end

    def downsample(points, n)
      return points if points.size <= n
      return [] if points.empty?

      step = points.size.to_f / n
      Array.new(n) { |i| points[(i * step).floor] || 0 }
    end
  end
end
