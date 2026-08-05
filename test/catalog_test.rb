# frozen_string_literal: true

require_relative "test_helper"

class CatalogTest < Minitest::Test
  def setup
    @home = File.join(ROOT, "tmp", "catalog-home")
    FileUtils.rm_rf(@home)
    FileUtils.mkdir_p(File.join(@home, "docs", "user-guide"))
    FileUtils.mkdir_p(File.join(@home, "skills", "demo-skill"))
    FileUtils.mkdir_p(File.join(@home, "installed-plugins", "example-plugin-abcd1234", "skills", "plugin-skill"))

    File.write(File.join(@home, "docs", "user-guide", "04-slash-commands.md"), <<~MD)
      # Slash Commands

      ## Session Management

      ### `/resume`

      Open the session picker to reload a previous session from disk.

      ### `/new`

      Start a fresh session. Alias: `/clear`.

      ## Model and Mode

      ### `/model <name>`

      Switch models. Alias: `/m`.
    MD

    File.write(File.join(@home, "skills", "demo-skill", "SKILL.md"), <<~MD)
      ---
      name: demo-skill
      description: A demo skill for testing the catalog inventory.
      ---
      # Demo
    MD

    File.write(
      File.join(@home, "installed-plugins", "example-plugin-abcd1234", "skills", "plugin-skill", "SKILL.md"),
      <<~MD
        ---
        name: plugin-skill
        description: Skill shipped inside an installed plugin.
        user-invocable: true
        ---
      MD
    )

    File.write(
      File.join(@home, "installed-plugins", "example-plugin-abcd1234", "README.md"),
      "# Example Plugin\n\nDoes example things for tests.\n"
    )

    @catalog = GrokLens::Catalog.new(grok_home: @home)
  end

  def test_slash_commands_parsed
    cmds = @catalog.slash_commands
    names = cmds.map(&:name)
    assert_includes names, "/resume"
    assert_includes names, "/new"
    assert_includes names, "/model"
    resume = cmds.find { |c| c.name == "/resume" }
    assert_match(/session/i, resume.description)
  end

  def test_skills_and_plugins
    skills = @catalog.skills
    assert skills.any? { |s| s.name == "demo-skill" }
    assert skills.any? { |s| s.name == "plugin-skill" && s.source == "plugin" }

    plugins = @catalog.plugins
    assert_equal 1, plugins.size
    assert_equal "example-plugin", plugins.first.name
    assert_match(/example/i, plugins.first.description)
  end

  def test_utf8_normalization_for_binary_files
    plugin_dir = File.join(@home, "installed-plugins", "binary-plugin-deadbeef")
    FileUtils.mkdir_p(plugin_dir)
    # Non-UTF-8 bytes that would crash ERB if left as ASCII-8BIT
    File.binwrite(File.join(plugin_dir, "README.md"), "# Bin\n\nCaf\xE9 style plugin with \x80 binary.\n".b)
    cat = GrokLens::Catalog.new(grok_home: @home)
    plug = cat.plugins.find { |p| p.id == "binary-plugin-deadbeef" }
    assert plug
    assert_equal Encoding::UTF_8, plug.description.encoding
    assert plug.description.valid_encoding?
  end

  def test_resume_command
    session = GrokLens::Session.new(
      id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      cwd: "/Users/demo/code/acme-api",
      title: "t",
      summary_text: "",
      status: :idle,
      pid: nil,
      models: [],
      current_model_id: "grok-4.5",
      created_at: nil,
      last_active_at: nil,
      opened_at: nil,
      num_messages: 0,
      num_chat_messages: 0,
      num_turns: 0,
      tool_counts: {},
      est_tokens: 0,
      context_tokens: nil,
      context_window: nil,
      est_source: "size",
      disk_bytes: 0,
      agent_name: nil,
      session_kind: nil,
      parent_id: nil,
      children: [],
      first_user_prompt: nil,
      git_root: nil,
      git_branch: nil,
      git_commit: nil,
      activity_points: [],
      detail_loaded: false,
      running_tasks: []
    )
    cmd = GrokLens::Presenters.resume_command(session)
    assert_equal "grok --cwd /Users/demo/code/acme-api --resume aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", cmd
  end
end
