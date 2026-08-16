# Grok Lens

[![CI](https://github.com/monomyth/grok-lens/actions/workflows/ci.yml/badge.svg)](https://github.com/monomyth/grok-lens/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Ruby](https://img.shields.io/badge/Ruby-%3E%3D%204.0-red.svg)](https://www.ruby-lang.org/)

Local, **read-only** dashboard for [Grok Build](https://x.ai/) sessions under `~/.grok` and [Grok Bot](https://x.ai/bot) agents on this Mac.

Ruby **4.x** · Sinatra · Tufte-inspired dense UI

> **Privacy:** Session data can include prompts and code. Binds to `127.0.0.1` by default and never writes to `~/.grok`. See [SECURITY.md](SECURITY.md).

## Features

- **Projects** by working directory — path, short description, model mix, est. tokens
- **Sessions** — **live** / **stale** / **idle**, models, turns, est. tokens, context window
- **Grok Bot** — named agents from the desktop app roster, filterable on Home
- **Running tasks** — in-flight bg shells / tools / live subagents (with process/port liveness checks)
- **Nested subagents** — `+N sub · K live`
- **Search** — FTS over Grok’s `session_search.sqlite`
- **Compare** — side-by-side metrics for two sessions
- **Copy** session id and `grok --cwd … --resume <id>`
- **Light / dark / system** theme (single cycle control)
- **Live polling** re-renders Active + Sessions (any sort/filter) without a full page reload
- **Glossary** of slash commands · **plugins & skills** inventory
- Sort / filter sessions (last active, running, tokens, title; running-only)

### Status meanings

| Label | Meaning |
|--------|---------|
| **live** | A Grok process for this session is running, or (Grok Bot) the app is open and this agent is selected / awaiting a reply |
| **stale** | Listed open but pid is dead |
| **idle** | No live process |
| **N running** | Live in-flight work units (bg shell, tool, subagent) after liveness checks |

Token **lifetime** figures are **estimates** (hybrid: `signals.json` + on-disk sizes). **Context** comes from Grok’s `signals.json` when present. Optional napkin **cost** only if you set a rate (see below) — not real billing.

## Requirements

- **Ruby >= 4.0**
- Bundler

```bash
ruby -v   # must report 4.x
```

## Install & run

```bash
git clone https://github.com/monomyth/grok-lens.git
cd grok-lens
bundle install
bundle exec rackup -o 127.0.0.1 -p 9292
# or
bin/grok-lens
```

Open **http://127.0.0.1:9292**

### Options

| Variable | Default | Meaning |
|----------|---------|---------|
| `GROK_HOME` | `~/.grok` | Root of Grok Build data |
| `HOST` | `127.0.0.1` | Bind address |
| `PORT` | `9292` | HTTP port |
| `GROK_LENS_POLL_SECONDS` | `300` | Default auto-refresh (UI can override; `0` = off) |
| `GROK_LENS_USD_PER_M_TOKENS` | unset | **Optional** USD per 1M tokens for est. cost — leave unset to hide cost |
| `GROK_LENS_CONFIG` | `~/.grok-lens.yml` | Optional YAML (`usd_per_m_tokens`) — see `config.example.yml` |
| `GROK_LENS_GROK_BOT` | on | Set `0` to hide Grok Bot agents |
| `GROK_LENS_GROK_BOT_APP` | `~/Library/Application Support/Grok Bot` | Desktop persistence root |

```bash
GROK_HOME=/path/to/.grok PORT=9292 bin/grok-lens
```

## Screenshots

Dual-home dashboard (synthetic demo data — not real session history):

![Grok Lens home dashboard](docs/images/home.png)

## Data sources (read-only)

| Path | Use |
|------|-----|
| `sessions/<cwd>/<id>/summary.json` | Titles, models, counts, times |
| `signals.json` | Context tokens / window, turns, tools (when present) |
| `events.jsonl` | Models, tools, activity sparkline |
| `updates.jsonl` | In-flight / background tool status |
| `chat_history.jsonl` | Opening message (wrappers stripped); size for est. |
| `active_sessions.json` + process table | Live / stale sessions |
| `sessions/session_search.sqlite` | FTS search |
| Project `README.md` | Optional project description |
| `~/Library/Application Support/Grok Bot/sand-client-persistence` | Grok Bot roster + transcript replicas |
| `…/sand-session-marker.json` | Grok Bot app liveness |

## Development

```bash
bundle install
bundle exec rake test
bundle exec rackup -o 127.0.0.1 -p 9292
```

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Project layout

```
grok-lens/
  bin/grok-lens
  config.ru
  config.example.yml
  lib/grok_lens/     # store, estimate, search, catalog, app
  views/
  public/
  test/
  docs/
```

## License

[MIT](LICENSE) · Copyright (c) 2026 Eugene Ray

## Disclaimer

Grok Lens is an independent community tool. It is not affiliated with or endorsed by xAI. “Grok” and related marks belong to their respective owners.
