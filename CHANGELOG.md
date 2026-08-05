# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] — 2026-08-05

### Added

- Hybrid token estimates (`signals.json` context + turns/tools + disk size)
- Context window display; optional est. cost (`GROK_LENS_USD_PER_M_TOKENS` / `~/.grok-lens.yml`)
- FTS **Search** over `session_search.sqlite`
- **Compare** two sessions (metrics + tool histograms)
- Home sort (last active / running / tokens / title) and “running only” filter
- Subagent badge `+N sub · K live`
- Partial poll re-renders Active/Recent tables without full page reload
- Tighter running-task liveness (session pid descendants + ports; badge = bg + subagents)

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

[0.3.0]: https://github.com/monomyth/grok-lens/releases/tag/v0.3.0
[0.2.0]: https://github.com/monomyth/grok-lens/releases/tag/v0.2.0
[0.1.0]: https://github.com/monomyth/grok-lens/releases/tag/v0.1.0
