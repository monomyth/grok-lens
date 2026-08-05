# Grok Lens

[![CI](https://github.com/monomyth/grok-lens/actions/workflows/ci.yml/badge.svg)](https://github.com/monomyth/grok-lens/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Ruby](https://img.shields.io/badge/Ruby-%3E%3D%204.0-red.svg)](https://www.ruby-lang.org/)

Local, **read-only** dashboard for [Grok Build](https://x.ai/) sessions and projects stored under `~/.grok`.

Ruby **4.x** · Sinatra · Tufte-inspired dense UI · snapshot on start

> **Privacy:** Session data can include prompts and code. Grok Lens binds to `127.0.0.1` by default and never writes to `~/.grok`. See [SECURITY.md](SECURITY.md).

## Features

- **Projects** grouped by session working directory — path, short description, model mix, est. tokens
- **Sessions** with status (**live** / **stale** / **idle**), title, model, turns, est. tokens
- **Nested subagents** under parent sessions
- **Session skim** — first user prompt, tool histogram, activity sparkline (not a full chat viewer)
- **Light / dark / system** theme
- Copy **session id** and ready-to-paste **`grok --cwd … --resume <id>`**
- **Live polling** (default 5 minutes; 30s–10m or off — scans are typically 20–40ms)
- **Slash-command glossary** and **installed plugins & skills** inventory

Token counts are **estimates** derived from on-disk artifact sizes (`chat_history` + `events`). Grok does not currently persist API token usage in session files.

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
| `GROK_LENS_POLL_SECONDS` | `300` | Default auto-refresh interval (UI can override; `0` = off) |
| `GROK_LENS_USD_PER_M_TOKENS` | unset | Optional USD per 1M tokens for est. cost column |
| `GROK_LENS_CONFIG` | `~/.grok-lens.yml` | Optional YAML (`usd_per_m_tokens`) |

```bash
GROK_HOME=/path/to/.grok PORT=9292 bin/grok-lens
```

## Screenshots

Dual-home dashboard (synthetic demo data — not real session history):

![Grok Lens home dashboard](docs/images/home.png)

## Data sources (read-only)

| Path | Use |
|------|-----|
| `~/.grok/sessions/<cwd>/<id>/summary.json` | Titles, models, message counts, times |
| `events.jsonl` | Models per turn, tools, activity |
| `chat_history.jsonl` | First user prompt; size for token estimate |
| `active_sessions.json` | Active session IDs and PIDs |
| `sessions/session_search.sqlite` | Optional title fallback |
| Project `README.md` | Optional project description |

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
  bin/grok-lens          # launcher
  config.ru
  lib/grok_lens/         # store, models, app
  views/                 # ERB
  public/                # CSS + minimal JS
  test/                  # Minitest fixtures
  docs/                  # design notes
```

## Roadmap

- Full-text search UI over the session search index
- Real token telemetry when Grok writes usage fields
- Optional “open cwd in terminal” / deep-link helpers
- Partial DOM updates on poll (avoid full reload when lists change)

## License

[MIT](LICENSE)

## Disclaimer

Grok Lens is an independent community tool. It is not affiliated with or endorsed by xAI. “Grok” and related marks belong to their respective owners.
