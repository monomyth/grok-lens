# frozen_string_literal: true

require "sinatra/base"
require "json"

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
      set :store, Store.new
      set :snapshot, nil
      set :snapshot_mutex, Mutex.new
    end

    helpers Presenters

    helpers do
      def snapshot
        settings.snapshot_mutex.synchronize do
          settings.snapshot ||= settings.store.scan
        end
      end

      def refresh_snapshot!
        settings.snapshot_mutex.synchronize do
          settings.snapshot = settings.store.scan
        end
      end

      def est(n)
        Estimate.format_tokens(n)
      end

      def bytes(n)
        Estimate.format_bytes(n)
      end
    end

    get "/" do
      @snap = snapshot
      erb :home
    end

    get "/projects/*" do
      @snap = snapshot
      path = "/#{params["splat"].first}"
      # also try without leading issues — projects keyed by id or path
      @project = @snap.projects.find { |p| p.path == path || p.id == params["splat"].first || p.path.end_with?(path) }
      # fallback: match by project id
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

    get "/health" do
      content_type :json
      { ok: true, version: GrokLens::VERSION, ruby: RUBY_VERSION }.to_json
    end

    not_found do
      erb :not_found
    end
  end
end
