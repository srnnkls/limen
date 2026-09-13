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

With [scholia](https://github.com/srnnkls/scholia) installed, `limen-scholia` exposes annotation sessions as `annotation.*` operations and names the visible sessions in Herdr message headers:

```elisp
(require 'limen-scholia)
```

For Herdr-managed provider sessions, also load the bridge and enable its mode:

```elisp
(require 'limen-herdr)
(require 'limen-herdr-transient)
(limen-herdr-mode 1)
```

To have every prompt typed into a Claude Code or Codex pane carry Emacs context, load `limen-hooks` and enable its mode. Enabling asks once per provider whose settings lack `limen hook` and installs it; modes enabled by the same command share that prompt. `M-x limen-hooks-uninstall` removes it:

```elisp
(require 'limen-hooks)
(limen-hooks-mode 1)
```

`limen-inbox-mode` lists the questions agents are waiting on in an `Inbox` section at the top of `herdr-status`. Enabling it registers the question hook events and installs them the same way:

```elisp
(require 'limen-inbox)
(limen-inbox-mode 1)
```

Limen installs no global keybinding.

## Command line

Put `bin/limen` on `PATH`. Run `limen` for the canonical command index and `limen help COMMAND` for command-specific arguments.

`context` returns the project, focus, windows, buffers, compilations, and trail in one call; `--section` narrows it. `trail` lists recently visited buffers with settled point traces while `limen-trail-mode` is enabled. `annotations` lists scholia sessions, lists project-confined annotations, or renders a session in an export format; it answers `unknown_operation` until `limen-scholia` is loaded. `projects` uses Projectile when available and falls back to `project.el`. `compile` observes existing Emacs compilation buffers without starting work. `skill` generates instructions from the live operation registry. `hook claude` and `hook codex` answer the providers' `SessionStart` and `UserPromptSubmit` hooks from standard input; they act only inside Limen-launched or Herdr-hosted panes, give up silently after three seconds when Emacs does not answer, and exit silently otherwise. `eval -` reads source from standard input; evaluation remains disabled unless explicitly enabled in Emacs.

## Lisp interface

Register coarse operations with `limen-register-operation`, open integrations with `limen-open-session`, and expose a session over loopback MCP with `limen-mcp-register-session`. Selection events are sent only to open sessions whose project contains the current file. Closing the final session removes the shared selection hook.

`elisp.eval` is hidden and rejected unless `limen-enable-elisp-eval` is non-nil. This is an accidental-use gate, not a sandbox: same-user processes with Emacs-server access can already evaluate Emacs Lisp. MCP routes bind to loopback and use opaque bearer tokens; operation paths remain inside the request's project root.

## Provider integrations

Claude Code, Codex, and Pi can use Limen through their native transports. The optional `limen-herdr-mode` injects launch and lifecycle wiring into Herdr without making either package depend on the other at runtime. `M-x limen-herdr-transient` exposes status, context push, reconnect, adoption, and protocol diagnostics. Herdr's message and send commands receive Limen's snapshot for any project-confined buffer, virtual ones included, with a `live: \`limen context\`` field pointing at the full state. With `limen-hooks-mode` enabled, that snapshot and the recent buffer trail reach the agent through its prompt hook instead of the message body.

See [docs/integrations.md](docs/integrations.md) for the canonical capability, disclosure, and lifecycle contract. Claude's fixed wire evidence is recorded in [docs/claude-integration-parity.md](docs/claude-integration-parity.md).

## License

Limen is GPL-3.0-or-later; see [license](license). Its Claude Code compatibility transport includes material adapted from [manzaltu/claude-code-ide.el](https://github.com/manzaltu/claude-code-ide.el), also GPL-3.0-or-later.
