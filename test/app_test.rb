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
    GrokLens::App.set :store, GrokLens::Store.new(grok_home: @home)
    GrokLens::App.set :snapshot, nil
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
    assert_match(/First user prompt/, last_response.body)
    assert_match(/read_file/, last_response.body)
  end

  def test_project_page
    get "/projects/tmp-demo-project"
    assert last_response.ok?
    assert_match(/Parent Session Title/, last_response.body)
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
end
