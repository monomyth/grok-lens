# Plan: multi-source sessions + Grok bot

**Date:** 2026-08-13  
**Status:** proposal (Grok Bot *sessions* shipped in 0.4.0 as a Home source — not the Mobirok relay pane)

## Code review (current tree, v0.3.1)

Solid local dashboard: read-only, tests exist, features match the README. Main risks are **performance** and **store.rb size**, not feature gaps.

Full structured review: `docs/reviews/2026-08-13-code-review.md` (8 bugs, 7 suggestions, nits).

**Highest-priority bugs to fold into P0:**

1. Shared/stale PID in `active_sessions.json` can mark the wrong session **live**.
2. In-process subagents (`subagents/*/meta.json` `status: running`) are ignored.
3. Duplicate `stat-sessions` / `stat-tokens` ids — poll updates header only.
4. “Active now” / home filter / 50-row cap / poll re-render gaps.
5. Project URL `end_with?` + slug collisions.
6. Opening message skipped when `chat_history.jsonl` > 2 MB.

**Also:** mutex-held 5s scan; `dir_size` walks huge trees; leftover Lens pumas on :9292/:9295/:9296.

### Suggestions

- Split `Store` (scan / running-tasks / nest) before adding Codex/Cursor.
- Snapshot: compute off-mutex, swap pointer under lock.
- Running-task liveness: cache `ps`/`lsof` once per scan (partially done) and skip descendant `pgrep` for idle sessions (already limited to live).
- Tests: FTS against a tiny sqlite fixture; compare route with two ids; mutex/scan not required if we extract scanners.

### Outstanding (product, not bugs)

- Home screenshot is pre–running-tasks / pre-search.
- Token lifetime is still a **hybrid estimate**; context from `signals.json` is the only Grok-recorded number.
- No first-class “source” field yet (everything is Grok).

---

## Integration: Codex

**On disk (this machine):**

| Path | Role |
|------|------|
| `~/.codex/session_index.jsonl` | `{id, thread_name, updated_at}` — 23+ threads |
| `~/.codex/sessions/YYYY/MM/DD/rollout-…-<uuid>.jsonl` | Event stream: `session_meta` (cwd, model, originator), `response_item` |
| `~/.codex/archived_sessions/` | Older rollouts |
| `~/.codex/history.jsonl` | Prompt history |

**Map to Lens Session:**

- id ← index `id`
- title ← `thread_name`
- cwd ← first `session_meta.payload.cwd`
- last_active ← `updated_at`
- model ← `session_meta.payload` model fields
- live ← process cmdline contains session uuid or `codex` + cwd (best-effort)
- tokens ← omit unless a usage event exists in the jsonl
- resume ← `codex resume <id>` (confirm CLI; do not invent flags — verify `codex --help` at impl time)

**Do not** parse full rollout jsonl on home scan — index + file mtime + first `session_meta` line only.

## Integration: Cursor

**On disk:**

| Path | Role |
|------|------|
| `~/.cursor/projects/<slug>/` | One folder per workspace slug |
| `…/agent-transcripts/<uuid>/<uuid>.jsonl` | `{role, message.content[]}` (user/assistant/tool) |
| `…/terminals/` | Terminal dumps |
| `…/mcps/` | Project MCP cache |

**Map:**

- id ← transcript uuid
- title ← first user text (strip `<user_query>`)
- cwd ← decode slug `Users-monomyth-code-grok` → `/Users/monomyth/code/grok`
- last_active ← transcript mtime
- live ← Cursor process + recent mtime (weak)
- resume ← open Cursor at workspace (no stable CLI resume id publicly guaranteed)

Treat Cursor as **read-only history**, not a live TUI twin.

## Integration: Grok bot (Mobirok)

Existing **Mobirok** is already the remote Grok Build client (iPhone + Mac relay + iCloud queue). Do **not** build a second write path.

| Piece | Role |
|-------|------|
| Lens | Read-only index + “copy resume” / deep-link |
| MobirokMac | Indexes `~/.grok/sessions` → `sessions.json`; ACP attach |
| iOS / bot | Prompt, approve/deny tools |

**Lens + bot plan:**

1. **Read** Mobirok `sessions.json` + `remote/state.json` (attached session, pending permission) and show a **Bot** page (mockup 03).
2. Deep-link: `mobirok://session/<id>` or “copy attach command” — only if iOS URL exists; otherwise “open MobirokMac”.
3. Optional later: Telegram/X bot that **enqueues the same inbox JSON** Mobirok already uses — one write path.

Lens stays **never writing** to `~/.grok`.

---

## Plan of action

### P0 — hygiene (0.5–1 d)

- Kill stray Lens pumas; document one bind address.
- Off-mutex snapshot swap; cap `dir_size` / skip `updates.jsonl` in size walk.
- Refresh `docs/images/home.png`.
- Fixture test for FTS + search 200.

### P1 — adapter seam (2–3 d)

- `Source` enum: `grok | codex | cursor`
- `Session.source`, filter chips on home
- `GrokAdapter` = current Store extract
- Home query `?src=grok`

### P2 — Codex adapter (2 d)

- Index jsonl + one-line `session_meta`
- Filter chip + resume command after CLI check
- No full transcript viewer

### P3 — Cursor adapter (2 d)

- Walk `~/.cursor/projects/*/agent-transcripts`
- Title from first user message; cwd from slug
- Skim opening message only

### P4 — Mobirok / bot pane (2–3 d)

- Read iCloud queue if present; degrade if missing
- Show attach + pending permission
- Document “bot = Mobirok inbox, not a new agent”

### P5 — later / skip

- Full chat for any source
- Exact Agent Dashboard IPC
- Public bind + auth
- Fake unified token totals across vendors

---

## Mockups

See `docs/mockups/`:

- `01-unified-home.png` — source chips, one ledger
- `02-session-detail.png` — provider badge, resume, running list
- `03-bot-inbox.png` — Mac relay + phone approve
