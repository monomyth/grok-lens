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
    # Local dashboard only; include rack-test default host (example.org)
    set :host_authorization, {
      permitted_hosts: [
        ".localhost", "localhost", "127.0.0.1", "0.0.0.0", "example.org"
      ]
    }

    configure do
      set :store, Store.new(grok_home: GrokLens::Config.grok_home)
      set :catalog, Catalog.new(grok_home: GrokLens::Config.grok_home)
      set :snapshot, nil
      set :snapshot_mutex, Mutex.new
      set :last_scan_ms, nil
    end

    helpers Presenters

    helpers do
      def snapshot
        settings.snapshot_mutex.synchronize do
          settings.snapshot ||= timed_scan
        end
      end

      def refresh_snapshot!
        settings.snapshot_mutex.synchronize do
          settings.snapshot = timed_scan
        end
      end

      def timed_scan
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        snap = settings.store.scan
        t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        settings.last_scan_ms = ((t1 - t0) * 1000).round(1)
        snap
      end

      def est(n)
        Estimate.format_tokens(n)
      end

      def bytes(n)
        Estimate.format_bytes(n)
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
    end

    get "/" do
      @snap = snapshot
      erb :home
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

    get "/projects/*" do
      @snap = snapshot
      path = "/#{params["splat"].first}"
      @project = @snap.projects.find { |p| p.path == path || p.id == params["splat"].first || p.path.end_with?(path) }
      @project ||= @snap.projects.find { |p| p.id == params["splat"].first.tr("/", "-") }
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

    # Soft live poll endpoint: re-scan and return compact JSON for the home view.
    get "/api/snapshot" do
      content_type :json
      force = params["refresh"].to_s == "1" || params["refresh"].to_s == "true"
      snap = force ? refresh_snapshot! : snapshot
      {
        ok: true,
        scanned_at: snap.scanned_at.utc.iso8601,
        scan_ms: settings.last_scan_ms,
        missing_home: snap.missing_home,
        primary_sessions: snap.primary_sessions.size,
        total_sessions: snap.sessions_by_id.size,
        projects: snap.projects.size,
        total_est_tokens: snap.total_est_tokens,
        total_est_tokens_label: Estimate.format_tokens(snap.total_est_tokens),
        active: snap.active_sessions.count(&:active?),
        stale: snap.active_sessions.count(&:stale?),
        warnings: snap.warnings.size,
        models_hist: snap.models_hist,
        active_sessions: snap.active_sessions.map { |s| session_json(s) },
        recent_sessions: snap.primary_sessions.first(40).map { |s| session_json(s) },
        projects_list: snap.projects.map { |p|
          {
            id: p.id,
            name: p.name,
            path: p.path,
            description: p.description,
            session_count: p.session_count,
            est_tokens: p.est_tokens,
            est_tokens_label: Estimate.format_tokens(p.est_tokens),
            last_active_at: p.last_active_at&.utc&.iso8601
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
        last_scan_ms: settings.last_scan_ms
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
          est_tokens_label: Estimate.format_tokens(s.est_tokens),
          last_active_at: s.last_active_at&.utc&.iso8601,
          children: s.children.size,
          resume_command: resume_command(s),
          continue_command: continue_command(s)
        }
      end
    end
  end
end
