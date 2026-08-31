# frozen_string_literal: true

require_relative "test_helper"
require "digest"

class StoreTest < Minitest::Test
  def setup
    @home = File.join(ROOT, "tmp", "fixture-home")
    @ids = FixtureHelper.build_fixture_home(@home)
    @store = GrokLens::Store.new(grok_home: @home)
    FixtureHelper.stub_registry_pid(@store, Process.pid, @ids[:parent_id])
  end

  def test_scan_finds_sessions_and_nests_subagents
    snap = @store.scan
    refute snap.missing_home
    assert_equal 1, snap.projects.size
    # primary: parent + idle; child nested under parent
    assert_equal 2, snap.primary_sessions.size
    parent = snap.session(@ids[:parent_id])
    assert parent
    assert_equal :active, parent.status
    assert_equal 1, parent.children.size
    assert_equal @ids[:child_id], parent.children.first.id
    child = snap.session(@ids[:child_id])
    refute child.primary?
    assert_equal @ids[:parent_id], child.parent_id
  end

  def test_stale_pid
    snap = @store.scan
    idle = snap.session(@ids[:idle_id])
    assert_equal :stale, idle.status
  end

  def test_token_estimate_positive
    snap = @store.scan
    parent = snap.session(@ids[:parent_id])
    assert parent.est_tokens.positive?
  end

  def test_enrich_loads_tools_and_prompt
    snap = @store.scan
    parent = @store.enrich_session(snap.session(@ids[:parent_id]))
    assert parent.detail_loaded
    assert parent.tool_counts["read_file"].positive?
    assert_match(/refactor/i, parent.first_user_prompt.to_s)
    refute_match(/user_query/i, parent.first_user_prompt.to_s)
    assert parent.activity_points.any?
  end

  def test_scrub_prompt_wrappers
    raw = "<user_query>\nfix the theme toggle\n</user_query>"
    cleaned = @store.send(:scrub_prompt_wrappers, raw)
    assert_equal "fix the theme toggle", cleaned

    nested = "<user_info>meta</user_info>\n<user_query>hello world</user_query>"
    assert_equal "hello world", @store.send(:scrub_prompt_wrappers, nested)
  end

  def test_running_tasks_detects_live_bg_via_port
    store = GrokLens::Store.new(grok_home: @home)
    FixtureHelper.stub_registry_pid(store, Process.pid, @ids[:parent_id])
    store.define_singleton_method(:port_listening?) { |port| port.to_i == 19_876 }
    store.define_singleton_method(:process_command_index) { ["python3 -m http.server 19876"] }
    snap = store.scan
    parent = snap.session(@ids[:parent_id])
    assert parent.running_count.positive?, "expected live bg task"
    titles = parent.running_tasks.map(&:title).join(" ")
    assert_match(/demo static server|http.server|19876/i, titles)
    # completed bg must not appear
    refute parent.running_tasks.any? { |t| t.id == "call-dead-1" }
  end


  def test_process_discovery_marks_live_resume
    store = GrokLens::Store.new(grok_home: @home)
    FixtureHelper.stub_registry_pid(store, Process.pid, @ids[:parent_id])
    live_pid = Process.pid
    sid = @ids[:idle_id]
    store.define_singleton_method(:process_table) do
      "  #{live_pid} grok --resume #{sid}\n"
    end
    snap = store.scan
    sess = snap.session(sid)
    assert_equal :active, sess.status
    assert_equal live_pid, sess.pid
  end

  def test_shared_registry_pid_keeps_only_cmdline_owner
    File.write(File.join(@home, "active_sessions.json"), JSON.pretty_generate([
      { session_id: @ids[:parent_id], pid: Process.pid, cwd: @ids[:proj], opened_at: "2026-07-14T12:00:00Z" },
      { session_id: @ids[:idle_id], pid: Process.pid, cwd: @ids[:proj], opened_at: "2026-07-14T11:00:00Z" }
    ]))
    store = GrokLens::Store.new(grok_home: @home)
    FixtureHelper.stub_registry_pid(store, Process.pid, @ids[:parent_id])
    store.define_singleton_method(:process_table) { "" }
    snap = store.scan
    assert_equal :active, snap.session(@ids[:parent_id]).status
    refute_equal :active, snap.session(@ids[:idle_id]).status
  end

  def test_subagent_meta_running_counts_without_child_pid
    parent_dir = File.join(@home, "sessions", "%2Ftmp%2Fdemo-project", @ids[:parent_id])
    meta_dir = File.join(parent_dir, "subagents", @ids[:child_id])
    FileUtils.mkdir_p(meta_dir)
    File.write(File.join(meta_dir, "meta.json"), JSON.pretty_generate(
      "subagent_id" => @ids[:child_id],
      "parent_session_id" => @ids[:parent_id],
      "description" => "in-process helper",
      "status" => "running",
      "effective_model_id" => "grok-build"
    ))
    snap = @store.scan
    parent = snap.session(@ids[:parent_id])
    child = snap.session(@ids[:child_id])
    assert child.active?, "meta.json running should mark the child live"
    assert parent.running_tasks.any? { |t| t.id == @ids[:child_id] && t.kind == :subagent && t.live }
    assert parent.live_children_count.positive?
  end

  def test_opening_message_reads_prefix_of_large_chat
    path = File.join(@home, "huge-chat.jsonl")
    File.write(path, [
      { type: "system", content: "sys" }.to_json,
      { type: "user", content: "<user_query>hello from the front</user_query>" }.to_json,
      { type: "assistant", content: "ok" }.to_json,
      ("x" * 3_000_000)
    ].join("\n"))
    text = @store.send(:extract_first_user_prompt, path)
    assert_equal "hello from the front", text
  end

  def test_project_id_distinguishes_slash_and_hyphen_paths
    a = @store.send(:project_id, "/foo/bar")
    b = @store.send(:project_id, "/foo-bar")
    refute_equal a, b
    assert_match(/-#{Regexp.escape(Digest::SHA256.hexdigest("/foo/bar")[0, 8])}\z/, a)
  end

  def test_dir_size_skips_updates_jsonl
    dir = File.join(@home, "sessions", "%2Ftmp%2Fdemo-project", @ids[:parent_id])
    updates = File.join(dir, "updates.jsonl")
    update_bytes = File.size(updates)
    assert update_bytes.positive?
    sized = @store.send(:dir_size, dir)
    raw = Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH)
             .select { |f| File.file?(f) }
             .sum { |f| File.size(f) }
    assert sized <= raw - update_bytes
  end

  def test_estimate_format
    assert_equal "~1.5M", GrokLens::Estimate.format_tokens(1_500_000)
    assert_equal "~12k", GrokLens::Estimate.format_tokens(12_000)
  end

  def test_hybrid_token_estimate_uses_signals
    dir = File.join(@home, "sessions", "%2Ftmp%2Fdemo-project", @ids[:parent_id])
    File.write(File.join(dir, "signals.json"), JSON.pretty_generate(
      "contextTokensUsed" => 50_000,
      "contextWindowTokens" => 500_000,
      "turnCount" => 10,
      "toolCallCount" => 20
    ))
    est = GrokLens::Estimate.for_session(
      session_dir: dir,
      chat_history_bytes: 1000,
      events_bytes: 1000,
      num_messages: 40
    )
    assert_equal "hybrid", est[:est_source]
    assert_equal 50_000, est[:context_tokens]
    assert est[:est_tokens] >= 50_000
    refute est[:billed]
  end

  def test_usage_json_preferred_when_ledger_covers_session
    dir = File.join(@home, "sessions", "%2Ftmp%2Fdemo-project", @ids[:parent_id])
    FixtureHelper.write_usage(
      dir, @ids[:parent_id],
      turns: 3, input: 10_000, output: 400, cached: 2_000,
      reasoning: 50, calls: 4, cost_ticks: 4_608_349_120
    )
    est = GrokLens::Estimate.for_session(
      session_dir: dir,
      chat_history_bytes: 1000,
      events_bytes: 1000,
      num_messages: 40,
      num_turns: 3
    )
    assert_equal "usage", est[:est_source]
    assert est[:billed]
    assert_equal 10_400, est[:est_tokens]
    assert_in_delta 0.460834912, est[:cost_usd], 1e-9
    refute est[:usage][:incomplete]
    assert_equal 10_000, est[:usage][:input_tokens]
    assert_equal 400, est[:usage][:output_tokens]
    assert_equal 2_000, est[:usage][:cached_read_tokens]
    assert_equal 50, est[:usage][:reasoning_tokens]
    assert_equal 4, est[:usage][:model_calls]
    assert_equal 3, est[:usage][:recorded_turns]
  end

  def test_partial_usage_json_keeps_lifetime_estimate
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
    est = GrokLens::Estimate.for_session(
      session_dir: dir,
      chat_history_bytes: 1000,
      events_bytes: 1000,
      num_messages: 40,
      num_turns: 28
    )
    refute est[:billed]
    assert_equal "hybrid", est[:est_source]
    assert est[:est_tokens] >= 50_000
    assert est[:usage][:incomplete]
    assert_equal 1, est[:usage][:recorded_turns]
    assert_in_delta 0.460834912, est[:usage][:cost_usd], 1e-9
    assert_nil est[:cost_usd]
  end

  def test_scan_marks_complete_usage_as_billed
    dir = File.join(@home, "sessions", "%2Ftmp%2Fdemo-project", @ids[:parent_id])
    FixtureHelper.write_usage(dir, @ids[:parent_id], turns: 3, input: 8_000, output: 200, cost_ticks: 10_000_000_000)
    snap = @store.scan
    parent = snap.session(@ids[:parent_id])
    assert parent.billed?
    assert_equal 8_200, parent.est_tokens
    assert_in_delta 1.0, parent.cost_usd, 1e-9
    assert_equal "usage", parent.est_source
    assert snap.billed_count >= 1
    assert_in_delta 1.0, snap.total_cost_usd, 1e-9
    assert_equal "8k", parent.tokens_label
  end

  def test_format_tokens_exact_vs_approx
    assert_equal "~1.5M", GrokLens::Estimate.format_tokens(1_500_000)
    assert_equal "1.5M", GrokLens::Estimate.format_tokens(1_500_000, approx: false)
    assert_equal "~12k", GrokLens::Estimate.format_tokens(12_000)
    assert_equal "12k", GrokLens::Estimate.format_tokens(12_000, approx: false)
    assert_equal "~433", GrokLens::Estimate.format_tokens(433)
    assert_equal "433", GrokLens::Estimate.format_tokens(433, approx: false)
  end

  def test_cost_from_ticks
    assert_in_delta 1.0, GrokLens::Estimate.cost_from_ticks(10_000_000_000), 1e-12
    assert_in_delta 0.460834912, GrokLens::Estimate.cost_from_ticks(4_608_349_120), 1e-9
    assert_nil GrokLens::Estimate.cost_from_ticks(nil)
  end

  def test_cost_helper
    assert_in_delta 0.005, GrokLens::Estimate.cost_usd(1000, 5.0), 0.0001
    assert_equal "$0.0050", GrokLens::Estimate.format_cost(0.005)
  end


  def test_missing_home
    store = GrokLens::Store.new(grok_home: File.join(ROOT, "tmp", "nope-missing"))
    snap = store.scan
    assert snap.missing_home
  end
end
