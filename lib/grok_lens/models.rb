# frozen_string_literal: true

require "time"

module GrokLens
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
    :detail_loaded
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
