# frozen_string_literal: true

require_relative "test_helper"

class AdaptersTest < Minitest::Test
  def teardown
    ENV["GROK_LENS_CODEX"] = "0"
    ENV["GROK_LENS_CURSOR"] = "0"
    ENV.delete("GROK_LENS_CODEX_HOME")
    ENV.delete("GROK_LENS_CURSOR_HOME")
  end

  def test_codex_scan_from_index_and_prefix
    root = File.join(ROOT, "tmp", "fixture-codex")
    ids = FixtureHelper.build_codex_home(root)
    ENV["GROK_LENS_CODEX"] = "1"
    rows = GrokLens::Codex.new(home: root).scan([])
    assert_equal 1, rows.size
    s = rows.first
    assert_equal :codex, s.source_key
    assert_equal ids[:id], s.id
    assert_equal "Build the demo API", s.title
    assert_equal "/tmp/codex-demo", s.cwd
    assert_equal "gpt-5.6-sol", s.current_model_id
    assert_equal "codex resume #{ids[:id]}", GrokLens::Presenters.resume_command(s)
  end

  def test_cursor_scan_opening_and_slug
    root = File.join(ROOT, "tmp", "fixture-cursor")
    ids = FixtureHelper.build_cursor_home(root)
    ENV["GROK_LENS_CURSOR"] = "1"
    rows = GrokLens::Cursor.new(home: root).scan([])
    assert_equal 1, rows.size
    s = rows.first
    assert_equal :cursor, s.source_key
    assert_equal ids[:id], s.id
    assert_match(/borrow checker/i, s.title)
    refute_match(/user_query/i, s.title)
    assert_equal "/tmp/cursor-demo", s.cwd
    assert_nil GrokLens::Presenters.resume_command(s)
  end

  def test_store_merges_when_enabled
    grok = File.join(ROOT, "tmp", "fixture-home-multi")
    FixtureHelper.build_fixture_home(grok)
    codex = File.join(ROOT, "tmp", "fixture-codex-multi")
    cursor = File.join(ROOT, "tmp", "fixture-cursor-multi")
    cids = FixtureHelper.build_codex_home(codex)
    uids = FixtureHelper.build_cursor_home(cursor)
    ENV["GROK_LENS_CODEX"] = "1"
    ENV["GROK_LENS_CODEX_HOME"] = codex
    ENV["GROK_LENS_CURSOR"] = "1"
    ENV["GROK_LENS_CURSOR_HOME"] = cursor
    store = GrokLens::Store.new(grok_home: grok)
    FixtureHelper.stub_registry_pid(store, Process.pid, "11111111-1111-1111-1111-111111111111")
    snap = store.scan
    assert snap.session(cids[:id])
    assert snap.session(uids[:id])
    assert snap.primary_sessions.any?(&:grok?)
    assert_equal :codex, snap.session(cids[:id]).source_key
    assert_equal :cursor, snap.session(uids[:id]).source_key
  end

  def test_disabled_skips
    root = File.join(ROOT, "tmp", "fixture-codex")
    FixtureHelper.build_codex_home(root)
    ENV["GROK_LENS_CODEX"] = "0"
    assert_empty GrokLens::Codex.new(home: root).scan([])
  end
end
