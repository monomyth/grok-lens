# frozen_string_literal: true

require_relative "test_helper"

class McpTest < Minitest::Test
  def setup
    @home = File.join(ROOT, "tmp", "fixture-mcp")
    FileUtils.rm_rf(@home)
    FileUtils.mkdir_p(@home)
  end

  def test_parses_user_config_and_skips_env_tables
    File.write(File.join(@home, "config.toml"), <<~TOML)
      disabled_mcp_servers = ["xapi"]

      [mcp_servers.blender]
      command = "/opt/venv/bin/python"
      args = ["/opt/blender_mcp_server.py"]
      enabled = true

      [mcp_servers.xapi]
      command = "npx"
      args = ["-y", "@xdevplatform/xurl", "mcp"]
      enabled = false

      [mcp_servers.xapi.env]
      CLIENT_SECRET = "should-not-appear"
      CLIENT_ID = "abc"

      [mcp_servers.x-docs]
      url = "https://docs.x.com/mcp"
      enabled = true
    TOML

    rows = GrokLens::Mcp.parse_config(File.join(@home, "config.toml"))
    names = rows.map { |r| r[:name] }
    assert_includes names, "blender"
    assert_includes names, "x-docs"
    assert_includes names, "xapi"
    refute(rows.any? { |r| r[:name].include?("env") })
    xapi = rows.find { |r| r[:name] == "xapi" }
    refute xapi[:enabled]
    refute_match(/should-not-appear/, xapi[:target].to_s)
    docs = rows.find { |r| r[:name] == "x-docs" }
    assert_equal "http", docs[:transport]
    assert_equal "https://docs.x.com/mcp", docs[:target]
  end

  def test_plugin_mcp_json_and_status
    FileUtils.mkdir_p(File.join(@home, "installed-plugins", "chrome-devtools-mcp-abcd1234"))
    File.write(File.join(@home, "installed-plugins", "chrome-devtools-mcp-abcd1234", ".mcp.json"), <<~JSON)
      {"mcpServers":{"chrome-devtools":{"command":"npx","args":["chrome-devtools-mcp@latest"]}}}
    JSON
    File.write(File.join(@home, "config.toml"), <<~TOML)
      disabled_mcp_servers = ["xapi"]
      [mcp_servers.sentry]
      url = "https://mcp.sentry.dev/mcp"
      enabled = true
    TOML

    encoded = "/tmp/mcp-demo".gsub("/", "%2F")
    live_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    idle_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    live_dir = File.join(@home, "sessions", encoded, live_id)
    idle_dir = File.join(@home, "sessions", encoded, idle_id)
    FileUtils.mkdir_p([live_dir, idle_dir])

    File.write(File.join(live_dir, "events.jsonl"), [
      { ts: "2026-08-31T20:00:00Z", type: "mcp_config_resolved", servers: [
        { name: "chrome-devtools", transport: "stdio", source: "local" },
        { name: "sentry", transport: "http", source: "local" },
        { name: "xapi", transport: "stdio", source: "local" }
      ] }.to_json,
      { ts: "2026-08-31T20:00:01Z", type: "mcp_server_connected", server_name: "chrome-devtools", transport: "stdio", tool_count: 29, tools: %w[click new_page] }.to_json,
      { ts: "2026-08-31T20:00:02Z", type: "mcp_server_failed", server_name: "sentry", transport: "http", error_type: "auth_required", error_message: "Auth required" }.to_json,
      { ts: "2026-08-31T20:00:03Z", type: "mcp_tool_call_started", server_name: "chrome-devtools", tool_name: "take_snapshot" }.to_json
    ].join("\n") + "\n")

    File.write(File.join(idle_dir, "events.jsonl"), [
      { ts: "2026-08-01T20:00:00Z", type: "mcp_server_connected", server_name: "chrome-devtools", tool_count: 10 }.to_json
    ].join("\n") + "\n")

    inv = GrokLens::Mcp.inventory(
      grok_home: @home,
      sessions: [
        { id: live_id, dir: live_dir, live: true, title: "Live Agent", cwd: "/tmp/mcp-demo" },
        { id: idle_id, dir: idle_dir, live: false, title: "Old Session", cwd: "/tmp/mcp-demo" }
      ],
      ps_index: ["npx chrome-devtools-mcp@latest"]
    )
    by = inv.to_h { |s| [s.name, s] }

    chrome = by["chrome-devtools"]
    assert chrome
    assert_equal :active, chrome.status
    assert_equal "plugin", chrome.source
    assert chrome.live_session_ids.include?(live_id)
    assert chrome.session_ids.include?(idle_id)

    sentry = by["sentry"]
    assert_equal :failed, sentry.status
    assert_match(/auth/i, sentry.error.to_s)
    assert_empty sentry.live_session_ids, "a failed connect is not a running client"

    xapi = by["xapi"]
    assert_equal :suspended, xapi.status
    refute xapi.enabled
  end

  def test_idle_when_connected_without_inflight_call
    File.write(File.join(@home, "config.toml"), <<~TOML)
      [mcp_servers.blender]
      command = "/opt/venv/bin/python"
      args = ["/opt/blender_mcp_server.py"]
    TOML
    encoded = "/tmp/mcp-demo".gsub("/", "%2F")
    sid = "cccccccc-cccc-cccc-cccc-cccccccccccc"
    dir = File.join(@home, "sessions", encoded, sid)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "events.jsonl"), [
      { type: "mcp_server_connected", server_name: "blender", tool_count: 3, tools: %w[list_objects] }.to_json,
      { type: "mcp_tool_call_started", server_name: "blender", tool_name: "list_objects" }.to_json,
      { type: "mcp_tool_call_completed", server_name: "blender", tool_name: "list_objects", success: true }.to_json
    ].join("\n") + "\n")

    inv = GrokLens::Mcp.inventory(
      grok_home: @home,
      sessions: [{ id: sid, dir: dir, live: true, title: "Blender session", cwd: "/tmp/mcp-demo" }],
      ps_index: ["/opt/venv/bin/python /opt/blender_mcp_server.py"]
    )
    blender = inv.find { |s| s.name == "blender" }
    assert_equal :idle, blender.status
    assert_equal 1, blender.call_count
    assert_equal 3, blender.tool_count
    assert_equal [sid], blender.live_session_ids
  end

  def test_config_resolved_alone_is_not_a_running_client
    File.write(File.join(@home, "config.toml"), <<~TOML)
      [mcp_servers.x-docs]
      url = "https://docs.x.com/mcp"
    TOML
    encoded = "/tmp/mcp-demo".gsub("/", "%2F")
    sid = "dddddddd-dddd-dddd-dddd-dddddddddddd"
    dir = File.join(@home, "sessions", encoded, sid)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "events.jsonl"), [
      { type: "mcp_config_resolved", servers: [{ name: "x-docs", transport: "http", source: "local" }] }.to_json
    ].join("\n") + "\n")

    inv = GrokLens::Mcp.inventory(
      grok_home: @home,
      sessions: [{ id: sid, dir: dir, live: true, title: "Just started", cwd: "/tmp/mcp-demo" }],
      ps_index: []
    )
    docs = inv.find { |s| s.name == "x-docs" }
    assert docs
    assert_empty docs.live_session_ids
    assert_includes docs.session_ids, sid
  end
end
