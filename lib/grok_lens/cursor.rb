# frozen_string_literal: true

require "json"
require "time"

module GrokLens
  # Read-only Cursor agent transcripts under ~/.cursor/projects.
  # History only: title from first user text, cwd from project slug.
  class Cursor
    UUID_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

    def initialize(home: nil)
      @home = File.expand_path(home || Config.cursor_home)
    end

    attr_reader :home

    def scan(warnings)
      return [] unless Config.cursor_enabled?

      projects = File.join(@home, "projects")
      unless Dir.exist?(projects)
        warnings << "Cursor projects not found: #{projects}" if Config.cursor_required?
        return []
      end

      live = cursor_app_alive?
      sessions = []
      Dir.children(projects).each do |slug|
        next if slug.start_with?(".")

        root = File.join(projects, slug)
        next unless File.directory?(root)

        transcripts = File.join(root, "agent-transcripts")
        next unless Dir.exist?(transcripts)

        cwd = decode_slug(slug)
        Dir.children(transcripts).each do |sid|
          next unless sid.match?(UUID_RE)

          path = File.join(transcripts, sid, "#{sid}.jsonl")
          path = File.join(transcripts, sid) if !File.file?(path) && File.file?(File.join(transcripts, sid))
          next unless File.file?(path)

          title, first = skim_opening(path)
          title = "Cursor #{sid[0, 8]}" if title.to_s.empty?
          mtime = File.mtime(path).utc
          recent = live && (Time.now.utc - mtime) < 600
          sessions << Session.new(
            id: sid,
            cwd: cwd,
            title: title,
            summary_text: "",
            status: recent ? :active : :idle,
            pid: nil,
            models: [],
            current_model_id: nil,
            created_at: mtime,
            last_active_at: mtime,
            opened_at: nil,
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
            disk_bytes: File.size(path),
            agent_name: nil,
            session_kind: nil,
            parent_id: nil,
            children: [],
            first_user_prompt: first,
            git_root: nil,
            git_branch: nil,
            git_commit: nil,
            activity_points: [],
            detail_loaded: false,
            running_tasks: [],
            source: :cursor,
            bot_section: nil,
            mcp_names: []
          )
        end
      end
      sessions
    rescue StandardError => e
      warnings << "Cursor scan: #{e.class}: #{e.message}"
      []
    end

    def self.decode_slug(slug)
      new.send(:decode_slug, slug)
    end

    private

    def decode_slug(slug)
      tokens = slug.to_s.split("-")
      return slug if tokens.empty?

      acc = tokens.first == "Users" ? "/Users" : "/#{tokens.first}"
      tokens = tokens.drop(1)
      until tokens.empty?
        found = nil
        tokens.size.downto(1) do |n|
          cand = File.join(acc, tokens[0, n].join("-"))
          if File.exist?(cand)
            found = [cand, n]
            break
          end
        end
        if found
          acc, n = found
          tokens.shift(n)
        else
          acc = File.join(acc, tokens.join("-"))
          break
        end
      end
      acc
    end

    def skim_opening(path)
      return [nil, nil] unless File.file?(path)
      return [nil, nil] if File.size(path) > 2_000_000

      File.foreach(path) do |line|
        begin
          obj = JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        next unless obj.is_a?(Hash)
        next unless obj["role"].to_s == "user"

        text = flatten_content(obj["message"] || obj["content"])
        text = unwrap(text)
        next if text.nil? || text.empty?

        clipped = clip(text, 500)
        title = clip(text, 80)
        return [title, clipped]
      end
      [nil, nil]
    rescue StandardError
      [nil, nil]
    end

    def flatten_content(content)
      case content
      when String then content
      when Array
        content.map { |part|
          if part.is_a?(Hash)
            part["text"] || part["content"] || ""
          else
            part.to_s
          end
        }.join("\n")
      when Hash
        flatten_content(content["content"] || content["text"])
      else
        content.to_s
      end
    end

    def unwrap(text)
      s = text.to_s
      if s =~ %r{<user_query>\s*([\s\S]*?)\s*</user_query>}i
        s = Regexp.last_match(1)
      end
      s.gsub(/\s+/, " ").strip
    end

    def clip(text, max)
      t = text.to_s.gsub(/\s+/, " ").strip
      return t if t.length <= max

      "#{t[0, max - 1]}…"
    end

    def cursor_app_alive?
      `ps -ax -o command= 2>/dev/null`.to_s.match?(%r{(?:^|[/\s])Cursor(?:\s|$)}i)
    rescue StandardError
      false
    end
  end
end
