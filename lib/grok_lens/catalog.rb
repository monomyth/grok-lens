# frozen_string_literal: true

require "yaml"

module GrokLens
  # Inventory of Grok slash commands, skills, and installed plugins (read-only).
  class Catalog
    Skill = Data.define(:name, :description, :source, :path, :user_invocable, :plugin)
    Plugin = Data.define(:id, :name, :path, :skill_count, :description)
    SlashCommand = Data.define(:name, :aliases, :section, :description)

    def initialize(grok_home: Config.grok_home)
      @grok_home = File.expand_path(grok_home)
    end

    attr_reader :grok_home

    def slash_commands
      path = File.join(@grok_home, "docs", "user-guide", "04-slash-commands.md")
      if File.file?(path)
        parse_slash_doc(File.read(path, encoding: "UTF-8"))
      else
        fallback_slash_commands
      end
    end

    def skills
      seen = {}
      list = []

      scan_skill_roots.each do |source, root, plugin|
        next unless Dir.exist?(root)

        Dir.glob(File.join(root, "**", "SKILL.md")).each do |path|
          meta = parse_skill(path)
          next unless meta

          key = "#{source}:#{meta[:name]}"
          next if seen[key]

          seen[key] = true
          list << Skill.new(
            name: meta[:name],
            description: meta[:description],
            source: source,
            path: path,
            user_invocable: meta[:user_invocable],
            plugin: plugin
          )
        end
      end

      list.sort_by { |s| [s.source, s.name.to_s.downcase] }
    end

    def plugins
      root = File.join(@grok_home, "installed-plugins")
      return [] unless Dir.exist?(root)

      Dir.children(root).filter_map do |entry|
        next if entry.start_with?(".") || entry == "registry.json"

        dir = File.join(root, entry)
        next unless File.directory?(dir)

        skill_n = Dir.glob(File.join(dir, "**", "SKILL.md")).size
        desc = plugin_description(dir, entry)
        name = entry.sub(/-[0-9a-f]{8}$/i, "")
        Plugin.new(
          id: entry,
          name: name,
          path: dir,
          skill_count: skill_n,
          description: desc
        )
      end.sort_by { |p| p.name.downcase }
    end

    def inventory
      sk = skills
      pl = plugins
      sc = slash_commands
      {
        scanned_at: Time.now.utc,
        grok_home: @grok_home,
        slash_commands: sc,
        skills: sk,
        plugins: pl,
        counts: {
          slash_commands: sc.size,
          skills: sk.size,
          plugins: pl.size,
          invocable_skills: sk.count(&:user_invocable)
        }
      }
    end

    private

    def scan_skill_roots
      roots = []
      roots << ["user", File.join(@grok_home, "skills"), nil]
      roots << ["bundled", File.join(@grok_home, "bundled", "skills"), nil]
      plugins_root = File.join(@grok_home, "installed-plugins")
      if Dir.exist?(plugins_root)
        Dir.children(plugins_root).each do |entry|
          dir = File.join(plugins_root, entry)
          next unless File.directory?(dir)
          next if entry.start_with?(".") || entry == "registry.json"

          roots << ["plugin", File.join(dir, "skills"), entry]
          # some plugins put skills at plugin root or commands/
          roots << ["plugin", dir, entry]
        end
      end
      roots
    end

    def parse_skill(path)
      text = File.read(path, encoding: "UTF-8")
      name = File.basename(File.dirname(path))
      description = ""
      user_invocable = true

      if text.start_with?("---")
        parts = text.split(/^---\s*$/, 3)
        if parts.size >= 3
          begin
            fm = YAML.safe_load(parts[1], permitted_classes: [Symbol]) || {}
            name = fm["name"].to_s if fm["name"]
            description = clean_desc(fm["description"] || fm["short-description"] || "")
            if fm.key?("user-invocable")
              user_invocable = !!fm["user-invocable"]
            elsif fm.key?("user_invocable")
              user_invocable = !!fm["user_invocable"]
            end
            # disable-model-invocation skills can still be slash-invocable
          rescue StandardError
            description = first_paragraph(parts[2] || text)
          end
        end
      else
        description = first_paragraph(text)
      end

      description = first_paragraph(text) if description.empty?
      description = clip(description, 220)
      return nil if name.to_s.empty?

      { name: name, description: description, user_invocable: user_invocable }
    rescue StandardError
      nil
    end

    def clean_desc(text)
      text.to_s.gsub(/\s+/, " ").strip
    end

    def first_paragraph(text)
      lines = text.to_s.lines.map(&:strip)
      lines.reject! { |l| l.empty? || l.start_with?("#") || l.start_with?("---") || l.start_with?("**") }
      lines.first.to_s
    end

    def clip(text, n)
      t = text.to_s.strip
      return t if t.length <= n

      "#{t[0, n - 1]}…"
    end

    def plugin_description(dir, entry)
      readme = File.join(dir, "README.md")
      if File.file?(readme)
        return clip(first_paragraph(File.read(readme, 2000)), 200)
      end

      # fall back to first skill description
      skill = Dir.glob(File.join(dir, "**", "SKILL.md")).first
      if skill
        meta = parse_skill(skill)
        return meta[:description] if meta
      end

      "Installed plugin (#{entry})"
    end

    def parse_slash_doc(md)
      section = "General"
      commands = []
      current = nil

      md.each_line do |line|
        if line =~ /^##\s+(.+)/
          commands << build_cmd(current) if current
          section = Regexp.last_match(1).strip
          current = nil
          next
        end

        if line =~ /^###\s+`(\/[^`]+)`(.*)/
          commands << build_cmd(current) if current
          title = Regexp.last_match(1).strip
          rest = Regexp.last_match(2).to_s
          # Extract all `/foo` tokens (covers "/a` and `/b" headings)
          names = title.scan(%r{/[a-z0-9][a-z0-9_-]*})
          names = [title.split(/\s/).first].compact if names.empty?
          aliases = rest.scan(%r{`(/[a-z0-9][a-z0-9_-]*)`}).flatten
          aliases += rest.scan(/alias(?:es)?:\s*`([^`]+)`/i).flatten.flat_map { |a| a.split(/,|\s+/).map(&:strip) }
          aliases = aliases.grep(%r{^/}).uniq
          primary = names.first
          extra = (names[1..] || []) + aliases
          current = {
            name: primary,
            aliases: extra.uniq - [primary],
            section: section,
            desc_lines: []
          }
          next
        end

        next unless current

        # stop description at next heading-level content we don't want
        if line =~ /^---\s*$/
          commands << build_cmd(current)
          current = nil
          next
        end

        stripped = line.strip
        next if stripped.empty?
        next if stripped.start_with?("```")
        next if stripped.start_with?("|")
        next if stripped.start_with?("- Bare")
        next if stripped.start_with?("- `/docs")

        # first prose paragraph only
        if current[:desc_lines].empty? || current[:desc_lines].join(" ").length < 280
          next if stripped.start_with?("#")
          next if stripped.match?(/^Arguments are/)

          current[:desc_lines] << stripped.gsub(/\[([^\]]+)\]\([^)]+\)/, '\1')
        end
      end
      commands << build_cmd(current) if current

      # de-dupe by name
      by_name = {}
      commands.each do |c|
        by_name[c.name] ||= c
      end
      by_name.values.sort_by { |c| [c.section, c.name] }
    end

    def build_cmd(h)
      desc = h[:desc_lines].join(" ")
      desc = clip(desc, 320)
      desc = "See Grok docs for details." if desc.empty?
      SlashCommand.new(
        name: h[:name],
        aliases: h[:aliases],
        section: h[:section],
        description: desc
      )
    end

    def fallback_slash_commands
      [
        ["Session Management", "/resume", "Open session picker or resume from disk"],
        ["Session Management", "/new", "Start a fresh session (alias /clear)"],
        ["Session Management", "/compact", "Compress history to reclaim context"],
        ["Session Management", "/session-info", "Session details (aliases /status, /info)"],
        ["Model and Mode", "/model", "Switch models"],
        ["Model and Mode", "/plan", "Enter plan mode"],
        ["Other", "/theme", "Switch color theme"],
        ["Other", "/help", "Documentation and troubleshooting"]
      ].map do |section, name, desc|
        SlashCommand.new(name: name, aliases: [], section: section, description: desc)
      end
    end
  end
end
