# frozen_string_literal: true

require_relative "test_helper"

class StoreTest < Minitest::Test
  def setup
    @home = File.join(ROOT, "tmp", "fixture-home")
    @ids = FixtureHelper.build_fixture_home(@home)
    @store = GrokLens::Store.new(grok_home: @home)
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
    assert parent.activity_points.any?
  end

  def test_estimate_format
    assert_equal "~1.5M", GrokLens::Estimate.format_tokens(1_500_000)
    assert_equal "~12k", GrokLens::Estimate.format_tokens(12_000)
  end

  def test_missing_home
    store = GrokLens::Store.new(grok_home: File.join(ROOT, "tmp", "nope-missing"))
    snap = store.scan
    assert snap.missing_home
  end
end
