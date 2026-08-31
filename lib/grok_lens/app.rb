# frozen_string_literal: true

require "sinatra/base"
require "json"
require "time"

module GrokLens
  class App < Sinatra::Base
    set :root, File.expand_path("../..", __dir__)
    set :views, File.join(settings.root, "views")
    set :public_folder, File.join(settings.root, "public")
    set :show_exceptions, development?
    set :host_authorization, {
      permitted_hosts: [
        ".localhost", "localhost", "127.0.0.1", "0.0.0.0", "example.org"
      ]
    }

    configure do
      set :store, Store.new(grok_home: GrokLens::Config.grok_home)
      set :catalog, Catalog.new(grok_home: GrokLens::Config.grok_home)
      set :search, Search.new(grok_home: GrokLens::Config.grok_home)
      set :snapshot, nil
      set :snapshot_mutex, Mutex.new
      set :last_scan_ms, nil
      set :bot_agents, nil
    end

    helpers Presenters

    helpers do
      def snapshot
        cached = settings.snapshot_mutex.synchronize { settings.snapshot }
        return cached if cached

        refresh_snapshot!
      end

      def refresh_snapshot!
        # Scan off the mutex so requests can still serve the previous snapshot.
        settings.store.instance_variable_set(:@process_command_index, nil)
        snap = timed_scan
        agents = load_bot_agents
        settings.snapshot_mutex.synchronize do
          settings.snapshot = snap
          settings.bot_agents = agents
        end
        snap
      end

      def bot_agents
        cached = settings.snapshot_mutex.synchronize { settings.bot_agents }
        return cached if cached

        refresh_snapshot!
        settings.snapshot_mutex.synchronize { settings.bot_agents } || []
      end

      def load_bot_agents
        warnings = []
        Bot.new.scan(warnings)
      end

      def timed_scan
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        snap = settings.store.scan
        t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        settings.last_scan_ms = ((t1 - t0) * 1000).round(1)
        snap
      end

      def est(n, approx: true)
        Estimate.format_tokens(n, approx: approx)
      end

      def tok(s)
        Estimate.format_tokens(s.est_tokens, approx: !s.billed?)
      end

      def bytes(n)
        Estimate.format_bytes(n)
      end

      def ctx_label(s)
        Estimate.format_context(s.context_tokens, s.context_window)
      end

      def cost_label(tokens)
        rate = GrokLens::Config.usd_per_m_tokens
        usd_label(Estimate.cost_usd(tokens, rate))
      end

      def usd_label(usd)
        Estimate.format_cost(usd)
      end

      def cost_enabled?
        !GrokLens::Config.usd_per_m_tokens.nil?
      end

      def session_cost_usd(s)
        return s.cost_usd if s.billed? && !s.cost_usd.nil?
        return s.usage[:cost_usd] if s.recorded_usage? && s.usage[:cost_usd]
        return Estimate.cost_usd(s.est_tokens, GrokLens::Config.usd_per_m_tokens) if cost_enabled?

        nil
      end

      def session_cost_kind(s)
        return "billed" if s.billed? && s.cost_usd
        return "recorded" if s.recorded_usage? && s.usage[:cost_usd]
        return "est" if cost_enabled?

        nil
      end

      def token_source_label(s)
        return "usage.json" if s.billed?
        return "#{s.est_source || "size"} · partial usage.json" if s.recorded_usage? && s.usage[:incomplete]

        s.est_source || "size"
      end

      def total_tokens_label(snap)
        unbilled = snap.sessions_by_id.values.count { |s| s.grok? && !s.billed? && s.est_tokens.to_i.positive? }
        Estimate.format_tokens(snap.total_est_tokens, approx: unbilled.positive? || snap.billed_count.to_i.zero?)
      end

      def project_tokens_label(project)
        all_billed = project.billed_tokens.to_i.positive? && project.billed_tokens == project.est_tokens
        Estimate.format_tokens(project.est_tokens, approx: !all_billed)
      end

      def snapshot_cost_label(snap)
        return usd_label(snap.total_cost_usd) if snap.total_cost_usd.to_f.positive?

        cost_label(snap.total_est_tokens) if cost_enabled?
      end

      def usage_command(session)
        return nil unless session.respond_to?(:source_key) && session.source_key == :grok

        "grok usage #{session.id}"
      end

      def poll_seconds_default
        GrokLens::Config.poll_seconds
      end

      def poll_presets
        GrokLens::Config.poll_presets
      end

      def grok_home_path
        GrokLens::Config.grok_home
      end

      def nav_active(path)
        request.path_info == path ? "active" : nil
      end

      def sort_sessions(list, key)
        case key
        when "running"
          list.sort_by { |s| [-s.running_count, -(s.last_active_at&.to_i || 0)] }
        when "tokens"
          list.sort_by { |s| -(s.est_tokens || 0) }
        when "title"
          list.sort_by { |s| s.title.to_s.downcase }
        else # last_active
          list.sort_by { |s| -(s.last_active_at&.to_i || 0) }
        end
      end
    end

    get "/" do
      @snap = snapshot
      @sort = params["sort"].to_s
      @sort = "last_active" if @sort.empty?
      @filter_running = params["running"].to_s == "1"
      @src = params["src"].to_s
      list = @snap.primary_sessions
      list = list.select { |s| s.source_key.to_s == @src } unless @src.empty?
      list = list.select(&:running_now?) if @filter_running
      @sorted_sessions = sort_sessions(list, @sort)
      @source_counts = @snap.primary_sessions.each_with_object(Hash.new(0)) { |s, h| h[s.source_key] += 1 }
      @bot_agents = bot_agents
      erb :home
    end

    get "/bot" do
      @snap = snapshot
      @bot_agents = bot_agents
      halt 404, erb(:not_found) if @bot_agents.empty?
      @bot_groups = Bot.new.grouped(@bot_agents)
      erb :bot
    end

    get "/bot/:id" do
      @snap = snapshot
      @bot_agents = bot_agents
      @agent = @bot_agents.find { |a| a.id == params[:id] }
      halt 404, erb(:not_found) unless @agent
      erb :bot_agent
    end

    get "/search" do
      @snap = snapshot
      @q = params["q"].to_s
      @search_available = settings.search.available?
      @results = @q.empty? ? [] : settings.search.query(@q)
      erb :search
    end

    get "/compare" do
      @snap = snapshot
      a_id = params["a"].to_s
      b_id = params["b"].to_s
      @session_a = a_id.empty? ? nil : @snap.session(a_id)
      @session_b = b_id.empty? ? nil : @snap.session(b_id)
      @session_a = settings.store.enrich_session(@session_a) if @session_a
      @session_b = settings.store.enrich_session(@session_b) if @session_b
      @pick_list = @snap.primary_sessions.first(80)
      erb :compare
    end

    get "/glossary" do
      @snap = snapshot
      inv = settings.catalog.inventory
      @commands = inv[:slash_commands]
      @counts = inv[:counts]
      @doc_path = File.join(GrokLens::Config.grok_home, "docs", "user-guide", "04-slash-commands.md")
      erb :glossary
    end

    get "/extensions" do
      @snap = snapshot
      inv = settings.catalog.inventory
      @skills = inv[:skills]
      @plugins = inv[:plugins]
      @counts = inv[:counts]
      erb :extensions
    end

    get "/mcp" do
      @snap = snapshot
      @mcp_servers = Array(@snap.mcp_servers)
      erb :mcp
    end

    get "/projects/*" do
      @snap = snapshot
      raw = params["splat"].first.to_s
      path = raw.start_with?("/") ? raw : "/#{raw}"
      matches = @snap.projects.select { |p| p.id == raw || p.path == raw || p.path == path }
      @project = matches.size == 1 ? matches.first : nil
      halt 404, erb(:not_found) unless @project
      erb :project
    end

    get "/sessions/:id" do
      @snap = snapshot
      session = @snap.session(params[:id])
      halt 404, erb(:not_found) unless session
      @session = settings.store.enrich_session(session)
      erb :session
    end

    post "/refresh" do
      refresh_snapshot!
      redirect back
    end

    get "/api/snapshot" do
      content_type :json
      force = params["refresh"].to_s == "1" || params["refresh"].to_s == "true"
      snap = force ? refresh_snapshot! : snapshot
      rate = GrokLens::Config.usd_per_m_tokens
      {
        ok: true,
        scanned_at: snap.scanned_at.utc.iso8601,
        scan_ms: settings.last_scan_ms,
        missing_home: snap.missing_home,
        primary_sessions: snap.primary_sessions.size,
        total_sessions: snap.sessions_by_id.size,
        projects: snap.projects.size,
        total_est_tokens: snap.total_est_tokens,
        total_est_tokens_label: total_tokens_label(snap),
        total_billed_tokens: snap.total_billed_tokens,
        billed_count: snap.billed_count,
        total_cost_usd: snap.total_cost_usd,
        total_cost_label: snapshot_cost_label(snap),
        cost_enabled: !rate.nil? || snap.total_cost_usd.to_f.positive?,
        active: snap.active_sessions.count(&:active?),
        stale: snap.active_sessions.count(&:stale?),
        total_running: snap.primary_sessions.sum(&:running_count),
        warnings: snap.warnings.size,
        models_hist: snap.models_hist,
        mcp: mcp_summary_json(snap),
        active_sessions: snap.active_sessions.map { |s| session_json(s) },
        recent_sessions: snap.primary_sessions.map { |s| session_json(s) },
        bot: bot_summary_json(force ? settings.bot_agents : bot_agents),
        projects_list: snap.projects.map { |p|
          {
            id: p.id,
            name: p.name,
            path: p.path,
            description: p.description,
            session_count: p.session_count,
            est_tokens: p.est_tokens,
            est_tokens_label: project_tokens_label(p),
            billed_tokens: p.billed_tokens,
            cost_usd: p.cost_usd,
            last_active_at: p.last_active_at&.utc&.iso8601
          }
        }
      }.to_json
    end

    get "/api/search" do
      content_type :json
      q = params["q"].to_s
      {
        ok: true,
        available: settings.search.available?,
        q: q,
        results: settings.search.query(q).map { |r|
          {
            session_id: r.session_id,
            cwd: r.cwd,
            title: r.title,
            snippet: r.snippet,
            rank: r.rank
          }
        }
      }.to_json
    end

    get "/health" do
      content_type :json
      {
        ok: true,
        version: GrokLens::VERSION,
        ruby: RUBY_VERSION,
        poll_seconds_default: GrokLens::Config.poll_seconds,
        last_scan_ms: settings.last_scan_ms,
        cost_enabled: !GrokLens::Config.usd_per_m_tokens.nil?
      }.to_json
    end

    not_found do
      erb :not_found
    end

    helpers do
      def session_json(s)
        {
          id: s.id,
          title: s.title,
          cwd: s.cwd,
          project: File.basename(s.cwd.to_s),
          status: s.status.to_s,
          pid: s.pid,
          model: s.current_model_id,
          num_turns: s.num_turns,
          num_messages: s.num_messages,
          est_tokens: s.est_tokens,
          est_tokens_label: s.tokens_label,
          billed: s.billed?,
          cost_usd: s.cost_usd,
          usage_incomplete: s.recorded_usage? && s.usage[:incomplete],
          context_tokens: s.context_tokens,
          context_label: Estimate.format_context(s.context_tokens, s.context_window),
          est_source: s.est_source,
          last_active_at: s.last_active_at&.utc&.iso8601,
          last_active_rel: relative_time(s.last_active_at),
          children: s.children.size,
          live_children: s.live_children_count,
          source: s.source_key.to_s,
          source_label: s.source_label,
          bot_section: s.bot_section,
          running_count: s.running_count,
          running_now: s.running_now?,
          running_tasks: Array(s.running_tasks).select(&:live).map { |t|
            { id: t.id, kind: t.kind.to_s, title: t.title, status: t.status, tool_name: t.tool_name }
          },
          resume_command: resume_command(s),
          continue_command: continue_command(s),
          mcp_names: Array(s.mcp_names)
        }
      end

      def mcp_summary_json(snap)
        list = Array(snap.mcp_servers)
        {
          total: list.size,
          active: list.count(&:active?),
          idle: list.count(&:idle?),
          suspended: list.count(&:suspended?),
          failed: list.count(&:failed?),
          servers: list.map { |s|
            {
              name: s.name,
              status: s.status.to_s,
              transport: s.transport,
              source: s.source,
              plugin: s.plugin,
              target: s.target,
              enabled: s.enabled,
              error: s.error,
              tool_count: s.tool_count,
              call_count: s.call_count,
              live: s.live_session_ids.size,
              sessions: s.session_ids.size
            }
          }
        }
      end

      def bot_summary_json(agents)
        list = Array(agents)
        {
          available: list.any?,
          total: list.size,
          working: list.count(&:working?),
          idle: list.count(&:idle?),
          agents: list.map { |a|
            {
              id: a.id,
              name: a.name,
              section: a.section,
              status: a.status.to_s,
              awaiting: a.awaiting,
              selected: a.selected,
              activity: a.activity,
              last_entry: a.last_entry,
              last_active_rel: relative_time(a.last_active_at)
            }
          }
        }
      end
    end
  end
end
