# frozen_string_literal: true

require "time"

module GrokLens
  # In-flight work unit for a session (bg shell, tool call, live subagent).
  RunningTask = Data.define(
    :id,
    :kind,        # :bg_shell | :tool | :subagent
    :title,
    :status,
    :tool_name,
    :live
  )

  Session = Data.define(
    :id,
    :cwd,
    :title,
    :summary_text,
    :status,
    :pid,
    :models,
    :current_model_id,
    :created_at,
    :last_active_at,
    :opened_at,
    :num_messages,
    :num_chat_messages,
    :num_turns,
    :tool_counts,
    :est_tokens,
    :context_tokens,
    :context_window,
    :est_source,
    :disk_bytes,
    :agent_name,
    :session_kind,
    :parent_id,
    :children,
    :first_user_prompt,
    :git_root,
    :git_branch,
    :git_commit,
    :activity_points,
    :detail_loaded,
    :running_tasks,
    :source,       # :grok | :bot
    :bot_section
  ) do
    def primary?
      # Top-level ledger rows: anything without a known parent (orphan subagents included)
      parent_id.nil?
    end

    def active?
      status == :active
    end

    def stale?
      status == :stale
    end

    # All live in-flight work units (bg shells, tools, subagents) that passed liveness checks.
    def running_count
      Array(running_tasks).count(&:live)
    end

    def live_children_count
      Array(children).count(&:active?)
    end

    def source_key
      (source || :grok).to_sym
    end

    def bot?
      source_key == :bot
    end

    def grok?
      !bot?
    end

    def source_label
      bot? ? "Grok Bot" : "Grok"
    end

    def with(**changes)
      self.class.new(**to_h.merge(changes))
    end
  end

  # Grok Bot desktop agent (not a Grok Build session).
  BotAgent = Data.define(
    :id,
    :name,
    :description,
    :section_id,
    :section,
    :status,          # :working | :idle
    :awaiting,
    :selected,
    :activity,        # what it is doing, when working
    :last_entry,
    :created_at,
    :last_active_at,
    :app_alive
  ) do
    def working?
      status == :working
    end

    def idle?
      status == :idle
    end

    def with(**changes)
      self.class.new(**to_h.merge(changes))
    end
  end

  Project = Data.define(
    :id,
    :path,
    :name,
    :description,
    :sessions,
    :session_count,
    :est_tokens,
    :models_hist,
    :last_active_at,
    :disk_bytes
  )

  Snapshot = Data.define(
    :scanned_at,
    :grok_home,
    :projects,
    :sessions_by_id,
    :primary_sessions,
    :active_sessions,
    :warnings,
    :total_est_tokens,
    :models_hist,
    :missing_home
  ) do
    def session(id)
      sessions_by_id[id]
    end

    def project_for_path(path)
      projects.find { |p| p.path == path }
    end
  end
end
