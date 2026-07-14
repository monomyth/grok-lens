# Grok Lens

Local, read-only dashboard for **Grok Build** sessions and projects under `~/.grok`.

Ruby **4.x** · Sinatra · Tufte-inspired dense UI · snapshot on start (live polling is a future TODO).

## Requirements

- Ruby **>= 4.0**
- Bundler

```bash
ruby -v   # must be 4.x
```

## Run

```bash
cd grok-lens
bundle install
bundle exec rackup -o 127.0.0.1 -p 9292
# or
chmod +x bin/grok-lens && bin/grok-lens
```

Open **http://127.0.0.1:9292**

Optional:

```bash
GROK_HOME=/path/to/.grok PORT=9292 bin/grok-lens
```

## What it shows

- **Projects** (by session cwd) with path, short description, model mix, est. tokens
- **Sessions** with status (live / stale / idle), title, model, turns, est. tokens
- **Nested subagents** under parent sessions
- **Session skim**: first user prompt, tool histogram, activity sparkline — not full chat

Token counts are **estimates** from on-disk artifact sizes (`chat_history` + `events`). Grok does not currently store API token usage in session files.

## Tests

```bash
bundle exec ruby -Itest test/store_test.rb test/app_test.rb
```

## Layout

See `docs/superpowers/specs/2026-07-14-grok-lens-design.md`.
