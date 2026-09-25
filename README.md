# limen

An Emacs interface for agents.

## About

Limen lets a coding agent read and act on the Emacs session you work in. It keeps a registry of
operations — read a live buffer, save it, read the focus and the windows, list diagnostics and
compilation output, open a diff — and serves them to Claude Code, Codex, Pi and Oh My Pi over the
channel each harness speaks: the `limen` command line, loopback MCP, a Pi extension, and the
harnesses' own prompt hooks. Every file an operation reads or writes lies inside the agent's
project.

Limen also carries context the other way. With [herdr.el](https://github.com/srnnkls/herdr.el)
running the agents, each prompt you type into an agent's terminal arrives with what Emacs knows:
the file and line you are on, the region you selected, the buffers you visited last. The same
hooks feed an inbox of the questions agents are waiting on, notices between the members of a
herd, the model and context columns of the Herdr dashboard, edit review in Magit, and live
[memex.el](https://github.com/srnnkls/memex.el) transcripts.

Reach for it when agents work on the code you have open and should ask Emacs instead of guessing
from the disk, or when you run several agents under Herdr and want to steer them from Emacs.

## Installation

Limen needs Emacs 29.1 or newer. It declares `transient` and `magit-section`, so a package manager
installs them with it; from a clone, install both from a package archive yourself. Clone the
repository and put it on `load-path`:

```sh
git clone https://github.com/srnnkls/limen ~/src/limen
```

```elisp
(add-to-list 'load-path "~/src/limen")
```

Put `bin/limen` on `PATH`, where agents look for it:

```sh
ln -s ~/src/limen/bin/limen ~/.local/bin/limen
```

The command reaches Emacs through `emacsclient`, so Emacs must run a server: `M-x server-start`,
or `(server-start)` in your init file.

Pi and Oh My Pi load Limen through the two extensions in `extensions/`. Link them where those
harnesses discover extensions:

```sh
cd ~/src/limen && mise run install-extensions
```

The integrations load only when you ask for them: herdr.el for agent panes,
[cera](https://github.com/srnnkls/cera) for the message field,
[scholia](https://github.com/srnnkls/scholia) for annotations, memex.el for transcripts, and
Magit for edit review. [Choosing what to load](GUIDE.md#choosing-what-to-load) lists which module
needs which.

## Getting started

The smallest setup gives agents the command line:

```elisp
(require 'limen)
(require 'limen-trail)
(limen-trail-mode 1)
```

Open a file of some project in Emacs, then ask from a shell inside that project:

```console
$ limen focus
{"version":1,"ok":true,"operation":"focus.get","result":{"name":"app.py","kind":"file",...,"point":{"line":40,...}}}

$ limen context --section focus --section trail
{"version":1,"ok":true,"operation":"context.get","result":{"focus":{...},"trail":[...]}}

$ limen buffer read app.py --line 1 --end-line 20
```

Every answer is one JSON envelope, and the project is the one the shell's working directory lies
in. `limen skill` prints a Markdown reference of the operations enabled right now; hand it to an
agent as instructions, or let the prompt hooks do it.

With herdr.el installed, let Limen wire the agents Herdr starts and carry context on every prompt:

```elisp
(require 'limen-herdr)
(require 'limen-hooks)
(limen-herdr-mode 1)
(limen-hooks-mode 1)
```

Enabling `limen-hooks-mode` asks once per harness whether to add `limen hook` to its settings.
Start an agent from `M-x herdr-transient`, select a region in a project file, and type a prompt
into the agent's terminal: the agent receives an `Emacs context` block with the file, the
selected range and the text. [Your first session](GUIDE.md#your-first-session) walks through the
rest.

## Commands

Limen binds no global key. These commands are the entry points:

| Command | Does |
| --- | --- |
| [`limen-herdr-transient`](REFERENCE.md#limen-herdr-transientel) | menu: push context, integration status, install hooks, adopt Claude Code agents |
| [`limen-herdr-push-context`](REFERENCE.md#limen-herdrel) | send the region, point or marked Dired files to an agent |
| [`limen-hooks-install`](REFERENCE.md#limen-hooksel) | add Limen's hooks to a harness's settings |
| [`limen-hooks-uninstall`](REFERENCE.md#limen-hooksel) | remove them |
| [`limen-herdr-claude-adopt`](REFERENCE.md#limen-herdr-claudeel) | take up a Claude Code agent Herdr already runs |
| [`limen-herd-dispatch`](REFERENCE.md#limen-herdel) | choose the herd notices agents receive; `n` in `herdr-status` |
| [`limen-trail-clear`](REFERENCE.md#limen-trailel) | forget the buffer trail |
| [`limen-inbox-clear`](REFERENCE.md#limen-inboxel) | forget every pending question |
| [`limen-model-backfill`](REFERENCE.md#limen-modelel), [`limen-usage-backfill`](REFERENCE.md#limen-usageel) | fill the dashboard's model and context columns for agents started earlier |

Each feature is a global minor mode: `limen-trail-mode`, `limen-herdr-mode`, `limen-hooks-mode`,
`limen-inbox-mode`, `limen-herd-mode`, `limen-model-mode`, `limen-usage-mode`,
`limen-memex-live-mode`, `limen-complete-mode` and `limen-herdr-claude-auto-adopt-mode`.

The `limen` command line:

| Command | Does |
| --- | --- |
| [`limen context`](REFERENCE.md#limen-context) | project, focus, windows, buffers, compilations, trail and annotations in one call |
| [`limen focus`](REFERENCE.md#limen-focus) | the buffer, point and selection you are on |
| [`limen buffer`](REFERENCE.md#limen-buffer) | list, read, save and open buffers |
| [`limen trail`](REFERENCE.md#limen-trail) | recently visited buffers |
| [`limen windows`](REFERENCE.md#limen-windows) | the file windows of the selected frame |
| [`limen diagnostics`](REFERENCE.md#limen-diagnostics) | Flymake and Flycheck diagnostics |
| [`limen compile`](REFERENCE.md#limen-compile) | existing compilation buffers |
| [`limen annotations`](REFERENCE.md#limen-annotations) | scholia sessions and annotations |
| [`limen projects`](REFERENCE.md#limen-projects) | known projects |
| [`limen skill`](REFERENCE.md#limen-skill) | agent instructions for the enabled operations |
| [`limen hook`](REFERENCE.md#limen-hook) | answer a harness hook from standard input |
| [`limen eval`](REFERENCE.md#limen-eval) | evaluate Emacs Lisp, when enabled |

## Concepts

| Term | Meaning |
| --- | --- |
| *operation* | a named request an agent can make, such as `buffer.read`, served over the CLI, MCP or both |
| *session* | one agent's connection to Emacs, bound to a project root and, under Herdr, to a pane |
| *project confinement* | every path an operation reads or writes must lie inside the session's project |
| *focus* | the buffer, point and selection of the selected window, or of the window used before an agent's terminal |
| *trail* | the buffers you visited last, with the lines you settled on |
| *context block* | the `Emacs context` text a prompt hook adds to a prompt |
| *adoption* | Emacs taking up an agent Herdr already runs, which gives it a session |
| *attachment* | Emacs showing the terminal of an adopted agent |
| *subscription* | a feature's claim on hook events, which decides what Limen installs |

## Documentation

- [GUIDE.md](GUIDE.md) explains how Limen works and how to set up each feature, starting at
  [How Limen works](GUIDE.md#how-limen-works).
- [REFERENCE.md](REFERENCE.md) lists every command, key, user option, face, hook, MCP tool, CLI
  command, environment variable and exit status.
- [docs/integrations.md](docs/integrations.md) describes what each harness supports and how Limen
  reaches it.
- [docs/hook-payload.md](docs/hook-payload.md) specifies the hook events and how a feature
  subscribes to them.

## Development

```sh
mise run test                    # the ERT suites and the extension tests
eask run script test             # the ERT suites
eask run script test-extensions  # the extension tests, under Node
eask compile
eask lint checkdoc --strict
```

CI runs these on Emacs 29.1 and 30.1 on Linux and macOS, together with `eask lint package`,
`declare`, `indent`, `keywords`, `regexps` and `license`. The suites in `integration/` exercise
Limen against herdr.el, cera and scholia; they need those packages and their test helpers on
`load-path` and stay out of `mise run test`.

Where the code lives:

- `limen.el`: the operation and event registry, sessions, project confinement, the built-in
  operations, the CLI dispatcher and the agent skill.
- `limen-editor.el`, `limen-compile.el`, `limen-trail.el`, `limen-scholia.el`: selection events
  and diffs, compilation buffers, the buffer trail, annotations.
- `limen-mcp.el`: the loopback MCP server.
- `limen-provider.el`: what Limen knows about each harness.
- `limen-herdr.el`, `limen-herdr-claude.el`, `limen-herdr-transient.el`: the Herdr bridge,
  Claude Code adoption, the menu.
- `limen-hooks.el`: hook answers, subscriptions, installation, context blocks and edit review.
- `limen-inbox.el`, `limen-herd.el`, `limen-model.el`, `limen-usage.el`, `limen-memex.el`: the
  features built on hook events.
- `limen-message.el`, `limen-complete.el`: the Herdr message field.
- `limen-transcript.el`: reading harness transcripts.
- `bin/limen`: the POSIX shell client.
- `extensions/limen-hooks`, `extensions/limen-mcp`: the Pi and Oh My Pi extensions.

## License

GPL-3.0-or-later; see [license](license).
