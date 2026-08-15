# frozen_string_literal: true

require "minitest/autorun"
require "rack/test"
require "fileutils"
require "json"
require "time"

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(ROOT, "lib"))
require "grok_lens"

module FixtureHelper
  module_function

  def build_fixture_home(root)
    FileUtils.rm_rf(root)
    FileUtils.mkdir_p(root)

    proj = "/tmp/demo-project"
    encoded = proj.gsub("/", "%2F")
    parent_id = "11111111-1111-1111-1111-111111111111"
    child_id = "22222222-2222-2222-2222-222222222222"
    idle_id = "33333333-3333-3333-3333-333333333333"

    parent_dir = File.join(root, "sessions", encoded, parent_id)
    child_dir = File.join(root, "sessions", encoded, child_id)
    idle_dir = File.join(root, "sessions", encoded, idle_id)
    FileUtils.mkdir_p([parent_dir, child_dir, idle_dir, File.join(parent_dir, "subagents", child_id)])

    write_summary(parent_dir, parent_id, proj,
                  title: "Parent Session Title",
                  summary: "Working on the demo project with nested helpers.",
                  model: "grok-4.5",
                  turns: 3,
                  messages: 40)
    write_summary(child_dir, child_id, proj,
                  title: "Subagent Helper",
                  summary: "Child worker session",
                  model: "grok-build",
                  turns: 0,
                  messages: 10,
                  kind: "subagent")
    write_summary(idle_dir, idle_id, proj,
                  title: "Older Idle Session",
                  summary: "Finished work",
                  model: "grok-composer-2.5-fast",
                  turns: 5,
                  messages: 20,
                  created: "2026-06-01T12:00:00Z",
                  updated: "2026-06-01T13:00:00Z")

    File.write(File.join(parent_dir, "chat_history.jsonl"), [
      { type: "system", content: "sys" }.to_json,
      { type: "user", content: [{ type: "text", text: "Please refactor the module cleanly." }] }.to_json,
      { type: "assistant", content: "ok", model_id: "grok-4.5" }.to_json
    ].join("\n") + "\n")

    File.write(File.join(parent_dir, "events.jsonl"), [
      { ts: "2026-07-01T10:00:00Z", type: "turn_started", model_id: "grok-4.5", turn_number: 0 }.to_json,
      { ts: "2026-07-01T10:00:01Z", type: "tool_started", tool_name: "read_file" }.to_json,
      { ts: "2026-07-01T10:00:02Z", type: "tool_completed", tool_name: "read_file" }.to_json,
      { ts: "2026-07-01T10:00:03Z", type: "first_token" }.to_json,
      { ts: "2026-07-01T10:01:00Z", type: "turn_started", model_id: "grok-4.5", turn_number: 1 }.to_json
    ].join("\n") + "\n")

    # One completed bg tool + one still-running bg tool (live via port 19876)
    File.write(File.join(parent_dir, "updates.jsonl"), [
      {
        timestamp: Time.now.to_i - 60,
        method: "session/update",
        params: {
          sessionId: parent_id,
          update: {
            sessionUpdate: "tool_call",
            toolCallId: "call-dead-1",
            title: "[bg] sleep 1 (019fdead)",
            rawInput: { command: "sleep 1", background: true, description: "old finished" }
          }
        }
      }.to_json,
      {
        timestamp: Time.now.to_i - 30,
        method: "session/update",
        params: {
          sessionId: parent_id,
          update: {
            sessionUpdate: "tool_call_update",
            toolCallId: "call-dead-1",
            status: "completed"
          }
        }
      }.to_json,
      {
        timestamp: Time.now.to_i,
        method: "session/update",
        params: {
          sessionId: parent_id,
          update: {
            sessionUpdate: "tool_call",
            toolCallId: "call-live-bg",
            title: "[bg] python3 -m http.server 19876 (019flive)",
            status: "in_progress",
            rawInput: {
              command: "python3 -m http.server 19876",
              background: true,
              description: "demo static server"
            },
            _meta: {
              "x.ai/tool" => {
                "name" => "run_terminal_command",
                "input" => { "command" => "python3 -m http.server 19876", "background" => true }
              }
            }
          }
        }
      }.to_json
    ].join("\n") + "\n")

    File.write(File.join(child_dir, "chat_history.jsonl"), "x" * 400)
    File.write(File.join(idle_dir, "chat_history.jsonl"), "y" * 200)

    # Active: parent with current pid (alive), idle session listed with dead pid
    File.write(File.join(root, "active_sessions.json"), JSON.pretty_generate([
      { session_id: parent_id, pid: Process.pid, cwd: proj, opened_at: "2026-07-14T12:00:00Z" },
      { session_id: idle_id, pid: 999_999_999, cwd: proj, opened_at: "2026-06-01T12:00:00Z" }
    ]))

    { parent_id: parent_id, child_id: child_id, idle_id: idle_id, proj: proj }
  end

  def write_summary(dir, id, cwd, title:, summary:, model:, turns:, messages:, kind: nil, created: "2026-07-01T10:00:00Z", updated: "2026-07-01T11:00:00Z")
    data = {
      "info" => { "id" => id, "cwd" => cwd },
      "session_summary" => summary,
      "generated_title" => title,
      "created_at" => created,
      "updated_at" => updated,
      "last_active_at" => updated,
      "num_messages" => messages,
      "num_chat_messages" => messages / 2,
      "current_model_id" => model,
      "next_trace_turn" => turns,
      "agent_name" => "grok-build-plan"
    }
    data["session_kind"] = kind if kind
    File.write(File.join(dir, "summary.json"), JSON.pretty_generate(data))
  end

  # Make a fixture PID look like a grok process that owns +session_id+.
  def stub_registry_pid(store, pid, session_id)
    store.define_singleton_method(:pid_command) do |p|
      p.to_i == pid.to_i ? "grok --cwd /tmp/demo-project --resume #{session_id}" : ""
    end
  end
end
