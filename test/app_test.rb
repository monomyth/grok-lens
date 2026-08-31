# frozen_string_literal: true

require_relative "test_helper"

class AppTest < Minitest::Test
  include Rack::Test::Methods

  def app
    GrokLens::App
  end

  def setup
    @home = File.join(ROOT, "tmp", "fixture-home-app")
    @ids = FixtureHelper.build_fixture_home(@home)
    store = GrokLens::Store.new(grok_home: @home)
    FixtureHelper.stub_registry_pid(store, Process.pid, @ids[:parent_id])
    GrokLens::App.set :store, store
    GrokLens::App.set :catalog, GrokLens::Catalog.new(grok_home: @home)
    GrokLens::App.set :snapshot, nil
    GrokLens::App.set :last_scan_ms, nil
    GrokLens::App.set :bot_agents, nil
  end

  def project_slug
    GrokLens::App.settings.store.scan.projects.first.id
  end

  def test_home_ok
    get "/"
    assert last_response.ok?
    assert_match(/Grok Lens/, last_response.body)
    assert_match(/Parent Session Title/, last_response.body)
    assert_match(/demo-project/, last_response.body)
  end

  def test_session_detail
    get "/sessions/#{@ids[:parent_id]}"
    assert last_response.ok?
    assert_match(/Opening message/, last_response.body)
    assert_match(/read_file/, last_response.body)
  end

  def test_project_page
    get "/projects/#{project_slug}"
    assert last_response.ok?
    assert_match(/Parent Session Title/, last_response.body)
  end

  def test_project_route_rejects_path_suffix
    get "/projects/demo-project"
    assert_equal 404, last_response.status
  end

  def test_home_always_emits_active_block
    get "/"
    assert last_response.ok?
    assert_match(/id="active-block"/, last_response.body)
    assert_match(/id="stat-header-sessions"/, last_response.body)
    assert_match(/id="stat-sessions"/, last_response.body)
    refute_match(/id="stat-header-sessions".*id="stat-header-sessions"/m, last_response.body)
  end

  def test_home_lists_all_primaries
    encoded = "/tmp/demo-project".gsub("/", "%2F")
    52.times do |i|
      sid = format("44444444-4444-4444-4444-%012d", i)
      dir = File.join(@home, "sessions", encoded, sid)
      FileUtils.mkdir_p(dir)
      FixtureHelper.write_summary(
        dir, sid, "/tmp/demo-project",
        title: "Extra Session #{i}",
        summary: "bulk",
        model: "grok-4.5",
        turns: 1,
        messages: 2
      )
      File.write(File.join(dir, "chat_history.jsonl"), "z")
    end
    GrokLens::App.set :snapshot, nil
    get "/"
    assert last_response.ok?
    assert_match(/Extra Session 51/, last_response.body)

    get "/api/snapshot?refresh=1"
    assert last_response.ok?
    body = JSON.parse(last_response.body)
    assert body["recent_sessions"].size >= 54
  end

  def test_refresh
    post "/refresh"
    assert [302, 303].include?(last_response.status)
  end

  def test_health
    get "/health"
    assert last_response.ok?
    body = JSON.parse(last_response.body)
    assert body["ok"]
    assert_equal "4", RUBY_VERSION.split(".").first
  end

  def test_missing_session
    get "/sessions/00000000-0000-0000-0000-000000000000"
    assert_equal 404, last_response.status
  end

  def test_session_has_resume_command
    get "/sessions/#{@ids[:parent_id]}"
    assert last_response.ok?
    assert_match(/grok --cwd/, last_response.body)
    assert_match(/--resume/, last_response.body)
    assert_match(/Copy resume/, last_response.body)
    refute_match(/Continue latest/i, last_response.body)
    refute_match(/user_query/i, last_response.body)
  end

  def test_theme_control_is_single_toggle
    get "/"
    assert last_response.ok?
    assert_match(/id="theme-toggle"/, last_response.body)
    refute_match(/data-theme-set="light"/, last_response.body)
  end


  def test_api_snapshot
    get "/api/snapshot?refresh=1"
    assert last_response.ok?
    body = JSON.parse(last_response.body)
    assert body["ok"]
    assert body["primary_sessions"].positive?
    assert body.key?("scan_ms")
  end

  def test_mcp_roster_page
    File.write(File.join(@home, "config.toml"), <<~TOML)
      disabled_mcp_servers = ["xapi"]
      [mcp_servers.blender]
      command = "/opt/venv/bin/python"
      args = ["/opt/blender_mcp_server.py"]
      [mcp_servers.xapi]
      command = "npx"
      enabled = false
    TOML
    dir = File.join(@home, "sessions", "%2Ftmp%2Fdemo-project", @ids[:parent_id])
    File.write(File.join(dir, "events.jsonl"), [
      { type: "mcp_server_connected", server_name: "blender", tool_count: 3, tools: ["list_objects"] }.to_json,
      { type: "mcp_tool_call_started", server_name: "blender", tool_name: "list_objects" }.to_json,
      { type: "mcp_tool_call_completed", server_name: "blender", tool_name: "list_objects", success: true }.to_json
    ].join("\n") + "\n")
    GrokLens::App.set :snapshot, nil
    get "/mcp"
    assert last_response.ok?
    assert_match(/MCP servers/, last_response.body)
    assert_match(/blender/, last_response.body)
    assert_match(/xapi/, last_response.body)
    assert_match(/suspended/, last_response.body)

    get "/"
    assert last_response.ok?
    refute_match(/id="mcp-home-block"/, last_response.body)
    assert_match(/href="\/mcp"/, last_response.body)

    get "/sessions/#{@ids[:parent_id]}"
    assert last_response.ok?
    assert_match(/MCP servers/, last_response.body)
    assert_match(/blender/, last_response.body)
  end

  def test_glossary_and_extensions_routes
    get "/glossary"
    assert last_response.ok?
    assert_match(/glossary/i, last_response.body)

    get "/extensions"
    assert last_response.ok?
    assert_match(/Plugins/i, last_response.body)
  end

  def test_search_and_compare_routes
    get "/search"
    assert last_response.ok?
    assert_match(/Search sessions/i, last_response.body)

    get "/compare"
    assert last_response.ok?
    assert_match(/Compare sessions/i, last_response.body)

    get "/compare", a: @ids[:parent_id], b: @ids[:idle_id]
    assert last_response.ok?
    assert_match(/Tokens/, last_response.body)
  end

  def test_running_only_includes_live_sessions_without_inflight_tasks
    get "/", running: "1"
    assert last_response.ok?
    table = last_response.body[/<tbody id="recent-tbody">(.*?)<\/tbody>/m, 1].to_s
    assert_match(/Parent Session Title/, table)
    refute_match(/Older Idle Session/, table)
  end

  def test_home_sort_params
    get "/", sort: "tokens", running: "1"
    assert last_response.ok?
    assert_match(/Running only/i, last_response.body)
    assert_match(/id="nav-bot"[^>]*hidden/, last_response.body)
    assert_match(/id="bot-home-block"[^>]*hidden/, last_response.body)
    refute_match(/No roster on this Mac/, last_response.body)
    refute_match(/href="\/codex"/, last_response.body)
    refute_match(/href="\/cursor"/, last_response.body)
    refute_match(/aria-label="Source"/, last_response.body)
  end

  def test_home_source_chips_only_when_discovered
    grok = @home
    codex = File.join(ROOT, "tmp", "fixture-codex-app")
    ids = FixtureHelper.build_codex_home(codex)
    ENV["GROK_LENS_CODEX"] = "1"
    ENV["GROK_LENS_CODEX_HOME"] = codex
    store = GrokLens::Store.new(grok_home: grok)
    FixtureHelper.stub_registry_pid(store, Process.pid, @ids[:parent_id])
    GrokLens::App.set :store, store
    GrokLens::App.set :snapshot, nil
    get "/"
    assert last_response.ok?
    assert_match(/aria-label="Source"/, last_response.body)
    assert_match(/Codex/, last_response.body)
    refute_match(/>Cursor</, last_response.body)
    get "/", src: "codex"
    assert last_response.ok?
    assert_match(/Build the demo API/, last_response.body)
    get "/sessions/#{ids[:id]}"
    assert last_response.ok?
    assert_match(/codex resume/, last_response.body)
  ensure
    ENV["GROK_LENS_CODEX"] = "0"
    ENV.delete("GROK_LENS_CODEX_HOME")
    GrokLens::App.set :snapshot, nil
  end

  def test_bot_undiscovered_is_404
    get "/bot"
    assert_equal 404, last_response.status
  end

  def test_bot_roster_route
    root = File.join(ROOT, "tmp", "fixture-grok-bot-app")
    ids = FixtureHelper.build_bot_fixture(root)
    ENV["GROK_LENS_GROK_BOT"] = "1"
    ENV["GROK_LENS_GROK_BOT_APP"] = root
    GrokLens::App.set :bot_agents, nil
    get "/bot"
    assert last_response.ok?, last_response.body[0, 400]
    assert_match(/Inbox Bot/, last_response.body)
    assert_match(/working/, last_response.body)
    get "/bot/#{ids[:inbox_id]}"
    assert last_response.ok?
    assert_match(/Doing now/, last_response.body)
    assert_match(/two-line reply/i, last_response.body)
  ensure
    ENV["GROK_LENS_GROK_BOT"] = "0"
    ENV.delete("GROK_LENS_GROK_BOT_APP")
    GrokLens::App.set :bot_agents, nil
  end


  def test_extensions_survives_non_utf8_plugin_readme
    plugin = File.join(@home, "installed-plugins", "weird-plugin-cafebabe")
    FileUtils.mkdir_p(plugin)
    File.binwrite(File.join(plugin, "README.md"), "# Weird\n\nCaf\xE9 and \x80 bytes in readme.\n".b)
    GrokLens::App.set :catalog, GrokLens::Catalog.new(grok_home: @home)
    get "/extensions"
    assert last_response.ok?, last_response.body[0, 400]
    assert_match(/weird-plugin/i, last_response.body)
  end

  def test_session_shows_billed_usage_json
    dir = File.join(@home, "sessions", "%2Ftmp%2Fdemo-project", @ids[:parent_id])
    FixtureHelper.write_usage(
      dir, @ids[:parent_id],
      turns: 3, input: 10_000, output: 400, cached: 2_000,
      reasoning: 50, calls: 4, cost_ticks: 4_608_349_120
    )
    GrokLens::App.set :snapshot, nil
    get "/sessions/#{@ids[:parent_id]}"
    assert last_response.ok?
    assert_match(/Recorded usage/, last_response.body)
    assert_match(/usage\.json/, last_response.body)
    assert_match(/\$0\.4608/, last_response.body)
    assert_match(/10k/, last_response.body)
    refute_match(/Est\. tokens/, last_response.body)
    assert_match(/grok usage/, last_response.body)
    assert_match(/cache read/, last_response.body)

    get "/"
    assert last_response.ok?
    assert_match(/\$0\.4608/, last_response.body)
    assert_match(/>10k</, last_response.body)

    get "/api/snapshot?refresh=1"
    body = JSON.parse(last_response.body)
    parent = body["recent_sessions"].find { |s| s["id"] == @ids[:parent_id] }
    assert parent["billed"]
    assert_equal "10k", parent["est_tokens_label"]
    assert_in_delta 0.4608, body["total_cost_usd"], 0.0001
    assert body["billed_count"] >= 1
  end

  def test_session_partial_usage_keeps_estimate_and_shows_recorded
    dir = File.join(@home, "sessions", "%2Ftmp%2Fdemo-project", @ids[:parent_id])
    File.write(File.join(dir, "signals.json"), JSON.pretty_generate(
      "contextTokensUsed" => 50_000,
      "contextWindowTokens" => 500_000,
      "turnCount" => 28,
      "toolCallCount" => 20
    ))
    FixtureHelper.write_usage(
      dir, @ids[:parent_id],
      turns: 1, input: 539_483, output: 433, cached: 237_568,
      reasoning: 178, calls: 2, cost_ticks: 4_608_349_120,
      turn_numbers: [28]
    )
    GrokLens::App.set :snapshot, nil
    get "/sessions/#{@ids[:parent_id]}"
    assert last_response.ok?
    assert_match(/Est\. tokens/, last_response.body)
    assert_match(/Recorded usage/, last_response.body)
    assert_match(/partial/i, last_response.body)
    assert_match(/\$0\.4608/, last_response.body)
  end
end


