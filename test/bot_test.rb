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

  def test_scan_reads_roster
    warnings = []
    rows = @bot.scan(warnings)
    assert_empty warnings
    assert_equal 2, rows.size
    research = rows.find { |s| s.id == @ids[:research_id] }
    inbox = rows.find { |s| s.id == @ids[:inbox_id] }
    assert research.bot?
    assert_equal "Research Bot", research.title
    assert_equal "Research", research.bot_section
    assert_equal "grok-bot://section-research", research.cwd
    assert_equal :active, research.status, "selected agent is live while Grok Bot pid is this process"
    assert_equal :active, inbox.status, "awaiting user response is live"
    assert research.est_tokens.positive?
    assert_match(/Summarize the brief/i, research.first_user_prompt.to_s)
  end

  def test_enrich_reads_opening_message
    session = @bot.scan([]).find { |s| s.id == @ids[:research_id] }
    rich = @bot.enrich(session)
    assert rich.detail_loaded
    assert_match(/summarize the brief/i, rich.first_user_prompt.to_s)
    assert rich.num_messages >= 2
  end

  def test_store_merges_bot_into_snapshot
    home = File.join(ROOT, "tmp", "fixture-home-with-bot")
    FixtureHelper.build_fixture_home(home)
    store = GrokLens::Store.new(grok_home: home)
    FixtureHelper.stub_registry_pid(store, Process.pid, "11111111-1111-1111-1111-111111111111")
    snap = store.scan
    bot = snap.session(@ids[:research_id])
    assert bot, "expected Grok Bot agent in snapshot"
    assert bot.bot?
    assert snap.primary_sessions.any?(&:grok?)
    assert snap.projects.any? { |p| p.path.start_with?("grok-bot://") }
  end

  def test_resume_opens_app
    session = @bot.scan([]).first
    assert_equal 'open -a "Grok Bot"', GrokLens::Presenters.resume_command(session)
  end

  def test_disabled_skips_scan
    ENV["GROK_LENS_GROK_BOT"] = "0"
    assert_empty GrokLens::Bot.new(app_support: @root).scan([])
  end
end
