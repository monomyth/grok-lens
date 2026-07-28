# Security Policy

## What Grok Lens does

Grok Lens is a **local, read-only** dashboard. It:

- Reads session metadata and artifacts under `GROK_HOME` (default `~/.grok`)
- Optionally reads project `README.md` files under session working directories
- Never writes to `~/.grok`
- Never phones home or sends your data to a remote service

## Sensitive data

Session stores can include **prompts, code snippets, paths, and tool outputs**. Treat the dashboard as confidential local tooling.

## Binding and network exposure

Default bind is `127.0.0.1` only. **Do not** expose the server on `0.0.0.0` or a public host without additional access control. There is no built-in authentication.

```bash
# Safe (default)
HOST=127.0.0.1 PORT=9292 bin/grok-lens

# Unsafe without a reverse proxy + auth
# HOST=0.0.0.0 bin/grok-lens
```

## Reporting issues

If you find a security issue in Grok Lens itself (path traversal, unintended writes, unsafe defaults), open a private security advisory on the GitHub repository or contact the maintainers before public disclosure.
