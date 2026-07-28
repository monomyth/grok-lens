# Contributing

Thanks for your interest in Grok Lens.

## Development

```bash
git clone https://github.com/monomyth/grok-lens.git
cd grok-lens
bundle install
bundle exec rake test
bundle exec rackup -o 127.0.0.1 -p 9292
```

Use a fixture `GROK_HOME` when possible so tests and demos do not depend on your personal session history:

```bash
GROK_HOME=/path/to/fixture bundle exec rackup -o 127.0.0.1 -p 9292
```

## Guidelines

- **Ruby 4.x only** — do not add Ruby 3 compatibility shims unless discussed
- Keep the tool **read-only** with respect to `GROK_HOME`
- Prefer small, focused PRs
- Add or update tests for store parsing and HTTP routes when behavior changes
- Token figures must remain clearly labeled as **estimates** unless real API usage fields appear in Grok’s on-disk format

## Code layout

| Path | Role |
|------|------|
| `lib/grok_lens/store.rb` | Filesystem scan and session enrichment |
| `lib/grok_lens/app.rb` | Sinatra routes |
| `views/` | ERB templates |
| `public/` | CSS / minimal JS |
| `test/` | Minitest + Rack::Test |

## Pull requests

1. Fork and branch from `main` / `master`
2. Ensure `bundle exec rake test` passes
3. Describe the change and any screenshots for UI work
