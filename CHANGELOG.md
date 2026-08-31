# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.7.0] — 2026-08-31

### Added

- **MCP roster** (`/mcp`): servers from user/project config and installed-plugin `.mcp.json`
- Status **active** (in-flight call on a live session), **idle** (connected or configured), **suspended** (`enabled = false` / `disabled_mcp_servers`), **failed** (auth/timeout/handshake)
- Session-detail list of servers that session used (roster lives on `/mcp` only)
- Env/headers are never read

## [0.6.0] — 2026-08-31

### Added

- Real usage from Grok Build 1.0.14+ `usage.json` (same JSON as `grok usage <session-id>`)
- Billed input / output / cache-read / reasoning tokens, model calls, and USD (`costUsdTicks` / 10¹⁰)
- Session-detail recorded-usage panel and per-turn table
- Copy `grok usage <id>` next to resume
- Home/header cost from billed totals without setting a napkin rate

### Changed

- Token column drops the **est.** / `~` prefix when the usage ledger covers the session
- Partial ledgers (recorded turns < session turns) keep the lifetime estimate and flag the billed slice as partial — last-turn input is not treated as lifetime
- Napkin `GROK_LENS_USD_PER_M_TOKENS` applies only where `usage.json` is missing

## [0.5.0] — 2026-08-15

### Added

- Source seam: Grok Build, Codex, and Cursor sessions on one Home ledger
- Codex adapter (`~/.codex/session_index.jsonl` + rollout `session_meta` prefix)
- Cursor adapter (`~/.cursor/projects/*/agent-transcripts`)
- Home source chips only for sources that returned rows
- `codex resume <id>` copy on Codex detail; Cursor has no per-chat resume

### Notes

- Token counts are omitted for Codex/Cursor (no invented API usage)
- Grok Bot stays a separate agent roster; Mobirok is not in this release
- Disable with `GROK_LENS_CODEX=0` / `GROK_LENS_CURSOR=0`

## [0.4.1] — 2026-08-15

### Changed

- Grok Bot is a **separate roster**, not mixed into Grok Build sessions
- Agents grouped by sidebar section; status is **working** / **idle**
- Working agents show a short “doing now” line from the streaming replica
- Selected-in-app is no longer treated as working

## [0.4.0] — 2026-08-15

### Added

- **Grok Bot** sessions from the desktop app roster (`~/Library/Application Support/Grok Bot/sand-client-persistence`)
- Home source chips: All / Grok Build / Grok Bot
- Selected or awaiting-reply bot agents show as live while the Grok Bot process is running
- `open -a "Grok Bot"` as the open command (no invented resume CLI)
- Opt out with `GROK_LENS_GROK_BOT=0`

### Notes

- Bot transcripts are local replicas. Lens does not attach, prompt, or read Grok Bot credentials.
- Token figures for bot agents are size estimates of the replica blob, labeled **est.**

## [0.3.2] — 2026-08-14

### Fixed

- Registry PID is live only if the process command line owns that session UUID (shared/stale `active_sessions.json` rows)
- In-process subagents with `subagents/*/meta.json` `status: running` count as live (no child OS PID required)
- Home poll updates both header and stats-strip counts (duplicate `id`s removed)
- “Active now” is always in the DOM so a later live session appears without a full reload
- Home list and `/api/snapshot` include every primary session (no 50/60 cap)
- Soft poll re-renders the session table for any sort/filter and re-applies the typed filter
- Project URLs match exact `id` or exact path; `project_id` includes a path digest so `/foo/bar` ≠ `/foo-bar`
- Opening message streams the start of large `chat_history.jsonl` instead of skipping the file

### Changed

- Snapshot scan runs off the request mutex; readers keep the previous snapshot until swap
- `dir_size` skips `updates.jsonl`, `*.lock`, and `terminal/` logs
- Session detail timestamps print `UTC`

## [0.3.1] — 2026-08-05

### Fixed

- Running badge counts **all** live tasks (bg shells, tools, subagents), not bg-only

### Changed

- README refreshed for v0.3 features and status meanings

## [0.3.0] — 2026-08-05

### Added

- Hybrid token estimates (`signals.json` context + turns/tools + disk size)
- Context window display; optional est. cost (`GROK_LENS_USD_PER_M_TOKENS` / `~/.grok-lens.yml`)
- FTS **Search** over `session_search.sqlite`
- **Compare** two sessions (metrics + tool histograms)
- Home sort (last active / running / tokens / title) and “running only” filter
- Subagent badge `+N sub · K live`
- Partial poll re-renders Active/Recent tables without full page reload
- Running-task detection from `updates.jsonl` with process/port liveness

## [0.2.0] — 2026-07-28

### Added

- Light / dark / system color theme (persisted in `localStorage`)
- Copy **session id** and full **`grok --cwd … --resume <id>`** command from home and session detail
- Configurable live polling (default 5m; presets 30s / 1m / 5m / 10m / off) via UI + `GROK_LENS_POLL_SECONDS`
- `/api/snapshot` JSON endpoint for soft refresh; scan timing shown in header
- Slash-command **glossary** page (parsed from `~/.grok/docs/user-guide/04-slash-commands.md`)
- **Plugins & skills** inventory page with short descriptions

### Performance

- Full home scan typically ~20–40ms on a multi-dozen-session install; 30–60s polling is safe if desired

## [0.1.0] — 2026-07-14

### Added

- Local Sinatra dashboard for Grok Build sessions under `~/.grok`
- Dual home view: stats, active sessions, projects, recent sessions
- Project and session detail pages (skim: no full transcript)
- Nested subagent sessions under parents
- Estimated token counts (labeled **est.**) from on-disk artifact sizes
- Live / stale / idle status from `active_sessions.json` + PID checks
- Manual **Refresh** (snapshot on start; no live polling yet)
- Fixture-based unit and Rack tests
- Tufte-inspired dense paper UI with SVG sparklines

[0.7.0]: https://github.com/monomyth/grok-lens/releases/tag/v0.7.0
[0.6.0]: https://github.com/monomyth/grok-lens/releases/tag/v0.6.0
[0.5.0]: https://github.com/monomyth/grok-lens/releases/tag/v0.5.0
[0.4.1]: https://github.com/monomyth/grok-lens/releases/tag/v0.4.1
[0.4.0]: https://github.com/monomyth/grok-lens/releases/tag/v0.4.0
[0.3.2]: https://github.com/monomyth/grok-lens/releases/tag/v0.3.2
[0.3.1]: https://github.com/monomyth/grok-lens/releases/tag/v0.3.1
[0.3.0]: https://github.com/monomyth/grok-lens/releases/tag/v0.3.0
[0.2.0]: https://github.com/monomyth/grok-lens/releases/tag/v0.2.0
[0.1.0]: https://github.com/monomyth/grok-lens/releases/tag/v0.1.0
