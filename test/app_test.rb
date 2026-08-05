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
    GrokLens::App.set :catalog, GrokLens::Catalog.new(grok_home: @home)
    GrokLens::App.set :snapshot, nil
    GrokLens::App.set :last_scan_ms, nil
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

  def test_session_has_resume_command
    get "/sessions/#{@ids[:parent_id]}"
    assert last_response.ok?
    assert_match(/grok --cwd/, last_response.body)
    assert_match(/--resume/, last_response.body)
    assert_match(/Copy resume/, last_response.body)
  end

  def test_api_snapshot
    get "/api/snapshot?refresh=1"
    assert last_response.ok?
    body = JSON.parse(last_response.body)
    assert body["ok"]
    assert body["primary_sessions"].positive?
    assert body.key?("scan_ms")
  end

  def test_glossary_and_extensions_routes
    get "/glossary"
    assert last_response.ok?
    assert_match(/glossary/i, last_response.body)

    get "/extensions"
    assert last_response.ok?
    assert_match(/Plugins/i, last_response.body)
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
end


