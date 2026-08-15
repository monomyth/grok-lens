# Grok Lens full-tree code review — 2026-08-13

Reviewed: `grok-lens` 0.3.1 (Ruby 4 / Sinatra local dashboard over `GROK_HOME`). Working tree was clean. Checked store/app/catalog/search/estimate/presenters, views, `public/app.js`, tests, and the on-disk Grok contract (`summary.json`, `updates.jsonl`, `signals.json`, `active_sessions.json`, `subagents/*/meta.json`).

## Summary

Grok Lens is a coherent read-only dashboard: snapshot + mutex, labeled hybrid estimates, careful HTML escaping, and tests that cover nesting, stale PIDs, hybrid tokens, and UTF-8 plugin READMEs. The main correctness gaps are live-state detection (registry PIDs and in-process subagents) and the home/poll UI, which does not actually show or refresh the full ledger it claims to. Nothing here writes to `~/.grok`, and bind defaults in `bin/grok-lens` stay localhost.

## Issues

### Issue 1 -- Severity: bug
- File: lib/grok_lens/store.rb:271
- Description: A session is marked `:active` whenever `active_sessions.json` lists it and `pid_alive?` succeeds. Grok leaves old rows in that registry; two session IDs often share one still-living PID after resume. `discover_live_from_processes` (store.rb:213) only overwrites an entry when the stored PID is already dead, so a live-but-wrong PID is never corrected. Those sessions appear as **live** on home, in `running_count` rollups, and in `/api/snapshot`.
- Suggestion: After loading the registry, resolve each live PID’s command line (`ps -p`). If it contains a different session UUID, drop or downgrade the row. Optionally treat “same PID, newer `opened_at`” as the only live owner.
- Status: fixed in 0.3.2 (`resolve_registry_pid_ownership`)

### Issue 2 -- Severity: bug
- File: lib/grok_lens/store.rb:347
- Description: Live subagents are counted only when `child.active?` (i.e. the child has its own live OS PID). Real Grok subagents are usually in-process: `summary.json` has `session_kind: "subagent"` and often **no** `parent_session_id`; liveness is in `subagents/<uuid>/meta.json` (`status: "running"` / `"completed"`). `nest!` (store.rb:562) only uses directory names. Result: `+N sub · K live` and the parent’s running-task list miss work that is actually running.
- Suggestion: When scanning `subagents/`, parse `meta.json` and treat `status == "running"` as live (session status and/or a `:subagent` `RunningTask`). Do not require `active_sessions.json` for children.
- Status: fixed in 0.3.2 (`subagents/*/meta.json` + `load_running_tasks`)

### Issue 3 -- Severity: bug
- File: views/layout.erb:42
- Description: `id="stat-sessions"` and `id="stat-tokens"` are used in the header (`layout.erb:42` / `layout.erb:46`) and again in the home stats strip (`views/home.erb:18` / `views/home.erb:23`). `document.getElementById` in `public/app.js:198` updates only the first node. Soft poll refreshes the header counts and leaves the large home figures stale.
- Suggestion: Give the strip distinct ids (`stat-sessions-home`, `stat-tokens-home`) and update both, or update via a class / `querySelectorAll`.
- Status: fixed in 0.3.2 (`stat-header-*` vs strip ids)

### Issue 4 -- Severity: bug
- File: views/home.erb:32
- Description: The “Active now” table is rendered only when the first snapshot has `active_sessions`. Poll writes into `#active-tbody` (`public/app.js:202`) and does nothing if that node was never painted. A boot with no live sessions, then a later live session, never grows the table until a full page load. The inverse (all sessions going idle) leaves an empty table section rather than hiding it.
- Suggestion: Always emit `#active-block` / `#active-tbody` (hide with CSS when empty) and let `applySnapshot` show/hide from `data.active_sessions`.
- Status: fixed in 0.3.2 (always emit `#active-block`, hide when empty)

### Issue 5 -- Severity: bug
- File: views/home.erb:124
- Description: Home lists `@sorted_sessions.first(50)` only. The client filter (`public/app.js:109`) searches `tr[data-filter]` in that slice. `/api/snapshot` also returns `primary_sessions.first(60)` (`lib/grok_lens/app.rb:198`). Installs with more than 50 primaries cannot find older sessions via Home → Filter, which the UI presents as a full-ledger filter. Design goal was to view all sessions.
- Suggestion: Paginate or raise the cap server-side; apply Filter/sort across the full primary list (or send ids+titles for the filter even if the table is windowed). Point the in-page filter at `/search` when the user has more than N sessions.
- Status: fixed in 0.3.2 (full primary list; API returns all)

### Issue 6 -- Severity: bug
- File: public/app.js:207
- Description: Soft poll only replaces `#recent-tbody` when sort is default and `running` is unset. That replacement does not re-apply `#filter`, so a typed filter flashes back to the unfiltered 50. If `?running=1`, the branch neither replaces rows nor patches running cells — the table is frozen. Custom sort only patches `.running-cell`, so titles, tokens, and new sessions stay stale.
- Suggestion: Re-render from `data.recent_sessions` (or a dedicated `/api/sessions` list) using the current sort/filter, then re-run the client filter function. At minimum, after `innerHTML = …`, re-apply the current `#filter` value.
- Status: fixed in 0.3.2 (always re-render + re-apply filter)

### Issue 7 -- Severity: bug
- File: lib/grok_lens/app.rb:156
- Description: Project lookup is `path ==`, `id ==`, or `p.path.end_with?(path)` where `path` is `"/" + splat`. `/projects/grok` matches any cwd ending in `/grok`; `/projects/tmp` matches `/var/tmp` as well as `/tmp`. `project_id` (`lib/grok_lens/store.rb:615`) collapses `/foo/bar` and `/foo-bar` to the same slug, so two projects can share one URL and the first `find` wins.
- Suggestion: Prefer exact `id` then exact `path`. Drop `end_with?` or require a unique match. Make `project_id` collision-resistant (e.g. hex of the path, or keep `%2F` encoding).
- Status: fixed in 0.3.2 (exact id/path; digest suffix on `project_id`)

### Issue 8 -- Severity: bug
- File: lib/grok_lens/store.rb:713
- Description: `extract_first_user_prompt` returns `nil` if `chat_history.jsonl` is larger than 2 MB, instead of reading a prefix. Long sessions (typical once tool results land in chat history) then omit “Opening message” even though the first real `<user_query>` is in the first few records. Wrapper scrubbing itself is correct; the size gate is not.
- Suggestion: Stream from the start with a byte/line budget (stop after N bytes or first cleaned user prompt). Do not skip the file because its *total* size is large.
- Status: fixed in 0.3.2 (stream from start with a byte budget)

### Issue 9 -- Severity: suggestion
- File: lib/grok_lens/store.rb:366
- Description: Open tool calls are recovered only from the last 2.5 MB of `updates.jsonl`. Long sessions append large inlined tool results; a still-running `run_terminal_command` whose last `tool_call_update` aged out of that window disappears. Combined with Issue 2, the “N running” badge under-counts on the sessions that need it most.
- Suggestion: Raise the tail, or scan backward for `tool_call` / `tool_call_update` until N open ids or a time bound. Persist last-known open ids from the previous snapshot to avoid dropouts.
- Status: open

### Issue 10 -- Severity: suggestion
- File: lib/grok_lens/store.rb:457
- Description: Liveness for bg/terminal tools treats any 3xxx/8xxx/9xxx token as a port and any 40-character command prefix as a process needle (`command_needles`, store.rb:473). An archived `python3 -m http.server 3000` looks live if *anything* listens on 3000; common prefixes match unrelated processes. That inflates `running_count` on idle sessions that are still `:active` (Issue 1).
- Suggestion: Prefer session-PID descendants, then explicit `PORT=` / `-p` / `:port` forms. Drop the “any 3/8/9xxx” scan. Require needles longer than a generic interpreter invocation, or match against `terminal/*.log` metadata if Grok records the child PID.
- Status: open

### Issue 11 -- Severity: suggestion
- File: lib/grok_lens/app.rb:131
- Description: Compare’s `<select>` is `primary_sessions.first(80)`. `/compare?a=<id>` still enriches a session outside that window, but the dropdown shows “—” and a third session cannot be picked. Same class of “hidden tail” as Issue 5.
- Suggestion: Include the currently selected A/B ids in the option list, or populate the picker from search / all primaries.
- Status: open

### Issue 12 -- Severity: suggestion
- File: views/session.erb:39
- Description: `created_at` / `last_active_at` are parsed to UTC (`store.rb:678`) then printed with `strftime("%Y-%m-%d %H:%M")` and no zone. The header snapshot string includes `UTC`. Detail times look like local wall time and are several hours off for non-UTC users. `relative_time` is fine.
- Suggestion: Append ` UTC` (match the header) or format in the viewer’s local zone in JS.
- Status: open

### Issue 13 -- Severity: suggestion
- File: lib/grok_lens/catalog.rb:225
- Description: Headings of the form ``### `/always-approve` and `/auto` `` and ``### `/minimal` and `/fullscreen` `` become one command plus an alias. Grok documents them as distinct toggles. Glossary users cannot find `/auto` or `/fullscreen` as first-class rows.
- Suggestion: If the heading contains `` and `/...` ``, emit two `SlashCommand` records (shared description is fine).
- Status: open

### Issue 14 -- Severity: suggestion
- File: lib/grok_lens/store.rb:699
- Description: `each_jsonl` bails out of the *entire* `events.jsonl` when the file exceeds 50 MB. Session detail then has empty tool bars and no sparkline. Design called for not loading huge files, not for dropping all event-derived metrics.
- Suggestion: Stream from the start or sample, with a max-bytes / max-lines cap, same idea as Issue 8.
- Status: open

### Issue 15 -- Severity: suggestion
- File: lib/grok_lens/search.rb:57
- Description: FTS strings keep `AND`/`OR`/`NOT`/`:` (column filter). A query like `fork:session` can fail `MATCH` and silently fall through to `LIKE`. The LIKE path interpolates `%` / `_` from the user string as wildcards (`search.rb:68`). Parameterization prevents SQL injection; ranking and “no matches” vs “syntax error” are still wrong.
- Suggestion: Quote each term, strip FTS operators, and escape `%`/`_` in the LIKE fallback.
- Status: open

### Issue 16 -- Severity: nit
- File: lib/grok_lens/store.rb:650
- Description: `CGI.escape(...).gsub("+", "%20")` is immediately overwritten by `cwd.gsub("/", "%2F")`. The redundant `next unless live || info[:bg]` at store.rb:330 is dead. `require "set"` in store.rb:6 is unused.
- Suggestion: Delete the dead assignment, the extra `next`, and the unused require.
- Status: open

### Issue 17 -- Severity: nit
- File: public/app.js:168
- Description: Soft-poll context text uses `context_label.split(' ')[0]` gated on `est_tokens_label`, not `est(s.context_tokens)` as the ERB does (`views/home.erb:133`). After a poll, the ctx fragment can be empty or a bare `50k` instead of `~50k`.
- Suggestion: Send a dedicated `context_short` field or reuse `context_label` consistently.
- Status: open

## Outstanding / follow-ups

- **Tests:** No unit coverage for `Search`, `Config`, project routing, `meta.json` liveness, shared-PID registry rows, or `app.js` poll. `AppTest` does not replace `settings.search`, so any future query test would hit the real `GROK_HOME` index. `test_process_discovery_marks_live_resume` stubs `` ` `` for every subprocess, so it does not exercise `pgrep`/`lsof`.
- **`signals.json`:** Production files include `modelsUsed`, `toolsUsed`, `sessionDurationSeconds`, `contextWindowUsage`, and richer error counts. Light scan still uses only context/turns/tools plus `summary.json`’s current model. Lifetime hybrid (`estimate.rb:24`) can grow to several times `contextTokensUsed`; keep the **est.** label (already done) and consider showing raw context as the primary figure.
- **Performance:** Every session `dir_size` is a recursive `FNM_DOTMATCH` glob (terminal logs, locks, MCP dumps). Scan holds `snapshot_mutex` for the whole walk plus `ps`/`pgrep`/`lsof`. Fine for dozens of sessions; large homes will stall every request that needs a fresh snapshot. Consider caching sizes by mtime and running process probes off the request mutex.
- **Security posture:** Documented localhost, no auth, no CSRF on `POST /refresh`. Acceptable for the stated threat model. `permitted_hosts` includes `example.org` for Rack::Test; keep that out of any non-loopback bind. `bin/grok-lens` defaults to `127.0.0.1`; bare `rackup` without `-o` may still listen on all interfaces.
- **Docs:** `docs/superpowers/specs/2026-07-14-grok-lens-design.md` still lists poll and FTS search as future TODOs; they shipped in 0.3. Footer only shows a warning *count*, not the messages in `snap.warnings`.
- **Unused data:** `subagents/*/meta.json` (`description`, `status`, `effective_model_id`) and `continue_command` are unused in the UI. Poll never refreshes the projects column.
