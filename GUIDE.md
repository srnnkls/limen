# The Limen guide

Every command, option and CLI flag is listed in [REFERENCE.md](REFERENCE.md). What each harness
supports is in [docs/integrations.md](docs/integrations.md).

## Contents

- [How Limen works](#how-limen-works)
- [Choosing what to load](#choosing-what-to-load)
- [Your first session](#your-first-session)
- [The command line](#the-command-line)
- [What an agent can see](#what-an-agent-can-see)
- [Buffers](#buffers)
- [Context in one call](#context-in-one-call)
- [The buffer trail](#the-buffer-trail)
- [Diagnostics and compilations](#diagnostics-and-compilations)
- [Annotations](#annotations)
- [Diffs](#diffs)
- [MCP](#mcp)
- [Agents under Herdr](#agents-under-herdr)
- [Sending context](#sending-context)
- [Prompt hooks](#prompt-hooks)
- [Edit review](#edit-review)
- [The question inbox](#the-question-inbox)
- [Herd notices](#herd-notices)
- [Model and context columns](#model-and-context-columns)
- [Live memex transcripts](#live-memex-transcripts)
- [The message field](#the-message-field)
- [Completion in the field](#completion-in-the-field)
- [Pi and Oh My Pi](#pi-and-oh-my-pi)
- [Extending Limen](#extending-limen)
- [When something looks wrong](#when-something-looks-wrong)
- [Where to look next](#where-to-look-next)

## How Limen works

Limen sits between Emacs and the agents that work beside it. A few terms carry the model:

- An *operation* is one thing an agent can ask of Emacs, named with dots: `buffer.read`,
  `focus.get`, `diff.open`. Each declares its parameters, whether it reads or writes, and the
  *interfaces* it is offered on: the CLI, MCP, or both. An operation can be disabled, in which
  case it is hidden and refuses calls.
- A *request* is one call of an operation. It carries the *project root* every path is checked
  against, and the window the call is about.
- A *session* is one agent's standing connection. It owns a project root, the buffers and diffs
  the agent opened, and the events it subscribed to. Closing it releases all of that.
- An *event* is something Emacs tells a session without being asked. There are two:
  `context.selection`, the latest selection in a project file, and `context.push`, context you
  sent on purpose.
- A *hook* is a harness running `limen hook <provider>` at a point in its turn: session start,
  prompt submission, a tool call, the end of a turn. A *subscription* is a feature's claim on
  some of those hook events, and the union of subscriptions is what Limen installs.

The command line needs no session: each call names the working directory, and its project is the
root. A session exists when something opens one — the Herdr bridge does for every agent it
launches or adopts, and a Lisp caller can for an MCP client of its own.

## Choosing what to load

Every module is a separate `require`. Load the ones whose features you want:

| Module | Needs | Gives |
| --- | --- | --- |
| `limen` | nothing further | the registry, the built-in operations, the CLI |
| `limen-editor` | nothing further | selection events and interactive diffs |
| `limen-compile` | nothing further | `compile.list`, `compile.read` |
| `limen-trail` | nothing further | the buffer trail, once `limen-trail-mode` is on |
| `limen-mcp` | nothing further | the loopback MCP server |
| `limen-scholia` | scholia | `annotation.*` operations |
| `limen-herdr` | herdr.el | launch wiring for agents under Herdr, context sends |
| `limen-herdr-claude` | herdr.el | adopting Claude Code agents |
| `limen-herdr-transient` | herdr.el | the `limen-herdr-transient` menu |
| `limen-hooks` | herdr.el | context on every prompt, edit review |
| `limen-inbox` | herdr.el | the question inbox in `herdr-status` |
| `limen-herd` | herdr.el | herd notices |
| `limen-model`, `limen-usage` | herdr.el | the dashboard's model and context columns |
| `limen-memex` | memex.el | live transcript views |
| `limen-message` | cera, memex.el | context, recap and status around the message field |
| `limen-complete` | cera | `@`, `#` and `/` completion in the message field |

`limen-herdr` loads `limen-editor`, `limen-compile`, `limen-trail` and `limen-mcp` itself, and
`limen-herdr-mode` turns on the message-field extension of `limen-message`. The CLI loads
`limen-compile`, `limen-trail` and, when present, `limen-scholia` on demand, so `limen context`
and `limen compile` work in any Emacs that has Limen on `load-path`.

A full Herdr setup:

```elisp
(require 'limen-herdr)
(require 'limen-herdr-transient)
(require 'limen-hooks)
(require 'limen-inbox)
(require 'limen-herd)
(require 'limen-model)
(require 'limen-usage)
(limen-trail-mode 1)
(limen-herdr-mode 1)
(limen-hooks-mode 1)
(limen-inbox-mode 1)
(limen-herd-mode 1)
(limen-model-mode 1)
(limen-usage-mode 1)
```

Each hook-based mode asks for the hook events it needs. Modes turned on by the same command, or
during startup, share one question per harness.

## Your first session

Start with the command line. Load the core and the trail:

```elisp
(require 'limen)
(require 'limen-trail)
(limen-trail-mode 1)
```

Visit a file in a project, move around, select a region, then run this from a shell in the same
project:

```sh
limen context
```

The answer is one JSON object. Its `result` holds a section per name: `project` with the root,
`focus` with the buffer, point and selection, `windows`, `buffers`, `compilations`, and `trail`
with the buffers you visited. Ask for one piece with `--section`:

```sh
limen context --section focus
```

`limen skill` prints the same list of operations an agent is given, as Markdown. Run it and read
it once; it is the whole agent-facing surface.

Now hand the agent Emacs through Herdr. With herdr.el installed and configured:

```elisp
(require 'limen-herdr)
(require 'limen-hooks)
(limen-herdr-mode 1)
(limen-hooks-mode 1)
```

Answer `y` when Limen asks to install its hooks into `~/.claude/settings.json` and
`~/.codex/hooks.json`. Start a Claude Code agent from `M-x herdr-transient`. Go back to your file,
select a few lines and type a prompt into the agent's terminal. Before the model sees your
prompt, the `UserPromptSubmit` hook adds a block like this one:

~~~text
Emacs context
focus: src/app.py:40:0-41:15
recent: src/models.py:118, README.md:3 (visited before this prompt, newest first)
live: `limen context`; `limen --help` lists every command

```
def handler(event):
    return evnt
```
~~~

The next prompt without a change of place carries a single line saying the context stands. The
agent can always ask for more with `limen context` and the other commands, which run against the
same Emacs.

## The command line

`bin/limen` is a POSIX shell script. It encodes the request, sends it to Emacs with
`emacsclient --eval`, and prints the answer. `EMACSCLIENT` names another client binary.

Every call runs against the project of the working directory: Projectile's root when Projectile
is installed, otherwise `project.el`'s, otherwise the directory itself. An agent working in a
project therefore sees that project and nothing else.

Every answer is one JSON envelope:

```json
{"version": 1, "ok": true, "operation": "buffer.read", "result": {...}}
{"version": 1, "ok": false, "operation": "buffer.save", "error": {"code": "conflict", "message": "..."}}
```

The exit status tells the error class apart, so a script can branch on it; the table is in
[Exit status](REFERENCE.md#exit-status). `limen help COMMAND` prints the arguments of any
command, and `limen` alone prints the index.

`limen skill` generates agent instructions from the live registry: each enabled CLI operation,
its command line, whether it reads or writes, and what it does. A disabled operation, such as
`trail.list` while `limen-trail-mode` is off, is left out.

`limen eval` evaluates Emacs Lisp, and refuses unless `limen-enable-elisp-eval` is non-nil. It is
never offered over MCP, and `limen skill` lists it only while it is enabled. The switch guards against accidental use: any process that
can reach your Emacs server can evaluate Lisp regardless.

## What an agent can see

Every operation that names a file resolves it to a canonical local path and refuses it unless it
lies below the request's project root. Symlinks are followed before the check, and remote paths
are refused. `limen-project-path-deny-regexps` hides more: each regexp is matched against the
project-relative path, and a match makes the file invisible to every operation, to focus, and to
context sends.

A *virtual buffer* is one that visits no file, such as `*compilation*` or a Magit status. Its
name and mode are listed, but its text and positions stay hidden unless
`limen-readable-virtual-buffer-condition` allows it. The condition takes the forms
`buffer-match-p` understands: a regexp on the name, `(major-mode . MODE)`,
`(derived-mode . MODE)`, a predicate, and `and`, `or` and `not` over those. `t` allows every
virtual buffer of the project. An invalid condition denies access. Emacs's internal buffers, those
whose name starts with a space, are never shown.

`limen-confine-to-project`, on by default, keeps focus, the window list and the trail inside the
requested project: a buffer of another project answers as if nothing were there. Turn it off and
each buffer answers against its own project, which its record names in a `project` field, under
that project's deny patterns.

Focus is the selected window, with one exception. When you type into an agent's terminal, the
selected window shows the terminal, and the place you mean is the buffer you came from. A window
whose major mode derives from one of `limen-focus-terminal-modes` is therefore skipped in favour
of the window used most recently before it.

## Buffers

`limen buffer list` lists the project's file buffers; `--virtual` lists the virtual ones and
`--all` both. Each record carries the name, file, kind, major mode, modified flag, modification
tick and narrowing.

`limen buffer read` returns the live text, including unsaved edits, by path or by `--name`.
`--line` and `--end-line` cut a range, and `--widen` reads past narrowing. The answer carries the
buffer's modification tick; pass it back as `--expected-tick` on a later read and a changed buffer
answers with a conflict instead of text.

`limen buffer save PATH --expected-tick TICK` saves a buffer only when its tick still matches and
the file on disk has not changed underneath it. Anything else is a `conflict` (exit status 6):
Limen never prompts and never overwrites silently.

`limen buffer open PATH` visits a file and shows it in the window already showing it, or in the
selected one. `--line`, `--column` and `--end-line`, or `--start-text` and `--end-text`, place
point and the region.

## Context in one call

`context.get`, which is `limen context`, gathers the sections an agent usually wants:

| Section | From | Holds |
| --- | --- | --- |
| `project` | `limen` | the root |
| `focus` | `limen` | the focused buffer, point, selection, viewport and invisible spans |
| `windows` | `limen` | the file windows of the selected frame |
| `buffers` | `limen` | file and virtual buffers |
| `compilations` | `limen-compile` | compilation buffers and their status |
| `trail` | `limen-trail` | the buffer trail, while `limen-trail-mode` is on |
| `annotations` | `limen-scholia` | the visible annotation sessions, while any is visible |

A section with nothing to say is left out. `--section NAME`, repeated, selects a subset; an
unknown name is an error. Focus reads cached window state and never forces a redisplay. A
virtual buffer that is not readable answers with its name and `redacted: true`.

## The buffer trail

`limen-trail-mode` keeps a list of the buffers you visited, newest first, at most
`limen-trail-buffer-limit` of them. For each it records the places you settled: after
`limen-trail-idle-delay` seconds of idle time point is sampled, and a move of fewer than
`limen-trail-point-distance` lines updates the latest place instead of adding one. An entry keeps
at most `limen-trail-point-limit` places.

Killing a file buffer keeps its entry, frozen to line and column and marked `live: false`, and
visiting the file again resumes it. Virtual entries go with their buffer. Turning the mode off
clears the trail, and so does `M-x limen-trail-clear`.

The trail feeds `limen trail`, the `trail` section of `limen context`, and the `recent:` line of a
[context block](#prompt-hooks). The mode costs no work per command.

## Diagnostics and compilations

`limen diagnostics` merges the Flymake diagnostics already computed with Flycheck's, when
Flycheck is loaded. It never starts a check. `--uri` narrows the list to one file. Lines are
one-based and columns zero-based.

`limen compile list` reports the project's existing `compilation-mode` buffers: name, directory,
status (`running`, `succeeded`, `failed`, `stopped` or `unknown`), exit code, and error, warning
and info counts. A buffer that finished before `limen-compile` loaded reports `unknown`.
`limen compile read BUFFER` returns the last 64 KiB of its output without text properties. Limen
never starts, waits for, or feeds a compilation.

## Annotations

With [scholia](https://github.com/srnnkls/scholia) installed, `limen-scholia` exposes annotation
sessions to agents:

```elisp
(require 'limen-scholia)
```

`limen annotations sessions` lists the sessions, whether each is active, whether it is the global
or project write target, and how many of its files lie in the project. `limen annotations list`
lists the annotations of the sessions visible in the current buffer, or of `--session NAME`,
narrowed by `--path` and capped by `--limit`. `limen annotations export --session NAME` renders a
session through scholia's own formatters, `rustc` by default, or `diff` or `integrate` with
`--format`.

While a session is visible, `limen context` gains an `annotations` section, and a context sent to
an agent carries a line such as ``annotations: review (3), perf — `limen annotations list` ``, so
the agent learns the annotations exist without receiving them.

## Diffs

An agent on MCP can propose an edit as an Ediff session instead of writing the file. This is off
by default; turn it on with:

```elisp
(require 'limen-editor)
(setq limen-editor-enable-diffs t)
```

`diff.open` opens Ediff between the file's buffer and a buffer holding the proposed text, and the
agent's tool call stays open until you finish. Take the hunks you want into the file's buffer with
Ediff; quitting Ediff or killing the proposal buffer ends the call with the outcome `closed`. With
`expected_tick`, the diff opens only while the file's buffer still has that modification tick. `diff.close` and `diff.close-all` let the agent
withdraw its diffs. A diff keeps the agent waiting on Emacs, which is why the operations stay
hidden until you enable them; [edit review](#edit-review) shows edits after they land instead.

## MCP

`limen-mcp` serves sessions over MCP Streamable HTTP on `127.0.0.1`, on a port the system picks.
Each session gets its own route, `http://127.0.0.1:PORT/mcp/ROUTE`, and a bearer token.

Tools are the operations offered on MCP, with dots turned into underscores: `buffer_read`,
`context_get`, `diff_open`. A disabled operation is not listed, and the client is told when the
list changes. The two events are resources, `emacs://context/selection` and
`emacs://context/push`, and a subscribed client is notified when either changes. Selection events
go only to sessions whose project holds the file you are in.

Under Herdr, Codex and Pi get their route when they launch; see
[docs/integrations.md](docs/integrations.md#transports). Any other MCP client can be served from
Lisp:

```elisp
(require 'limen-editor)
(require 'limen-compile)
(require 'limen-mcp)

(let* ((session (limen-open-session :provider 'my-client
                                    :project-root "~/src/app"))
       (route (limen-mcp-register-session session)))
  (list (limen-mcp-endpoint route) (limen-mcp-route-token route)))
```

`limen-mcp-unregister-session` closes the route and the session. The server stops when its last
route goes. Request bodies are capped at `limen-mcp-max-request-bytes`.

The loopback address, the unguessable route and token, and project confinement keep one session
out of another's way. They are not a sandbox: any process running as you can reach your Emacs
server already.

## Agents under Herdr

[herdr.el](https://github.com/srnnkls/herdr.el) runs agents in persistent terminal workspaces.
`limen-herdr-mode` plugs Limen into its agent lifecycle for Claude Code, Codex, Pi and Oh My Pi:

```elisp
(require 'limen-herdr)
(limen-herdr-mode 1)
```

When Herdr starts an agent, Limen opens a session rooted at the agent's project and bound to its
pane, and puts `LIMEN_SESSION` and `LIMEN_PROVIDER` into the pane's environment. Codex, Pi and
Oh My Pi also get an MCP route: Codex through `-c mcp_servers.limen...` arguments, Pi and Oh My Pi
through `LIMEN_MCP_URL`, `LIMEN_MCP_TOKEN` and `LIMEN_MCP_SESSION`. Nothing in your global harness
configuration changes. Detaching or stopping the agent closes the session.

`M-x limen-herdr-transient` is the menu for this:

```text
Integration   p push context   s status   h install hooks
Claude Code   a adopt          m auto-adopt
```

`s` shows an agent's integration status: provider, `connected`, `disconnected` or `cli-only`, the
transport and, with an MCP route, its endpoint.

### Adoption and attachment

An agent Herdr runs but Emacs did not launch, such as one started before Emacs or from Herdr's own
terminal, has no session and gets no context. *Adoption* gives it one. `M-x
limen-herdr-claude-adopt`, or `a` in the menu, adopts a Claude Code agent you pick.
`limen-herdr-claude-auto-adopt-mode`, `m` in the menu, adopts every Claude Code agent that runs on
a Herdr session Emacs is attached to and works in a known project, both those running now and
those that appear later. `limen-herdr-claude-auto-adopt-predicate` replaces that test.

Automatic adoptions happen one at a time, in idle moments `limen-herdr-claude-adopt-interval`
seconds apart, and open no terminal; `limen-herdr-claude-adopt-quietly` and
`limen-herdr-claude-adopt-attach` change that.

*Attachment* is Emacs showing an adopted agent's terminal. An adopted agent answers its hooks
either way, but two features act only for attached agents by default, because they concern the
agent you are looking at: the context block (`limen-hooks-context-attached-only`) and edit review
(`limen-hooks-review-attached-only`). Set one to nil to cover every agent with a session. The
question inbox draws its line one step further out: `limen-inbox-attached-only` keeps it to
agents Emacs holds a session for, attached or not.

## Sending context

`M-x limen-herdr-push-context`, `p` in the menu, sends the place you are at to an agent on
purpose: the region, or the current line without one, or the marked files in Dired. Herdr's own
message and send commands take the same snapshot when the target agent has a Limen session.

The rendered context of a Herdr message looks like this:

~~~text
Emacs context
file: src/app.py:40:0-41:15
mode: python-mode
defun: handler
symbol: evnt
diagnostics: error at 41:11 undefined name 'evnt'
live: `limen context`

```
   ╭─ app.py:41:15 ─
36 │
37 │ @app.route("/")
38 │ def index():
39 │     return render()
40 ┃ def handler(event):
41 ┃     return evnt▏
42 │
43 │ def other():
44 │     pass
45 │
   ╰─
```
~~~

The header names the file and the range, then what only the editor knows: the mode, the enclosing
definition, the symbol at point, and the diagnostics on the sent lines. The excerpt runs from
`limen-herdr-context-lines-before` lines above to `limen-herdr-context-lines-after` lines below,
numbered, with the sent lines marked `┃` and `limen-herdr-context-point-marker` standing where
point is. Set both line counts to 0 and the sent text goes alone in a fenced block.

A file outside the agent's project is sent with its absolute path, since sending it is your
choice; a file the project's deny patterns match is refused. A buffer that visits no file sends
its name, mode and text. Dired sends a `files:` list of at most `limen-herdr-context-item-limit`
files, and a directory, symlink, unreadable or out-of-project file among the marks refuses the
whole send. Paths inside the project are relative to the agent's working directory.

Where the context goes depends on the agent. A harness with Limen's hooks installed receives it
on its next prompt, when `limen-hooks-mode` is on. Otherwise an agent with an MCP route receives
a `context.push` event, and any other agent has the text typed into its terminal. A plain Herdr
message to an agent with hooks carries only your text; the context rides on the hook.

## Prompt hooks

`limen-hooks-mode` makes every prompt you type into an agent's terminal carry Emacs context,
without touching the prompt text:

```elisp
(require 'limen-hooks)
(limen-hooks-mode 1)
```

The hooks live in the harness's own settings: `$CLAUDE_CONFIG_DIR/settings.json` (default
`~/.claude/settings.json`) for Claude Code and `$CODEX_HOME/hooks.json` (default
`~/.codex/hooks.json`) for Codex. Enabling the mode asks once per harness whose settings lack an
event it needs, and installs `limen hook claude` or `limen hook codex` beside your other handlers.
`M-x limen-hooks-install` and `M-x limen-hooks-uninstall` do the same by hand; uninstalling removes
Limen's entries alone. The command installed is `limen-hooks-command` when set, otherwise the
`limen` on `exec-path`, otherwise the package's `bin/limen`.

`limen hook` does nothing unless the pane was set up by Herdr (`HERDR_ENV=1`) or launched by Limen
(`LIMEN_SESSION`). It gives up after `LIMEN_HOOK_TIMEOUT` seconds, 3 by default, when Emacs is
busy or absent, and it exits 0 without output on any failure, so a prompt is never blocked.

Two events carry context:

- `SessionStart` adds the output of `limen skill`, so the agent learns the commands on every
  start, `/clear` and compaction.
- `UserPromptSubmit` adds the context block: a context you sent, if one is pending, the extra
  header lines of other modules, a `focus:` line with the file and selected range, a `recent:`
  line with up to `limen-hooks-recent-limit` trail entries, the `live:` pointer, and the selected
  text, cut at `limen-hooks-selection-limit` characters. Text from subscribed features, such as
  held [herd notices](#herd-notices), follows the block.

The block shrinks when little changed. A prompt whose block equals the last one carries a single
line saying so. One whose block differs only in some header lines carries those lines and names
the ones that stand. After `limen-hooks-context-repeat` shortened prompts the whole block goes
again, and a context you sent always goes whole.

The hook finds its session by `LIMEN_SESSION`, then by the Herdr server and pane it ran in. A pane
Emacs never adopted gets nothing, unless `limen-hooks-answer-unattached` is set: then the open
session rooted at the hook's working directory answers for it.

## Edit review

With `limen-hooks-review-edits` on, an agent's edit to a project file opens its diff in Emacs as
soon as the edit lands:

```elisp
(setopt limen-hooks-review-edits t)
```

Set it with `setopt` or Customize: its setter subscribes the review event while
`limen-hooks-mode` is on. A plain `setq` takes effect only when the mode is next enabled.

Limen subscribes `PostToolUse` for the edit tools of every harness: `Edit`, `Write` and
`MultiEdit` for Claude Code, `edit` and `write` for Pi and Oh My Pi. The diff is
`limen-hooks-review-function`, by default a Magit diff of the repository's unstaged changes, so an
agent's edits add up in one buffer; without Magit it is `vc-diff`. It opens per
`limen-hooks-review-display-action`, in a left side window by default, and never takes the
selection. The agent does not wait for it. Codex names no edit tool yet, so its edits are not
reviewed.

## The question inbox

`limen-inbox-mode` lists the questions agents are waiting on in an `Inbox` section at the top of
`herdr-status`:

```elisp
(require 'limen-inbox)
(limen-inbox-mode 1)
```

Claude Code's `AskUserQuestion` enters through `PreToolUse` and leaves through the matching
`PostToolUse`, the agent's next prompt, the end of its turn or session, or the agent's pane
closing. Codex asks through `request_user_input_async`, which fires no tool hook, so the inbox reads
the question from the transcript when the turn ends; the next prompt clears it, and an entry older
than `limen-inbox-settle-seconds` goes once Herdr no longer reports the agent as blocked.

Each asking agent is a dashboard row, so the dashboard's agent keys act on it, and below it come
its questions, flags and options. By default the inbox only shows them, and you answer in the
agent's terminal. With `limen-inbox-answer` set, the options become lines you answer from the
dashboard:

| Key | On | Does |
| --- | --- | --- |
| `1` … `9` | a question | toggle that option |
| `RET` | an option | toggle it |
| `RET` | a question | open the agent without answering |
| `C-c C-c` | a question | commit its answer and move to the next question |
| `C-c C-d`, `C-c C-k` | a question | choose "Chat about this" and open the agent |
| `n` | a question with previews | edit a note for the option at point |

Answers stay local until you commit, and submitting the whole set asks for confirmation. Keys go
to the terminal one at a time, `limen-inbox-key-delay` seconds apart. With
`limen-inbox-answer-submit-eagerly`, any commit offers to submit once every question has a
committed answer. `limen-inbox-inline-notes` edits notes in a cera field instead of the
minibuffer. `M-x limen-inbox-clear` forgets every pending question.

## Herd notices

A *herd* in herdr.el is a named group of agents that know about each other. `limen-herd-mode`
tells each member what the others do:

```elisp
(require 'limen-herd)
(limen-herd-mode 1)
```

There are four kinds of notice: `online` (a member came up), `prompt` (it started a turn),
`finished` (it ended one) and `exited`. A member receives nothing until it subscribes. Press `n`
on an agent in `herdr-status`, or in Herdr's herd menu, to open `limen-herd-dispatch`: `o`, `p`,
`f` and `x` toggle a kind for the agents at point or in the region; `a`, `n` and `d` set all,
none, or `limen-herd-default-events`; `A`, `N` and `D` do the same for the whole herd at point.
The choice is stored in the pane label as `notify:KIND,...` next to `herd:NAME`, so it survives
restarts, and an agent can read or change its own with `herdr pane list` and
`herdr pane rename`.

Notices come from Herdr's agent states, so every harness Herdr detects takes part. A member whose
hooks reach Emacs reports the same turns with more detail: a `prompt` notice repeats the first
`limen-herd-prompt-length` characters of the prompt, and a `finished` notice the first
`limen-herd-excerpt-length` characters of the answer. A state change waits
`limen-herd-fallback-delay` seconds for such a hook before it becomes the notice itself.

A member in the middle of a turn is never interrupted. Its notices wait and reach it with its next
prompt, as hook context, or as soon as Herdr sees it idle; with `limen-herd-hold-for-busy` nil they
are dropped. Notices never answer notices: a turn started by a prompt that opens with one of
`limen-herd-quiet-prefixes` ends without a `finished` notice.

## Model and context columns

`limen-model-mode` and `limen-usage-mode` fill the model and context columns of `herdr-status`:

```elisp
(require 'limen-model)
(require 'limen-usage)
(limen-model-mode 1)
(limen-usage-mode 1)
```

The model arrives on the session start and on model switches, and the end of a turn reads it and
the reasoning effort from the transcript. `limen-model-prefer` picks the display name or the
identifier. The context figure is what the next request re-sends against the model's window;
`limen-usage-limits` maps model names to windows, `limen-usage-limit` covers the rest, and a count
beyond the window read from the model moves it to the next of `limen-usage-windows`.

Both report as Herdr pane metadata under the token names the dashboard reads, so the columns
follow whatever `herdr-status-model-token` and `herdr-status-context-token` say. Agents that
started before the mode was on get their figures with `M-x limen-model-backfill` and
`M-x limen-usage-backfill`.

## Live memex transcripts

`limen-memex-live-mode` keeps a [memex.el](https://github.com/srnnkls/memex.el) transcript
current while its agent works:

```elisp
(require 'limen-memex)
(limen-memex-live-mode 1)
```

After each prompt, tool call, finished turn and session end, every `memex-session-mode` buffer
showing that conversation is redrawn once the events pause for `limen-memex-live-delay` seconds,
keeping its filters and each window's place. With `limen-memex-live-visible-only`, only views in
a visible window are redrawn. `limen-memex-live-events` picks the events.

## The message field

herdr.el can write a message to an agent in a cera field directly under the region or line it is
about (`herdr-message-read-function` set to `herdr-message-read-field`). `limen-herdr-mode` adds
optional panes around that field, all off by default:

```elisp
(setq limen-message-context t   ; the agent's latest reply above the field
      limen-message-status t    ; model, effort and context window below it
      limen-message-summary t)  ; a one-line recap of the conversation
```

`limen-message-context` shows the agent's latest message, read from its memex session and drawn
as Markdown when lectio is installed. `limen-message-status` adds a line with the model, effort
and context window, and the agent's workspace when it is not yours. `limen-message-summary` asks
a CLI for a recap of up to five recent turns: the commands in `limen-message-backends` are tried
in order, Codex with `limen-message-codex-model` and Claude with `limen-message-claude-model`. The
recap sends conversation text to that model, and may cost API usage; tools, reasoning and your
draft are not sent.

While the field is open:

| Key | Does |
| --- | --- |
| `M-p`, `M-n` | show the agent's previous or next message |
| `C-c C-n` | show more messages at once, cycling `limen-message-message-counts` |
| `C-c C-u` | show your prompts beside the agent's answers |
| `C-c C-v` | show the whole message, or its preview |
| `C-p`, `up` / `C-n`, `down` | on the first or last input line, walk back through messages you sent |
| `C-c C-t` | open the agent's memex transcript beside the buffer |
| `C-c RET` | switch the agent's model |
| `C-c C-e` | set the agent's reasoning effort |

The model and effort pickers read their choices from `limen-message-models`, one entry per
provider:

```elisp
(setq limen-message-models
      '((claude :models ("opus" "sonnet" "haiku") :command "/model %s"
                :efforts ("low" "medium" "high") :effort "/effort %s")))
```

`:command` and `:effort` are a format string for the prompt that makes the change, or a function
called with the agent's target and the choice. For Codex, which takes no model by name, set
`:command` to `limen-message-codex-model`: it drives Codex's `/model` menu and asks for the
reasoning level the menu offers. Opening a field while another is open puts the first away and
keeps its draft for the next time you write to that agent.

## Completion in the field

`limen-complete-mode` completes inside a cera field: the message field, and the inbox note field.

```elisp
(require 'limen-complete)
(limen-complete-mode 1)
```

- `@` completes a project file.
- `#` completes an annotation of the visible scholia sessions, as `file:line`.
- `/` completes a skill of the harness the message goes to, with its description. Codex lists its
  own skills through `codex debug prompt-input`; for Claude Code, Pi and Oh My Pi the skill
  directories under the configuration directory and the project are read, the project's skill
  winning a shared name. A skill for Codex lands as `$name` and one for Pi as `/skill:name`.

Text that opens none of the three completes on what the field offers, for a message the messages
sent before. Skills are asked for once Emacs is first idle, so the first completion does not wait;
`M-x limen-complete-forget` drops the cached files and skills. `limen-complete-sources` maps the
opening characters to their functions.

## Pi and Oh My Pi

Pi and Oh My Pi load extensions, not settings-file hooks. `mise run install-extensions` links both
of Limen's into `~/.pi/agent/extensions` and `~/.omp/agent/extensions` (`PI_HOME` and `OMP_HOME`
move those):

- `limen-hooks` translates the harness's events into Limen's hook events and runs `limen hook`,
  so context, the herd, the dashboard columns and edit review work as they do for Claude Code.
- `limen-mcp` connects to the MCP route in `LIMEN_MCP_URL`, mirrors every tool as `limen_<tool>`,
  injects the latest selection once before the next turn, and delivers an explicit push as a
  message.

An adopted Pi pane has hooks but no MCP route, since the route exists only for a pane Limen
launched. [docs/integrations.md](docs/integrations.md#pi-and-oh-my-pi) has the details.

## Extending Limen

An operation is a function of its arguments and the request:

```elisp
(limen-register-operation
 "note.count" (lambda (_arguments request)
                (length (directory-files (limen-request-project-root request) nil "\\.org\\'")))
 :description "Count the Org files at the project root."
 :effect 'read
 :interfaces '(mcp))
```

`:parameters` declares arguments as plists with `:name`, `:type`, `:required`, `:description`,
`:enum`, `:items` and `:properties`; calls are validated against them and MCP clients see them as
the tool's input schema. `:enabled-p` hides the operation while it returns nil, and `:deferred`
marks one that answers later through `limen-request-resolve` or `limen-request-reject`.
`bin/limen` has subcommands for the built-in CLI operations only, so an operation of your own
reaches agents through MCP; `:command` names its CLI form in `limen skill` for when a
subcommand exists.

`limen-context-sections` maps section names to functions of the request, and adding an entry
adds a section to `context.get`. `limen-herdr-context-fields-functions` adds header lines to sent
context and context blocks. A feature that reacts to hook events subscribes with
`limen-hooks-subscribe`; [docs/hook-payload.md](docs/hook-payload.md) describes the events and
the call.

## When something looks wrong

Start at the command line and work outwards:

1. `limen focus` from the project: does Emacs answer at all? Exit status 4 means `emacsclient`
   could not reach the server.
2. `limen context`: is the file inside the project root the answer names, and not matched by
   `limen-project-path-deny-regexps`? A virtual buffer answers with `redacted: true` unless
   `limen-readable-virtual-buffer-condition` allows it.
3. `limen skill`: is the operation you expect listed? A missing one is disabled — `trail.list`
   needs `limen-trail-mode`, the diff operations need `limen-editor-enable-diffs`, `annotation.*`
   needs scholia, `elisp.eval` needs `limen-enable-elisp-eval`.
4. `s` in `M-x limen-herdr-transient`: does the agent have a session? `unavailable` means
   it was neither launched with `limen-herdr-mode` on nor adopted; `cli-only` means it was adopted
   without a session.
5. The harness settings: does `settings.json` or `hooks.json` hold `limen hook`? Run
   `M-x limen-hooks-install` for that harness.
6. The hook itself: pipe a payload into it from the agent's pane,
   `echo '{"hook_event_name":"UserPromptSubmit","prompt":"x"}' | limen hook claude`, and see
   whether a context block comes back. No output means the pane lacks `LIMEN_SESSION` and
   `HERDR_ENV`, Emacs took longer than `LIMEN_HOOK_TIMEOUT`, or no session answers for the pane.
7. An attached-only option: the context block and edit review skip agents whose terminal Emacs
   does not show, and the inbox skips agents Emacs holds no session for.

## Where to look next

- [REFERENCE.md](REFERENCE.md) lists every command, option, face, hook, MCP tool and CLI flag.
- [docs/integrations.md](docs/integrations.md) compares the harnesses and describes each
  transport.
- [docs/hook-payload.md](docs/hook-payload.md) specifies the hook events for feature authors.
- The ERT suites (`limen*-tests.el`) show every operation's behaviour, one test per case.
