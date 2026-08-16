# frozen_string_literal: true

require_relative "test_helper"

class BotTest < Minitest::Test
  def setup
    @root = File.join(ROOT, "tmp", "fixture-grok-bot")
    @ids = FixtureHelper.build_bot_fixture(@root)
    ENV["GROK_LENS_GROK_BOT"] = "1"
    ENV["GROK_LENS_GROK_BOT_APP"] = @root
    @bot = GrokLens::Bot.new(app_support: @root)
  end

  def teardown
    ENV["GROK_LENS_GROK_BOT"] = "0"
    ENV.delete("GROK_LENS_GROK_BOT_APP")
  end

  def test_base32_roundtrip
    key = "sand.client.slice.account.test.roster.last-roster"
    stem = GrokLens::Bot.encode_key(key)
    assert_equal key, GrokLens::Bot.decode_key(stem)
  end

  def test_scan_lists_agents_not_sessions
    warnings = []
    rows = @bot.scan(warnings)
    assert_empty warnings
    assert_equal 2, rows.size
    assert rows.all? { |a| a.is_a?(GrokLens::BotAgent) }
    research = rows.find { |a| a.id == @ids[:research_id] }
    inbox = rows.find { |a| a.id == @ids[:inbox_id] }
    assert_equal "Research Bot", research.name
    assert_equal "Research", research.section
    assert_equal :idle, research.status
    assert_equal :working, inbox.status
    assert_match(/two-line reply/i, inbox.activity.to_s)
    refute research.activity
  end

  def test_store_does_not_merge_agents_into_sessions
    home = File.join(ROOT, "tmp", "fixture-home-with-bot")
    FixtureHelper.build_fixture_home(home)
    store = GrokLens::Store.new(grok_home: home)
    FixtureHelper.stub_registry_pid(store, Process.pid, "11111111-1111-1111-1111-111111111111")
    snap = store.scan
    refute snap.session(@ids[:research_id])
    refute snap.projects.any? { |p| p.path.to_s.start_with?("grok-bot://") }
  end

  def test_disabled_skips_scan
    ENV["GROK_LENS_GROK_BOT"] = "0"
    assert_empty GrokLens::Bot.new(app_support: @root).scan([])
  end
end
