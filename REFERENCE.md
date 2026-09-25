# Limen reference

Every Emacs command, key, user option, face and hook, every operation and MCP tool, and every
`limen` command. For the model behind them, read [GUIDE.md](GUIDE.md); for what each harness
supports, read [docs/integrations.md](docs/integrations.md).

## Contents

- [Modes](#modes)
- [Emacs commands, options and faces](#emacs-commands-options-and-faces), by module
- [Operations and MCP tools](#operations-and-mcp-tools)
- [Events and MCP resources](#events-and-mcp-resources)
- [The limen command](#the-limen-command)
- [Environment](#environment)
- [Files](#files)
- [Exit status](#exit-status)

## Modes

Every mode is global. Limen binds no global key.

| Mode | Module | Does |
| --- | --- | --- |
| `limen-trail-mode` | `limen-trail` | track visited buffers and settled points |
| `limen-herdr-mode` | `limen-herdr` | wire Herdr agents into Limen; turns on the message-field extension |
| `limen-herdr-claude-auto-adopt-mode` | `limen-herdr-claude` | adopt Claude Code agents Herdr detects; turns on `limen-herdr-mode` |
| `limen-hooks-mode` | `limen-hooks` | carry Emacs context on every prompt; subscribes `context`, and `review` under `limen-hooks-review-edits` |
| `limen-inbox-mode` | `limen-inbox` | list pending questions in `herdr-status`; subscribes `inbox` |
| `limen-herd-mode` | `limen-herd` | send herd notices; subscribes `herd`, binds `n` in `herdr-status` |
| `limen-model-mode` | `limen-model` | report each agent's model to Herdr; subscribes `model` |
| `limen-usage-mode` | `limen-usage` | report each agent's context use to Herdr; subscribes `context window` |
| `limen-memex-live-mode` | `limen-memex` | redraw memex transcripts as agents work; subscribes `memex` |
| `limen-complete-mode` | `limen-complete` | `@`, `#` and `/` completion in cera fields |

A mode that subscribes to hook events asks, once per harness whose settings lack them, whether
to install them; see [docs/hook-payload.md](docs/hook-payload.md#subscribing).

## Emacs commands, options and faces

Options are listed as name, type, default. `M-x customize-group RET limen` reaches them all.

### limen.el

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `limen-enable-elisp-eval` | boolean | `nil` | allow `elisp.eval`; it is hidden and refused otherwise |
| `limen-readable-virtual-buffer-condition` | `buffer-match-p` condition | `nil` | project virtual buffers whose text and positions are readable; `t` allows all, nil or an invalid condition denies |
| `limen-confine-to-project` | boolean | `t` | keep focus, windows and the trail inside the requested project; nil answers each buffer against its own project |
| `limen-focus-terminal-modes` | list of symbols | `(ghostel-mode vterm-mode eat-mode term-mode)` | terminal modes focus looks past, to the window used before |
| `limen-project-path-deny-regexps` | list of regexps | `nil` | project-relative paths hidden from every operation |
| `limen-focus-invisible-span-limit` | integer ≥ 0 | `100` | invisible spans `focus.get` returns at most |

| Variable | Meaning |
| --- | --- |
| `limen-context-sections` | alist of `context.get` section names to functions of the request; a function returning nil omits its section |

| Hook | Called with |
| --- | --- |
| `limen-operation-change-hook` | `registered` or `unregistered`, and the operation name |
| `limen-session-open-hook` | the session, after it is registered |
| `limen-session-close-hook` | the session, before its resources are released |

Lisp interface: `limen-register-operation`, `limen-unregister-operation`, `limen-register-event`,
`limen-unregister-event`, `limen-operations`, `limen-events`, `limen-call`, `limen-open-session`,
`limen-close-session`, `limen-find-session`, `limen-find-session-at`, `limen-session-subscribe`,
`limen-session-unsubscribe`, `limen-session-publish`, `limen-make-request`,
`limen-request-resolve`, `limen-request-reject`, `limen-request-cancel`, `limen-project-path`,
`limen-project-file-p`, `limen-skill`. Their docstrings describe the arguments.

### limen-editor.el

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `limen-editor-enable-diffs` | boolean | `nil` | offer `diff.open`, `diff.close` and `diff.close-all` |

### limen-compile.el

No commands or options. Loading it registers `compile.list`, `compile.read` and the
`compilations` section of `context.get`.

### limen-trail.el

| Command | Does |
| --- | --- |
| `limen-trail-mode` | toggle the trail; turning it off clears it |
| `limen-trail-clear` | forget every trail entry |

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `limen-trail-buffer-limit` | integer ≥ 1 | `32` | buffers kept |
| `limen-trail-point-limit` | integer ≥ 1 | `8` | settled points kept per buffer |
| `limen-trail-idle-delay` | number | `0.5` | idle seconds before point is sampled |
| `limen-trail-point-distance` | integer ≥ 0 | `5` | lines a move must span to add a point instead of updating the latest |

### limen-mcp.el

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `limen-mcp-max-request-bytes` | integer | `1048576` | bytes buffered from one HTTP client at most |

Lisp interface: `limen-mcp-register-session` returns a route for an open session,
`limen-mcp-endpoint` its URL, `limen-mcp-route-token` its bearer token,
`limen-mcp-unregister-session` closes route and session, and `limen-mcp-state` reports the
listener's host, port and session count.

### limen-scholia.el

No commands or options. Loading it registers the `annotation.*` operations, the `annotations`
section of `context.get`, and the `annotations:` line of sent context. Loading it tries to load
scholia; when that fails, the operations stay disabled until `limen-scholia` is loaded again.

### limen-herdr.el

| Command | Does |
| --- | --- |
| `limen-herdr-mode` | register Limen's adapter for `claude`, `codex`, `pi` and `omp` agents and the context provider for Herdr's sends |
| `limen-herdr-push-context` | send the region, current line or marked Dired files to the agent Herdr resolves |

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `limen-herdr-context-item-limit` | integer ≥ 1 | `100` | files one Dired send carries at most |
| `limen-herdr-context-point-marker` | string | `"▏"` | text drawn where point is in a sent excerpt; empty draws nothing |
| `limen-herdr-context-lines-before` | natural number | `4` | excerpt lines above the sent text |
| `limen-herdr-context-lines-after` | natural number | `4` | excerpt lines below the sent text; with both 0 the text is sent alone |

| Hook | Called with | Returns |
| --- | --- | --- |
| `limen-herdr-context-fields-functions` | the context alist and the session root | a list of `"key: value"` header lines, or nil |
| `limen-herdr-context-hook` | the session, the context, the root and the rendered text, after a Herdr send renders it | ignored |
| `limen-herdr-push-functions` | the session, the context and the root, before a push is typed into the pane | non-nil when it delivered the push |

Lisp interface: `limen-herdr-status`, `limen-herdr-session-for`, `limen-herdr-agent-session`,
`limen-herdr-attached-p`, `limen-herdr-agents`, `limen-herdr-detach`.

### limen-herdr-claude.el

| Command | Does |
| --- | --- |
| `limen-herdr-claude-adopt` | read a Claude Code agent from the current Herdr server and adopt it, opening its terminal |
| `limen-herdr-claude-auto-adopt-mode` | adopt every Claude Code agent the predicate accepts, now and as they appear |

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `limen-herdr-claude-auto-adopt-predicate` | function | `limen-herdr-claude-adoptable-p` | accepts an agent on a Herdr session Emacs is attached to, working in a known project |
| `limen-herdr-claude-adopt-quietly` | boolean | `t` | adopt out of sight, one agent per idle moment; nil adopts at once |
| `limen-herdr-claude-adopt-interval` | number | `0.3` | idle seconds between two queued adoptions |
| `limen-herdr-claude-adopt-attach` | boolean | `nil` | open the terminal of an automatically adopted agent |

### limen-herdr-transient.el

`M-x limen-herdr-transient`:

| Key | Command | Does |
| --- | --- | --- |
| `p` | push context | `limen-herdr-push-context` to an agent read from the current server |
| `s` | status | show an agent's integration status |
| `h` | install hooks | `limen-hooks-install` |
| `a` | adopt | `limen-herdr-claude-adopt` |
| `m` | auto-adopt | toggle `limen-herdr-claude-auto-adopt-mode` |

The status names the provider, the availability (`connected`, `disconnected`, `cli-only` or
`unavailable`), the transport, the context capabilities, whether diffs are offered, and the MCP
endpoint when there is one.

### limen-hooks.el

| Command | Does |
| --- | --- |
| `limen-hooks-mode` | subscribe the context events, and the edit review event under `limen-hooks-review-edits` |
| `limen-hooks-install` | read a harness (`claude` or `codex`) and add the hooks every subscription needs to its settings |
| `limen-hooks-uninstall` | read a harness and remove Limen's hooks from its settings |

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `limen-hooks-command` | string or nil | `nil` | command the installed hooks run, without `hook PROVIDER`; nil finds `limen` on `exec-path`, then the package's `bin/limen` |
| `limen-hooks-recent-limit` | integer ≥ 0 | `5` | trail entries on the `recent:` line |
| `limen-hooks-context-repeat` | natural number | `5` | shortened prompts before the whole block is repeated; 0 never repeats on its own |
| `limen-hooks-answer-unattached` | boolean | `nil` | answer a pane Emacs holds no session for, with the session of its working directory's project |
| `limen-hooks-selection-limit` | integer ≥ 0 | `2000` | characters of selected text a prompt carries |
| `limen-hooks-review-edits` | boolean | `nil` | open the diff of a project file an agent edited |
| `limen-hooks-review-attached-only` | boolean | `t` | review only agents whose terminal Emacs shows |
| `limen-hooks-context-attached-only` | boolean | `t` | add the context block only for agents whose terminal Emacs shows |
| `limen-hooks-review-function` | function | `limen-hooks-review-with-magit` | called with the absolute path of the edited file |
| `limen-hooks-review-display-action` | `display-buffer` action | left side window, 0.45 wide, reusing a window, not the selected one | where the review diff appears |

| Hook | Called with | Returns |
| --- | --- | --- |
| `limen-hooks-event-functions` | the provider, the payload with `server` and `pane`, the session or nil, and the request | for `UserPromptSubmit`, a string added after the context block |

Join `limen-hooks-event-functions` through `limen-hooks-subscribe`, which also installs the events.

| Constant or function | Value |
| --- | --- |
| `limen-hooks-event-names` | `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `PostModelSwitch`, `SessionEnd` |
| `limen-hooks-providers` | harnesses whose hooks Limen answers: `claude`, `codex`, `pi`, `omp` |
| `limen-hooks-installing-providers` | harnesses whose settings Limen writes: `claude`, `codex` |
| `limen-hooks-events` | the `(EVENT . MATCHER)` specs the subscriptions need |

Lisp interface: `limen-hooks-subscribe`, `limen-hooks-unsubscribe`, `limen-hooks-request-install`,
`limen-hooks-install-all`, `limen-hooks-installed-p`, `limen-hooks-settings-file`,
`limen-hooks-agent-for`, `limen-hooks-review-with-magit`.

### limen-inbox.el

| Command | Default key | Does |
| --- | --- | --- |
| `limen-inbox-mode` | | list pending questions in `herdr-status` |
| `limen-inbox-clear` | | forget every pending question |
| `limen-inbox-toggle-index` | `1` … `9` on a question | toggle the option with that number |
| `limen-inbox-toggle-at-point` | `RET` on an option | toggle the option at point |
| `limen-inbox-attach-at-point` | `RET` on a question | open the question's agent without answering |
| `limen-inbox-commit-at-point` | `C-c C-c` on a question | commit the answer and move to the next question; a revisited question sends only what changed |
| `limen-inbox-dismiss-at-point` | `C-c C-d`, `C-c C-k` on a question | choose "Chat about this" and open the agent |
| `limen-inbox-notes-at-point` | `n` on a question with previews | edit a note for the option at point |

The keys act while `limen-inbox-answer` is set. They live in `limen-inbox-question-section-map`
and `limen-inbox-option-section-map`, whose parent is the question map.

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `limen-inbox-attached-only` | boolean | `t` | list only questions of agents Emacs holds a session for |
| `limen-inbox-settle-seconds` | number | `10` | seconds a question read from a transcript stays before its agent must be blocked |
| `limen-inbox-answer` | boolean | `nil` | render options as lines that answer into the agent's pane |
| `limen-inbox-answer-submit-eagerly` | boolean | `nil` | offer to submit once every question has a committed answer |
| `limen-inbox-inline-notes` | boolean | `nil` | edit notes in a cera field instead of the minibuffer |
| `limen-inbox-note-glyph` | list of strings | a Nerd Font note, then `"✎"` | mark of the note field; the first the display can draw wins |
| `limen-inbox-key-delay` | number | `0.05` | seconds between keys sent to an agent pane |

| Face | Default | Used for |
| --- | --- | --- |
| `limen-inbox-note-mark` | blue foreground, else inherits `link` | the mark a closed note field shows |

### limen-herd.el

| Command | Does |
| --- | --- |
| `limen-herd-mode` | send herd notices and bind `n` in `herdr-status` and the herd menu |
| `limen-herd-dispatch` | the notices menu |
| `limen-herd-subscribe-all`, `limen-herd-unsubscribe-all`, `limen-herd-subscribe-defaults` | set the agents at point, in the region, or read, to all, none, or `limen-herd-default-events` |
| `limen-herd-herd-subscribe-all`, `limen-herd-herd-unsubscribe-all`, `limen-herd-herd-subscribe-defaults` | the same for every member of the herd at point |
| `limen-herd-toggle-online`, `limen-herd-toggle-prompt`, `limen-herd-toggle-finished`, `limen-herd-toggle-exited` | toggle one kind |

`limen-herd-dispatch`, on `n` in `herdr-status`, in `herdr-status-dispatch` and in
`herdr-herd-dispatch`:

| Key | Does |
| --- | --- |
| `o`, `p`, `f`, `x` | toggle `online`, `prompt`, `finished`, `exited` |
| `a`, `n`, `d` | subscribe to all, none, or the defaults |
| `A`, `N`, `D` | the same for the whole herd at point |

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `limen-herd-default-events` | set of `online`, `prompt`, `finished`, `exited` | `(finished exited)` | what "defaults" subscribes to |
| `limen-herd-hold-for-busy` | boolean | `t` | hold notices for a member mid-turn; nil drops them |
| `limen-herd-prompt-length` | integer ≥ 0 | `120` | characters of a prompt a notice repeats |
| `limen-herd-excerpt-length` | integer ≥ 0 | `160` | characters of the last answer a `finished` notice repeats; 0 leaves it out |
| `limen-herd-quiet-prefixes` | list of strings | `("[herd " "/herd ")` | prompt openings whose turn ends without a `finished` notice |
| `limen-herd-label-prefix` | string | `"notify:"` | opening of the pane-label word listing subscriptions |
| `limen-herd-fallback-delay` | number | `5` | seconds a Herdr state change waits for a hook to report the same turn |

### limen-model.el

| Command | Does |
| --- | --- |
| `limen-model-mode` | report each agent's model as Herdr pane metadata |
| `limen-model-backfill` | report the model of every agent Herdr knows that carries none yet |

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `limen-model-token` | string or nil | `nil` | metadata token; nil follows `herdr-status-model-token` |
| `limen-model-source` | string | `"limen"` | metadata source |
| `limen-model-prefer` | `display-name` or `id` | `display-name` | which spelling of the model is reported |
| `limen-model-provider-events` | alist of provider to event specs | `PostModelSwitch` and `Stop` for `claude`, `pi`, `omp` | further events a model is read from |

### limen-usage.el

| Command | Does |
| --- | --- |
| `limen-usage-mode` | report each agent's context use as Herdr pane metadata |
| `limen-usage-backfill` | report the context use of every agent Herdr knows that carries none yet, from its transcript |

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `limen-usage-token` | string or nil | `nil` | metadata token; nil follows `herdr-status-context-token` |
| `limen-usage-source` | string | `"limen"` | metadata source |
| `limen-usage-limit` | integer | `200000` | context window of a model no `limen-usage-limits` entry matches |
| `limen-usage-limits` | alist of regexp to integer | `(("\\[1m\\]" . 1000000))` | context windows by model name |
| `limen-usage-windows` | list of integers | `(200000 1000000)` | windows a model may run on, smallest first; a count beyond one moves to the next |
| `limen-usage-provider-events` | alist of provider to event specs | `Stop` for all, plus `PostModelSwitch` for `claude` | events a fresh count follows |

### limen-memex.el

| Command | Does |
| --- | --- |
| `limen-memex-live-mode` | redraw memex views of a conversation as its agent works |

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `limen-memex-live-events` | list of `(EVENT . MATCHER)` | `UserPromptSubmit`, `PostToolUse`, `Stop`, `SessionEnd` | events after which a view is redrawn; read when the mode is enabled |
| `limen-memex-live-delay` | number | `1.0` | seconds without an event before a view is redrawn |
| `limen-memex-live-visible-only` | boolean | `t` | redraw only views in a visible window |

### limen-message.el

`limen-herdr-mode` installs this module's extension of `herdr-message-read-field`. Its panes and
keys appear while `limen-message-context` is set.

| Command | Key in the field | Does |
| --- | --- | --- |
| `limen-message-older` | `M-p` | show the agent's previous message |
| `limen-message-newer` | `M-n` | show the agent's next message |
| `limen-message-cycle-messages` | `C-c C-n` | show the next count of `limen-message-message-counts` |
| `limen-message-toggle-user` | `C-c C-u` | show your prompts beside the answers, or the answers alone |
| `limen-message-toggle` | `C-c C-v` | show the whole message, or its preview |
| `limen-message-history-older` | `C-p`, `up` | on the first input line, write the previously sent message into the field; elsewhere move up |
| `limen-message-history-newer` | `C-n`, `down` | on the last input line, write the next sent message; elsewhere move down |
| `limen-message-transcript` | `C-c C-t` | open the agent's memex transcript beside the buffer |
| `limen-message-pick-model` | `C-c RET` | switch the agent's model to one of `limen-message-models` |
| `limen-message-pick-effort` | `C-c C-e` | set the agent's reasoning effort |

`C-p`, `C-n`, `up` and `down` pass to the completion menu while it is open.

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `limen-message-context` | boolean | `nil` | show the agent's latest message above the field |
| `limen-message-summary` | boolean | `nil` | add a generated recap of up to five turns |
| `limen-message-status` | boolean | `nil` | show model, effort and context window below the field |
| `limen-message-models` | alist of provider to plist | `nil` | `:models`, `:command`, `:efforts`, `:effort` for the pickers |
| `limen-message-backends` | list of `codex`, `claude` | `(codex claude)` | recap commands, tried in order |
| `limen-message-codex-model` | string | `"gpt-5.6-luna"` | model Codex writes the recap with |
| `limen-message-codex-effort` | `"minimal"`, `"low"`, `"medium"` or `"high"` | `"low"` | reasoning Codex spends on the recap |
| `limen-message-claude-model` | string | `"haiku"` | model Claude writes the recap with |
| `limen-message-markdown` | boolean | `t` | render messages as Markdown with lectio |
| `limen-message-messages` | natural number | `8` | agent messages read back for walking |
| `limen-message-page-size` | natural number | `128` | records read per memex page |
| `limen-message-user-messages` | boolean | `nil` | start with your prompts shown beside the answers |
| `limen-message-message-counts` | list of natural numbers | `(1 2 3)` | how many messages the pane shows, in cycle order |
| `limen-message-message-gap` | natural number | `7` | pixels between shown messages |
| `limen-message-history-limit` | natural number | `32` | sent messages kept per agent |
| `limen-message-rule` | string | `"┃"` | rule drawn left of a quoted message |
| `limen-message-rule-offset` | natural number | `2` | pixels the rule stands off the pane's edge |
| `limen-message-headroom` | natural number | `10` | pixels between the context and the input |
| `limen-message-headroom-above` | natural number | `1` | pixels under the blank line that opens the context; 0 drops the line |
| `limen-message-recap-face` | face | `limen-message-recap` | face of the recap line |
| `limen-message-text-face` | face | `limen-message-text` | face of the quoted message |
| `limen-message-rule-face` | face | `limen-message-rule` | face of the rule |

| Face | Default | Used for |
| --- | --- | --- |
| `limen-message-recap` | inherits `default` | the recap line |
| `limen-message-text` | inherits `shadow` | the quoted message |
| `limen-message-rule` | inherits `shadow` | the rule left of a quoted message |
| `limen-message-agent-rule` | orange foreground, else inherits `warning` | the rule beside the agent's messages, while both sides show |
| `limen-message-user-rule` | blue foreground, else inherits `link` | the rule beside your prompts, while both sides show |
| `limen-message-status` | inherits `shadow` | the status line |
| `limen-message-status-icon` | inherits `limen-message-status`, height 0.75 | icons on the status line |

`limen-message-codex-model` is a ready `:command` for Codex: it drives Codex's `/model` menu and
reads the reasoning level offered for the chosen model.

### limen-complete.el

| Command | Does |
| --- | --- |
| `limen-complete-mode` | complete `@` files, `#` annotations and `/` skills in cera fields |
| `limen-complete-forget` | drop the cached project files and skills |
| `limen-complete-warm` | ask every harness for its skills now |

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `limen-complete-file-seconds` | number | `5` | seconds a project's file list is reused |
| `limen-complete-sources` | alist of character to function | `@` `limen-complete-files`, `#` `limen-complete-annotations`, `/` `limen-complete-skills` | completion sources by opening character |

### limen-transcript.el

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `limen-transcript-tail-bytes` | natural number | `262144` | bytes read from the end of a transcript |
| `limen-transcript-readers` | alist of provider to function | one reader per harness | reads the last answer's tokens, window and model |
| `limen-transcript-effort-readers` | alist of provider to function | one reader per harness | reads the last reasoning effort |
| `limen-transcript-files` | alist of provider to function | one finder per harness | finds a session's transcript from its id and directory |

### limen-provider.el

No commands or options. It registers the four harnesses `claude`, `codex`, `pi` and `omp`; the
[capability table](docs/integrations.md#capabilities) shows what each supports.

## Operations and MCP tools

An MCP tool is its operation's name with `.` replaced by `_`. The CLI column names the `limen`
subcommand; a dash means the operation is not offered there.

| Operation | MCP tool | CLI | Effect | Enabled when | Parameters |
| --- | --- | --- | --- | --- | --- |
| `context.get` | `context_get` | `context` | read | always | `sections`: array of strings |
| `focus.get` | `focus_get` | `focus` | read | always | none |
| `window.list` | `window_list` | `windows` | read | always | none |
| `buffer.list` | `buffer_list` | `buffer list` | read | always | `virtual`: boolean, `all`: boolean |
| `buffer.read` | `buffer_read` | `buffer read` | read | always | `path` or `name`: string; `line`, `end_line`, `expected_tick`: integer; `widen`: boolean |
| `buffer.save` | `buffer_save` | `buffer save` | write | always | `path`: string, required; `expected_tick`: integer, required |
| `buffer.open` | `buffer_open` | `buffer open` | write | always | `path`: string, required; `line`, `column`, `end_line`: integer; `start_text`, `end_text`: string |
| `buffer.release` | `buffer_release` | - | write | always | `path`: string, required |
| `diagnostic.list` | `diagnostic_list` | `diagnostics` | read | always | `uri`: string |
| `project.list` | - | `projects` | read | always | none |
| `trail.list` | `trail_list` | `trail` | read | `limen-trail-mode` | `limit`: integer |
| `compile.list` | `compile_list` | `compile list` | read | always | none |
| `compile.read` | `compile_read` | `compile read` | read | always | `name`: string, required |
| `annotation.sessions` | `annotation_sessions` | `annotations sessions` | read | scholia loaded | none |
| `annotation.list` | `annotation_list` | `annotations list` | read | scholia loaded | `session`, `path`: string; `limit`: integer |
| `annotation.export` | `annotation_export` | `annotations export` | read | scholia loaded | `session`: string, required; `path`: string; `format`: `rustc`, `diff` or `integrate` |
| `diff.open` | `diff_open` | - | write, deferred | `limen-editor-enable-diffs` | `old_path`, `new_path`, `contents`, `name`: string, required; `expected_tick`: integer |
| `diff.close` | `diff_close` | - | write | `limen-editor-enable-diffs` | `name`: string, required |
| `diff.close-all` | `diff_close-all` | - | write | `limen-editor-enable-diffs` | none |
| `elisp.eval` | - | `eval` | write | `limen-enable-elisp-eval` | `code`: string, required |

The operations of `limen-trail`, `limen-compile`, `limen-scholia` and `limen-editor` exist once
their module is loaded; the CLI loads the first three itself. Line numbers are one-based, columns
zero-based. Read operations carry the MCP hint
`readOnlyHint: true`. `buffer.release` releases a buffer the requesting session opened with
`buffer.open`. `diff.open` answers when the Ediff session ends; `diff.close` and `diff.close-all`
close the requesting session's diffs.

## Events and MCP resources

| Event | MCP resource | Carries |
| --- | --- | --- |
| `context.selection` | `emacs://context/selection` | the latest selection in a project file: `path`, `line`, `column`, `end_line`, `end_column`, `text`; replayed to new subscribers |
| `context.push` | `emacs://context/push` | an explicit send: the same fields, plus `items`, a list of `{type: "file", path, line, column, end_line, end_column, text}` for several files |

A subscribed MCP client receives `notifications/resources/updated` when either changes, and
`notifications/tools/list_changed` when the operation registry does.

## The limen command

```
limen <COMMAND> [ARGUMENTS]
limen help [COMMAND [SUBCOMMAND]]
```

Every command runs against the project of the working directory and prints one JSON envelope:
`{"version": 1, "ok": true, "operation": ..., "result": ...}` on success,
`{"version": 1, "ok": false, "operation": ..., "error": {"code": ..., "message": ...}}` on
failure. `-h` or `--help` after any command prints its help.

### limen context

```
limen context [--section NAME]...
```

Read `context.get`. `--section` selects `project`, `focus`, `windows`, `buffers`, `compilations`,
`trail` or `annotations`, and repeats.

### limen focus

```
limen focus
```

Read `focus.get`: the focused buffer's record, `point`, `selection`, `viewport`, `invisible_spans`
and `truncated`.

### limen buffer

```
limen buffer list [--virtual | --all]
limen buffer read PATH [--line N] [--end-line N] [--widen] [--expected-tick TICK]
limen buffer read --name NAME [--line N] [--end-line N] [--widen] [--expected-tick TICK]
limen buffer save PATH --expected-tick TICK
limen buffer open PATH [--line N] [--column N] [--end-line N] [--start-text TEXT] [--end-text TEXT]
```

| Subcommand | Operation | Does |
| --- | --- | --- |
| `list` | `buffer.list` | file buffers; `--virtual` the virtual ones, `--all` both |
| `read` | `buffer.read` | live text by path or `--name`; a stale `--expected-tick` is a conflict |
| `save` | `buffer.save` | save when the tick and the file on disk are unchanged |
| `open` | `buffer.open` | visit a file, show it and place point and the region |

### limen trail

```
limen trail [--limit N]
```

Read `trail.list`, newest first. Needs `limen-trail-mode`.

### limen windows

```
limen windows
```

Read `window.list`: each file window's buffer, file, whether it is selected, and its start.

### limen diagnostics

```
limen diagnostics [--uri URI]
```

Read `diagnostic.list`: computed Flymake diagnostics, with Flycheck's when it is loaded.

### limen compile

```
limen compile list
limen compile read BUFFER
```

`list` reads `compile.list`; `read` reads the last 64 KiB of a compilation buffer's output.

### limen annotations

```
limen annotations sessions
limen annotations list [--session NAME] [--path PATH] [--limit N]
limen annotations export --session NAME [--path PATH] [--format rustc|diff|integrate]
```

Read the `annotation.*` operations. Without scholia they answer `disabled_operation`, or
`unknown_operation` when `limen-scholia` cannot load.

### limen projects

```
limen projects
```

Read `project.list`: Projectile's known projects when Projectile is loaded, otherwise
`project.el`'s.

### limen skill

```
limen skill
```

Print Markdown agent instructions listing every enabled CLI operation, its command line and
effect.

### limen hook

```
limen hook claude|codex|pi|omp
```

Read a hook payload from standard input and print the harness's hook output. Exits 0 without
output unless `LIMEN_SESSION` or `HERDR_ENV=1` is set, when Emacs does not answer within
`LIMEN_HOOK_TIMEOUT` seconds, and on any error. The payload is described in
[docs/hook-payload.md](docs/hook-payload.md).

### limen eval

```
limen eval CODE
limen eval -
```

Evaluate Emacs Lisp; `-` reads it from standard input. Refused unless `limen-enable-elisp-eval`
is non-nil.

## Environment

| Variable | Read by | Meaning |
| --- | --- | --- |
| `EMACSCLIENT` | `bin/limen` | client binary; default `emacsclient` |
| `LIMEN_HOOK_TIMEOUT` | `limen hook` | seconds to wait for Emacs; default 3 |
| `LIMEN_SESSION` | `limen hook` | the Limen session of a launched pane; set by `limen-herdr-mode` |
| `LIMEN_PROVIDER` | the hooks extension | the harness name; set by `limen-herdr-mode` |
| `LIMEN_COMMAND` | the hooks extension | the command the hooks extension runs; default `limen` |
| `LIMEN_MCP_URL`, `LIMEN_MCP_TOKEN`, `LIMEN_MCP_SESSION` | Pi, Oh My Pi, Codex | the pane's MCP route; set by `limen-herdr-mode` for harnesses with an MCP route |
| `HERDR_ENV` | `limen hook` | `1` in a Herdr pane |
| `HERDR_SOCKET_PATH`, `HERDR_PANE_ID` | `limen hook` | the Herdr server and pane the hook ran in |
| `CLAUDE_CONFIG_DIR` | Emacs | Claude Code's configuration directory; default `~/.claude` |
| `CODEX_HOME` | Emacs | Codex's directory; default `~/.codex` |
| `PI_HOME`, `OMP_HOME` | Emacs, `mise run install-extensions` | Pi's and Oh My Pi's directories; default `~/.pi`, `~/.omp` |

Codex reads its bearer token from `LIMEN_MCP_TOKEN`, which the launch arguments name.

## Files

| File | Written by | Holds |
| --- | --- | --- |
| `$CLAUDE_CONFIG_DIR/settings.json` | `limen-hooks-install` | Claude Code's `hooks` entries running `limen hook claude` |
| `$CODEX_HOME/hooks.json` | `limen-hooks-install` | Codex's `hooks` entries running `limen hook codex` |
| `$PI_HOME/agent/extensions/limen-hooks`, `limen-mcp` | `mise run install-extensions` | links to `extensions/` |
| `$OMP_HOME/agent/extensions/limen-hooks`, `limen-mcp` | `mise run install-extensions` | links to `extensions/` |

Limen reads, and never writes, Claude Code's `sessions/*.json` for session names, the skill
directories `skills/` under each harness directory and under `.claude/`, `.codex/`, `.pi/` or
`.omp/` in the project, and the transcripts the hook payloads name.

## Exit status

| Status | Meaning | Error codes |
| --- | --- | --- |
| 0 | success | |
| 2 | invalid usage or request | `invalid_request`, `unsupported_version` |
| 3 | the operation cannot run as asked | `unknown_operation`, `disabled_operation`, `invalid_arguments` |
| 4 | the Emacs server is unreachable | |
| 5 | the operation failed, or the answer was malformed | `operation_failed`, `internal_error` |
| 6 | the buffer or file changed underneath the request | `conflict` |

`limen hook` exits 0 once its provider argument is valid, whatever happens after; a missing or
unknown provider exits 2.
