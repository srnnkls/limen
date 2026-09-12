# Limen

Limen is a provider-neutral Emacs 29.1+ interface for local agents. It exposes project-confined operations, session events, live editor context and diffs, read-only compilation state, a loopback MCP transport, and a framed command-line client.

## Install

Install `websocket` 1.12+ and `transient` 0.9.0+ from a configured package archive, then place this directory on `load-path`. A standalone MCP setup loads the core operations, editor support, compilation observer, and transport:

```elisp
(require 'limen)
(require 'limen-editor)
(require 'limen-compile)
(require 'limen-mcp)
```

Recent-buffer tracking is opt-in. Load `limen-trail` and enable its mode to expose the visit trail:

```elisp
(require 'limen-trail)
(limen-trail-mode 1)
```

For Herdr-managed provider sessions, also load the bridge and enable its mode:

```elisp
(require 'limen-herdr)
(require 'limen-herdr-transient)
(limen-herdr-mode 1)
```

Limen installs no global keybinding.

## Command line

Put `bin/limen` on `PATH`. Run `limen` for the canonical command index and `limen help COMMAND` for command-specific arguments.

`context` returns the project, focus, windows, buffers, compilations, and trail in one call; `--section` narrows it. `trail` lists recently visited buffers with settled point traces while `limen-trail-mode` is enabled. `projects` uses Projectile when available and falls back to `project.el`. `compile` observes existing Emacs compilation buffers without starting work. `skill` generates instructions from the live operation registry. `eval -` reads source from standard input; evaluation remains disabled unless explicitly enabled in Emacs.

## Lisp interface

Register coarse operations with `limen-register-operation`, open integrations with `limen-open-session`, and expose a session over loopback MCP with `limen-mcp-register-session`. Selection events are sent only to open sessions whose project contains the current file. Closing the final session removes the shared selection hook.

`elisp.eval` is hidden and rejected unless `limen-enable-elisp-eval` is non-nil. This is an accidental-use gate, not a sandbox: same-user processes with Emacs-server access can already evaluate Emacs Lisp. MCP routes bind to loopback and use opaque bearer tokens; operation paths remain inside the request's project root.

## Provider integrations

Claude Code, Codex, and Pi can use Limen through their native transports. The optional `limen-herdr-mode` injects launch and lifecycle wiring into Herdr without making either package depend on the other at runtime. `M-x limen-herdr-transient` exposes status, context push, reconnect, adoption, and protocol diagnostics.

See [docs/integrations.md](docs/integrations.md) for the canonical capability, disclosure, and lifecycle contract. Claude's fixed wire evidence is recorded in [docs/claude-integration-parity.md](docs/claude-integration-parity.md).

## License

Limen is GPL-3.0-or-later; see [license](license). Its Claude Code compatibility transport includes material adapted from [manzaltu/claude-code-ide.el](https://github.com/manzaltu/claude-code-ide.el), also GPL-3.0-or-later.
