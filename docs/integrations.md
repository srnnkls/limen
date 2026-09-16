# Provider integrations

Limen gives Claude Code, Codex, and Pi one provider-neutral Emacs contract while preserving each harness's native transport. The CLI remains available to every local harness.

```text
                        ┌─ Claude Code prompt hooks and CLI
Limen operations/events ├─ Codex MCP Streamable HTTP
                        └─ Pi packaged extension + MCP event stream
                                      ▲
                                      │
                            optional Herdr bridge
```

## Capability contract

| Capability | Claude Code | Codex | Pi |
| --- | --- | --- | --- |
| Operations | CLI | registry-derived MCP tools | registry-derived Pi tools |
| Passive selection | `focus:` line with the selected range on the next prompt | subscribed MCP resource update | latest update injected once before the next turn |
| Explicit context push | queued for the next prompt hook | queued for the next prompt hook | model-visible extension message |
| Prompt hooks | `UserPromptSubmit` and `SessionStart` in user settings | `UserPromptSubmit` and `SessionStart` in `hooks.json` | none |
| Question inbox | `AskUserQuestion` through `PreToolUse`/`PostToolUse` | `request_user_input_async` read from the transcript on `Stop` | none |
| Herd notices | herdr agent states, refined by `SessionStart`, `UserPromptSubmit`, `Stop`, `SessionEnd` and the session name from `sessions/*.json` | herdr agent states, refined by the same events, unnamed | herdr agent states |
| Edit review | `PostToolUse` on `Edit`, `Write`, `MultiEdit` opens the file's Magit diff | none until its edit tool is named in `limen-provider.el` | none |
| Interactive diffs | none | registry-derived MCP tools while `limen-editor-enable-diffs` is set | registry-derived Pi tools while `limen-editor-enable-diffs` is set |
| Launch wiring | `LIMEN_SESSION` in the pane environment | per-launch MCP URL and bearer token | per-launch packaged extension and MCP environment |
| Adopted external process | prompt hooks | prompt hooks | CLI only |

A Codex resource notification reports changed Emacs context to its MCP client. It does not prove that Codex inserted that resource into model context. Use the explicit context command when the model must receive the current selection.

Pi's startup wiring cannot be retrofitted into an externally started process, so its adopted sessions report `cli-only` rather than claiming tool or context integration. Claude Code and Codex read their hooks from user settings, so an adopted process of either is integrated as fully as a launched one. `limen-herdr-claude-auto-adopt-mode` takes up Claude agents on the herdr sessions Emacs is attached to, `herdr-known-sessions`, working in known projects — those running when it starts and those detected later; a herdr session driven from its own terminal is left alone, so its agents get neither context nor reviews.

## Shared contract

`limen.el` owns operation, event, request, and integration-session contracts without depending on Herdr or a provider. `limen-provider.el` describes each harness once — settings location, launch route and arguments, question and edit tools, session naming, reported capabilities — and every other file reads those fields instead of branching on a harness name.

Operations have a dotted ID, description, recursive parameter schema, effect, interface visibility, enable predicate, and optional deferred completion. Registry-derived MCP operations cover one-call context, live buffers, selected-window focus, windows, the opt-in recent-buffer trail, computed diagnostics, editable diffs while `limen-editor-enable-diffs` is set, existing compilation buffers, and scholia annotation sessions when `limen-scholia` is loaded. `project.list` stays CLI-only. `elisp.eval` remains CLI-only, hidden, and disabled unless `limen-enable-elisp-eval` is non-nil.

Two normalized events carry editor context:

- `context.selection` stores and deduplicates the latest project-confined snapshot.
- `context.push` records each explicit user-requested attachment with a monotonic sequence. Its optional typed `items` array carries multiple file references while the flat fields retain the primary item for compatibility.

An integration session owns its project root, opaque resource owner, generation, subscriptions, and deferred requests. Closing it invalidates late completions and releases only its buffers and owner-local Ediff state.

### Disclosure policy

Built-in operations and Limen's editor and Herdr context producers apply project confinement before file-backed reads, writes, diagnostics, diffs, focus snapshots, and context pushes. Canonical paths must remain local and beneath the session root. `limen-project-path-deny-regexps` adds canonical project-relative deny patterns; denied paths stay hidden across those built-in surfaces.

`limen-confine-to-project`, on by default, keeps focus, the window list and the trail within the requested project; off, each buffer answers against its own project, which its record names as `project`, under that project's deny patterns. Virtual-buffer metadata remains listable. Content and positional state are denied by default. `limen-readable-virtual-buffer-condition` accepts the conditions supported by Emacs 29's `buffer-match-p`: `t`, name regexps, predicates, major- or derived-mode clauses, and recursive `and`, `or`, and `not` forms. Set it to `t` only for an explicit global allowance. Invalid conditions fail closed, and no condition bypasses project confinement or the internal-buffer exclusion.

### Focus and buffers

`context.get` is the one-call entrypoint. It composes `limen-context-sections`, an alist of section names to functions of the request: `project`, `focus`, `windows`, and `buffers` come from `limen.el` and reuse the standalone handlers with the same disclosure; `limen-compile.el` adds `compilations` and `limen-trail.el` adds `trail`. A section returning nil is omitted, `sections` selects a subset, and an unknown name is rejected.

`focus.get` reads the request window, or the selected window, without redisplay or UI refresh. It reports the shared buffer record, point, active selection, cached viewport bounds, narrowing, and bounded invisible spans. A missing cached `window-end` stays null. Disallowed virtual focus returns non-positional metadata with `redacted: true`; inaccessible focus returns null.

`limen-trail.el` keeps a bounded most-recently-used trail while `limen-trail-mode` is enabled; the mode is off by default, and `trail.list` stays hidden and disabled until it is on. Visits are recorded from window selection and buffer change hooks, and point is sampled by one idle timer, so no per-command work runs. Each entry keeps at most `limen-trail-point-limit` settled points as markers, newest first, merging moves shorter than `limen-trail-point-distance` lines into the latest point. Killing a file buffer freezes its points to line and column and keeps the entry as `live: false`; reopening the file resumes it. Virtual entries drop on kill. Disabling the mode clears the trail. `trail.list` applies the same confinement, deny patterns, and virtual redaction as `buffer.list`, returns newest first, and `limit` caps the disclosed entries.

Buffer records include kind, modification tick, modified state, major mode, and narrowing bounds. `buffer.read` returns live unsaved text and respects narrowing unless `widen` is explicit. `expected_tick` rejects stale reads. `buffer.save` requires a matching tick and unchanged on-disk state, then revalidates the destination after save hooks. Conflicts never prompt or overwrite silently.

Diagnostics merge existing Flymake results with Flycheck only when Flycheck is already loaded. URI filtering, path policy, deterministic deduplication, one-based lines, and zero-based logical character columns apply to the normalized records.

### Annotations

`limen-scholia.el` registers `annotation.sessions`, `annotation.list`, and `annotation.export` for CLI and MCP, disabled until scholia loads. Sessions report whether they are active and whether they are the global or project write target, and count only files allowed below the request root. Listing defaults to the sessions visible in the current buffer, confines every file, and caps with `limit`; export renders one file or a whole session through scholia's own formatters. `context.get` gains an `annotations` section while any session is visible, and a Herdr message header carries `annotations: review (3), perf — \`limen annotations list\`` through `limen-herdr-context-fields-functions`, so the agent learns that annotations exist without receiving them.

### Prompt hooks

`limen-hooks.el` answers Claude Code and Codex hooks so prompts typed into an agent pane carry editor context without altering their text. `limen hook PROVIDER` reads the hook payload from standard input and prints `hookSpecificOutput.additionalContext`; it acts only when `LIMEN_SESSION`, set by the launch environment, or `HERDR_ENV=1` is present; it gives up after `LIMEN_HOOK_TIMEOUT` seconds (3 by default, below the providers' 5 s handler timeout) when Emacs is absent, starting up, or busy, and every failure exits 0 without output so a prompt is never blocked. `SessionStart` injects the `limen skill` reference, which Claude repeats after `/clear` and compaction. `UserPromptSubmit` injects an `Emacs context` block: the pending Herdr message context when one exists (`file:`, `mode:`, and the excerpt), the `limen-herdr-context-fields-functions` lines, a `recent:` line naming up to `limen-hooks-recent-limit` trail entries with their newest settled line, and the `live:` pointer. An unchanged block collapses to one line on later prompts.

The session is resolved by `LIMEN_SESSION`, then by the pane the hook ran in — `HERDR_SOCKET_PATH` and `HERDR_PANE_ID` name the session Limen launched or adopted there. A pane Emacs never took up gets no context, so a harness running under Herdr on its own stays unaware of Emacs unless `limen-hooks-answer-unattached` is set, in which case the open session rooted at the hook's working directory answers for it. Hooks are installed per provider into `$CLAUDE_CONFIG_DIR/settings.json` or `$CODEX_HOME/hooks.json` by `limen-hooks-install`, which preserves the file's other handlers and keys; `limen-hooks-uninstall` removes only Limen's entries. The events installed are `limen-hooks-events`: the two context events and, with `limen-hooks-review-edits`, the edit review event while `limen-hooks-mode` is on, plus whatever consumers add to `limen-hooks-extra-events`. One event can carry a group per tool matcher, so the review group sits beside the inbox's `PostToolUse` group. Enabling `limen-hooks-mode` calls `limen-hooks-request-install` with the feature name `context`; requests made by the same command or during startup coalesce, and after it one `y-or-n-p` per provider whose settings lack an event names every requesting feature, while batch sessions install at once. Disabling removes the context events again and leaves consumers' events in place; `limen-hooks-remove-events-everywhere` never removes an event some consumer still lists. Every answered event also runs `limen-hooks-event-functions` with the provider, the payload extended by the Herdr `server` and `pane` from `HERDR_SOCKET_PATH` and `HERDR_PANE_ID`, the resolved session, and the request; strings they return for a `UserPromptSubmit` follow the Emacs context block in the injected text. `limen-hooks-agent-for` resolves that payload to a Herdr agent entry by pane and server, then by the harness session id herdr reports. A Herdr message sent to a provider with installed hooks carries only its text: `limen-herdr-context-hook` records the rendered context as a draft, `herdr-message-compose-functions` promotes it to the pending context when the message is sent, and the next `UserPromptSubmit` consumes it. Cancelled messages never promote.

`limen-hooks-review-edits` opens the diff of a file an agent edited. It adds `PostToolUse` with the matcher of every provider's edit tools; on such an event from a pane Emacs holds a session for, on a file of that session's project, `limen-hooks-review-function` — `limen-hooks-review-with-magit` by default, a Magit diff of the repository's unstaged changes so an agent's edits add up in one buffer, or `vc-diff` without Magit — runs once the hook has answered, so the agent never waits on the review. The diff is shown per `limen-hooks-review-display-action`, a left side window by default since the agent terminal takes the right, and never selected. Turning it on while `limen-hooks-mode` is active requests the install under the feature name `review`.

### Question inbox

`limen-inbox.el` keeps the questions agents are waiting on and lists them at the top of `herdr-status`. `limen-inbox-mode` is the switch: enabling it adds `PreToolUse` and `PostToolUse` with the matcher `AskUserQuestion|request_user_input`, `Stop`, and `SessionEnd` to `limen-hooks-extra-events`, requests the install under the feature name `inbox`, and registers with `limen-hooks-event-functions` and `herdr-status-sections-functions`; disabling removes those handlers from the providers' settings again. Claude's matcher reads the `|` list as exact tool names, Codex's as a regex.

A `PreToolUse` for a provider's question tool records the call's `tool_use_id`, agent `session_id`, Herdr server and pane, and its questions with `header`, `question`, option labels, `multiSelect`, and `isOther`. The matching `PostToolUse` removes it; because a dismissed dialog is not documented to fire one, the agent's next `UserPromptSubmit`, its `Stop`, its `SessionEnd`, and a redraw that finds no dashboard agent on that server and pane remove it too.

Codex does not run its tool hooks for `request_user_input_async`: the call is accepted at once, the turn ends, and the question is shown afterwards. The `Stop` payload carries the turn id and the rollout path, so the inbox scans the last `limen-inbox-transcript-tail-bytes` of that transcript for this turn's `request_user_input*` function calls and lists their questions, which name the text `title` and may list options as plain strings. The answer is the user's next prompt, so `UserPromptSubmit` clears them; a rejected question leaves no record anywhere, so a transcript-sourced entry older than `limen-inbox-settle-seconds` is also dropped at redraw once Herdr no longer reports its agent as `blocked`, the state it detects while the question UI is on screen. Every change requests a dashboard redraw through `herdr-status-request-refresh`.

The section is inserted through `herdr-status-sections-functions` before the recent agents and only while a question is pending. Each asking agent is a `herdr-status-agent` section drawn with `herdr-status-agent-row`, so `RET`, `o`, `P`, `x`, and `R` act on it, and its body lists `header: question`, `(multi)` or `(or other)`, and the options joined by ` · `. Answering stays in the pane.

### Herd notices

`limen-herd.el` tells the members of a Herdr herd (`herdr-herd.el`) what the others do. `limen-herd-mode` is the global switch: enabling it adds `Stop` and `SessionEnd` to `limen-hooks-extra-events`, requests the install under the feature name `herd`, registers with `limen-hooks-event-functions`, `herdr-agent-event-functions`, `herdr-herd-protocol-functions`, and `herdr-herd-sent-functions`, records the status herdr reports for every live agent, subscribes every session to herdr's pane events, and puts a `notices` entry on `n` into `herdr-status-dispatch`, the `herdr-status` keymap, and `herdr-herd-dispatch`; disabling reverses all of it and removes the two hook events only where no other consumer lists them.

A member receives nothing until it subscribes. Its subscriptions are the `notify:KIND,…` word of its pane label next to `herd:NAME`, so they persist with herdr across restarts and an agent reads or changes its own with `herdr pane list` and `herdr pane rename`; the paragraph `limen-herd--protocol` adds to the roster says so. The `n` menu toggles each kind for the agent at point, the rows the region covers, or agents chosen by completion, sets all, none, or `limen-herd-default-events`, and does the same for the whole herd at point.

Herdr's agent states are the base source, so every harness herdr detects takes part. A pane's `agent_status` arriving through `pane.updated`, `pane.agent_detected`, or `pane.moved`, or its `pane.exited` or `pane.closed`, is compared with the status last recorded: a first `idle`, `working`, or `blocked` is `online`, `idle` to `working` is `prompt`, `working` or `blocked` to `idle` is `finished`, and an exit is `exited`, told as `NAME started a turn.` and the like. Each such notice waits `limen-herd-fallback-delay` seconds for a hook to report the same kind for the same pane; a hook event within that time, or within the ten seconds before the change, replaces it. The hook events are the refinement: `SessionStart` with source `startup` or `resume` is `online`, `UserPromptSubmit` is `prompt` with the first `limen-herd-prompt-length` characters of the prompt, `Stop` is `finished` with that prompt, the provider's session name where Claude assigned one, and the first `limen-herd-excerpt-length` characters of `last_assistant_message`, and `SessionEnd` is `exited` with its reason.

The sender is resolved with `limen-hooks-agent-for` over `herdr-herd-live-agents`, its herd with `herdr-herd-of-entry`, and the recipients are the other members subscribed to the kind. Each is told with `herdr-agent-prompt` when herdr does not report it `working` or `blocked`; otherwise the notice waits in memory and reaches the member either as hook context after the Emacs context on its next `UserPromptSubmit` or by prompt as soon as herdr reports it `idle`, or it is dropped when `limen-herd-hold-for-busy` is nil. Notice text comes from `herdr-herd-notice`, so it opens with `[herd NAME]` and ends `No reply needed.`. A turn a herd prompt starts stays silent on both paths: a prompt opening with one of `limen-herd-quiet-prefixes` silences its `Stop`, as does `stop_hook_active`, and a pane Limen or a herd command just prompted, heard through `herdr-herd-sent-functions`, has its next `working` and `idle` ignored. A session's prompt, held notices, and cached name are dropped on its `SessionEnd`.

### Compilation observation

`limen-compile.el` registers `compile.list` and `compile.read` for CLI and MCP. It observes existing project-confined `compilation-mode` buffers and never starts, waits for, or sends input to a process.

Records report the buffer name, directory, `running`, `succeeded`, `failed`, `stopped`, or `unknown` status, optional process status and exit code, and existing error/warning/info counters. Buffers completed before observation remain `unknown`. Reads remove compilation annotations and return a property-free UTF-8 tail capped at 65,536 bytes. Commands, arguments, environment annotations, generic terminals, and execution controls are excluded.

## Lifecycle

A harness adapter receives one shared `herdr-agent-session` through these phases:

```elisp
(adapter session :prepare)
(adapter session :arguments complete-argv)
(adapter session :adopted agent)
(adapter session :attached)
(adapter session :status)
(adapter session :detach)
```

`:prepare` returns pane environment entries. `:arguments` transforms the complete native start, continue, or resume argument list. Cleanup and rollback use the same `:detach` phase.

`limen-editor.el` owns selection publication and one shared `post-command-hook` that computes a snapshot once, then publishes it to matching live project sessions. `limen-herdr.el` is the optional bridge from Herdr agent sessions to Limen sessions. It owns launch wiring, status, and cleanup; what it knows about each harness comes from `limen-provider.el`.

While `limen-herdr-mode` is active, Herdr's send-context commands receive Limen's normalized point or region snapshot when the selected composite target has a matching live integration. In Dired, the bridge reads exactly the marked files, preserves their order, and validates the full set before publishing. Empty marks, directories, symlinks, unreadable or disallowed paths, and item-limit overflow reject the push atomically. File contents are not copied, and every item renders once. `limen-herdr-push-context` takes the same snapshot as a sent message and offers it to `limen-herdr-push-functions` first — `limen-hooks.el` claims it for a provider whose hooks are installed and carries it on the next prompt — then publishes `context.push` to a session with an MCP route, and otherwise types the rendered context into the pane. The snapshot renders as an `Emacs context` header with `file:` or `buffer:` followed by the position, `mode:`, and `live: \`limen context\`` fields, then the text at point in a fenced block; Dired sends a `files:` list. Paths are relative to the session root, the agent's working directory. The `live` field is the only pointer to the full editor state, so the agent pulls it through the CLI instead of receiving it eagerly. Unmatched targets use Herdr's built-in context unchanged.

## Transports

### Claude Code

Claude Code has no transport of its own. A launched pane carries `LIMEN_SESSION`; the prompt hooks deliver context and the CLI answers requests. Nothing is written under `~/.claude` beyond the hook entries in `settings.json`, and an Emacs restart leaves a running pane connected, since there is no connection to lose.

### Codex

Herdr starts Codex with per-launch `mcp_servers.limen` configuration. It does not edit the user's global Codex configuration. The endpoint exposes registry-derived tools and the `emacs://context/selection` and `emacs://context/push` resources over standard MCP Streamable HTTP.

### Pi

Herdr starts Pi with `extensions/limen-pi/index.ts`. The packaged extension mirrors live MCP tools into `limen_*` Pi tools, refreshes active tools after registry changes, and handles deferred tool responses over SSE.

Selection updates replace one cached snapshot. `before_agent_start` injects it once when its sequence changes. Explicit pushes use `pi.sendMessage`. Shutdown disables extension-owned tools and closes only that session's event stream.

## MCP boundary

`limen-mcp.el` runs one shared listener on `127.0.0.1`. Each session receives an opaque route and bearer token. It implements initialization, tools, resources, subscriptions, ordinary JSON responses, and SSE notifications. Cancelling a request or losing its stream stops deferred editor work and clears its delivery state. Request bodies are capped at 1 MiB and payload logging is absent by default.

The loopback listener, opaque route, token, project confinement, and owner-local cleanup reduce accidental cross-session access. They are not a sandbox. A same-user process with Emacs-server or shell access already has equivalent authority.

## Commands

`M-x limen-herdr-transient` opens the integration menu:

```text
Integration:  p push context    s status    h install hooks
Claude:       a adopt           m auto-adopt
```

The package installs no global keybinding.

The CLI remains the transport-independent fallback. Run `limen` for its canonical command index and `limen help COMMAND` for command-specific arguments. Compilation commands load `limen-compile` lazily; standalone MCP setups load it explicitly.
