# Grok Lens — Design Spec

**Date:** 2026-07-14  
**Status:** Approved for implementation planning  
**Working name:** `grok-lens`  
**Location:** `/Users/monomyth/code/grok/grok-lens/`

## Problem

Grok Build stores rich session history under `~/.grok`, but there is no single place to see all projects, sessions, status, models, and approximate usage at a glance. The user wants a modern, clear, Tufte-inspired local dashboard.

## Goals

- View **all** Grok Build sessions and projects from local disk
- Show **state** (active / stale / idle), **directory path**, short **description**, **models used**
- Show **token usage when possible** — real API token counts are not stored; use labeled estimates
- Modern, slick, efficient UI following **Tufte** principles for data display
- Snapshot at process start (no live polling in v1)

## Non-goals (v1)

- Live file watching or auto-poll (tracked as **TODO** for later)
- Full chat transcript browser (some sessions are hundreds of MB)
- Mutating `~/.grok` or remote APIs
- Authentication (localhost-only assumption)
- Dollar cost estimates

## Decisions (locked)

| Decision | Choice |
|----------|--------|
| Interface | Local web app (A) |
| Navigation | Dual home: projects + sessions (C) |
| Refresh | Snapshot on start; manual Refresh button; live polling TODO |
| Subagents | Nested under primary sessions (B) |
| Usage display | Estimated tokens + proxies, labeled **est.** (B) |
| Session detail | Metadata + skim (not full chat) (B) |
| Architecture | Sinatra + ERB + pure CSS + inline SVG (Approach 1) |

## Architecture

```
~/.grok/  (read-only)
  sessions/<url-encoded-cwd>/<session-id>/
  active_sessions.json
  sessions/session_search.sqlite  (optional enrich)

        │  scan once at boot (+ POST /refresh)
        ▼
  GrokLens::Store  →  in-memory Snapshot
        │
  Sinatra + ERB + public/styles.css + SVG sparklines
```

### Layers

1. **Store** — filesystem readers; never write to `~/.grok`
2. **Models** — `Project`, `Session`, `UsageEstimate`, aggregates, `Snapshot`
3. **Web** — routes and ERB views
4. **Presenters** — formatting (paths, relative time, est. tokens, badges)

### Environment

- `GROK_HOME` — default `~/.grok` (override for fixtures/tests)
- Bind: `127.0.0.1` (configurable via rack/puma env if needed)

### Run

```bash
cd grok-lens
bundle install
bundle exec rackup   # → http://127.0.0.1:9292
# or
bin/grok-lens
```

## Data sources

| Source | Use |
|--------|-----|
| `sessions/<cwd>/<id>/summary.json` | Core metadata |
| `events.jsonl` | Models per turn, tool names/counts, activity timeline |
| `chat_history.jsonl` | First user prompt; contribution to token estimate |
| `active_sessions.json` | session_id, pid, cwd, opened_at |
| `session_search.sqlite` | Fallback title/content |
| Project `README.md` (if path exists) | Optional project description |

### Observed `summary.json` fields (production sample)

`info.id`, `info.cwd`, `session_summary`, `generated_title`, `created_at`, `updated_at`, `last_active_at`, `num_messages`, `num_chat_messages`, `current_model_id`, `next_trace_turn`, `agent_name`, `session_kind` (`subagent` | absent), `git_root_dir`, `head_commit`, `head_branch`, `parent_session_id` (forks), `sandbox_profile`, `reasoning_effort`

**Note:** No `prompt_tokens` / `completion_tokens` fields exist in current session artifacts. Token UI must remain estimated.

## Data model

```
Snapshot {
  scanned_at
  grok_home
  projects: [Project]
  sessions_by_id: { id => Session }
  warnings: [String]   # parse skips, etc.
}

Project {
  id              # stable key from cwd
  path            # absolute cwd
  name            # basename short name
  description     # 1–2 sentences (heuristic)
  sessions        # primary sessions only (children nested)
  aggregates      # session_count, est_tokens, models_hist, last_active_at
}

Session {
  id, cwd, title, summary_text
  status          # :active | :stale | :idle
  pid             # if active list entry
  models          # unique model_ids from summary + events
  current_model_id
  created_at, last_active_at, opened_at?
  num_messages, num_chat_messages, num_turns
  tool_counts     # { name => count } from events (lazy on detail)
  est_tokens
  disk_bytes      # sum of session dir files (cheap)
  agent_name, session_kind, parent_id
  children        # nested subagent/fork sessions
  first_user_prompt  # lazy, detail page
  git             # branch, commit, root if present
}
```

### Status rules

1. **Active** — id in `active_sessions.json` and `Process.kill(0, pid)` succeeds (or platform-equivalent alive check)
2. **Stale** — id in active list but pid not alive
3. **Idle** — not in active list

### Nesting rules

- Sessions with `session_kind == "subagent"` or `parent_session_id` attach under parent when parent is known
- Orphans (parent missing) appear as top-level with a badge
- Home “recent sessions” lists **primary** rows; badge `+N sub` for children

### Description heuristics

**Session title:** `generated_title` → `session_summary` → truncated first user prompt → short id  

**Session description (1–2 sentences):** `session_summary` if multi-sentence / long enough; else first user prompt truncated to ~240 chars  

**Project description:** newest primary session title/summary; else first paragraph of `README.md` under path; else “No description yet”

### Token estimate

```
est_tokens ≈ (chat_history_bytes + events_bytes * 0.25) / 4
```

- Prefer `File.size` over reading content for home aggregates
- Label all displays **est.** or “estimated”
- Cap: do not fully load files &gt; 50MB for skim content; still use size for estimate
- Proxies always shown: turns (`next_trace_turn` / event turn_started count), tool call counts, message counts, disk size, duration (`last_active_at - created_at`)

## UI

### Visual language (Tufte)

- Paper background (`#f7f4ef`), near-black text, thin rules — no shadows, gradients, or chartjunk
- Small multiples: sparklines for activity; unit bars for model mix
- Tabular lining figures for numbers
- Dense but calm layout; data-ink maximized
- System UI mono for paths; serif or neutral humanist sans for body (implementation may use `Iowan Old Style` / Georgia stack + a clean UI sans for chrome)

### Routes

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/` | Dual home |
| GET | `/projects/*path` or `/projects/:id` | Project detail |
| GET | `/sessions/:id` | Session detail (skim) |
| POST | `/refresh` | Re-scan and redirect back |

### Home layout (dual)

1. **Header** — product name, snapshot time, session/project counts, Refresh
2. **Stats strip** — active count, total est. tokens, turns (recent window if cheap), model mix
3. **Active now** — table of active/stale sessions
4. **Two columns** — Projects (cards) \| Recent primary sessions (ledger)

### Project page

Path, description, aggregates, model mix, table of primary sessions (expandable subagents).

### Session page (skim)

- Header: status, title, path, models, agent, git, times, est. tokens, disk, message/turn/tool counts
- Description / summary
- First user prompt (truncated)
- Tool-name frequency (small bar list) — requires events parse
- Activity sparkline from event timestamps
- Nested children table
- Explicit note: not a full transcript viewer

### Filters (v1 light)

- Optional client-side filter box on home session list (vanilla JS, no framework)
- Copy session id (small control)

## Stack

- **Ruby 4.x required** (workspace baseline: 4.0.x; do not target Ruby 3)
- Sinatra, Puma, Rack
- ERB views, `public/styles.css`
- Optional: `sqlite3` gem for search index enrich; degrade if missing
- No Node/npm build step
- `Gemfile` / README: document `ruby ">= 4.0"` and fail fast on older interpreters

### Layout

```
grok-lens/
  Gemfile
  config.ru
  bin/grok-lens
  lib/grok_lens.rb
  lib/grok_lens/
    app.rb
    store.rb
    models.rb
    estimate.rb
    presenters.rb
  views/
    layout.erb
    home.erb
    project.erb
    session.erb
  public/
    styles.css
    app.js          # minimal filter/copy only
  test/
    fixtures/
    store_test.rb
    app_test.rb
  README.md
  docs/superpowers/specs/2026-07-14-grok-lens-design.md
```

## Performance

- Home scan: walk session dirs, parse `summary.json` only + file sizes + `active_sessions.json`
- Detail page: parse `events.jsonl` (streaming) and head of `chat_history.jsonl`
- Avoid loading `updates.jsonl` in v1 (often huge)
- Target: home useful within a few seconds on ~400MB session tree

## Errors & empty states

- Missing `GROK_HOME`: clear empty state with path shown
- Corrupt JSONL line: skip; increment warning counter; show in footer
- Unknown session id: 404 page

## Testing

- Fixtures: synthetic `GROK_HOME` with 2 projects, primary + subagent, active + dead pid
- Unit: status classification, nesting, estimates, description heuristics
- Rack::Test: home 200, project page, session page, refresh

## Future TODO (documented, not v1)

- [ ] Soft live poll (5–10s) for active sessions and summary mtimes
- [ ] Full-text search UI over `session_search.sqlite`
- [ ] Optional real token telemetry if Grok starts writing usage fields
- [ ] Open cwd in terminal / Finder
- [ ] Export CSV of session ledger

## Success criteria

1. `bundle exec rackup` shows dual home with real data from `~/.grok`
2. Active sessions reflect live PIDs; stale when dead
3. Subagents nested under parents
4. Every token figure labeled estimated
5. UI is readable, dense, and free of decorative chartjunk
6. Tests pass against fixtures without reading the user’s real home
