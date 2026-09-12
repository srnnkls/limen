# Provider integrations

Limen gives Claude Code, Codex, and Pi one provider-neutral Emacs contract while preserving each harness's native transport. The CLI remains available to every local harness.

```text
                        ┌─ Claude WebSocket /ide compatibility
Limen operations/events ├─ Codex MCP Streamable HTTP
                        └─ Pi packaged extension + MCP event stream
                                      ▲
                                      │
                            optional Herdr bridge
```

## Capability contract

| Capability | Claude Code | Codex | Pi |
| --- | --- | --- | --- |
| Operations | fixed Claude compatibility catalog | registry-derived MCP tools | registry-derived Pi tools |
| Passive selection | native `selection_changed` | subscribed MCP resource update | latest update injected once before the next turn |
| Explicit context push | primary item through native `at_mentioned` | submitted through the Herdr terminal | model-visible extension message |
| Interactive diffs | fixed compatibility tools | registry-derived MCP tools | registry-derived Pi tools |
| Launch wiring | `/ide` discovery and environment | per-launch MCP URL and bearer token | per-launch packaged extension and MCP environment |
| Adopted external process | full integration | CLI only | CLI only |

A Codex resource notification reports changed Emacs context to its MCP client. It does not prove that Codex inserted that resource into model context. Use the explicit context command when the model must receive the current selection.

Codex and Pi startup wiring cannot be retrofitted into an externally started process. Their adopted sessions report `cli-only` rather than claiming tool or context integration. Claude can reconnect at runtime through `/ide`.

## Shared contract

`limen.el` owns operation, event, request, and integration-session contracts without depending on Herdr or a provider.

Operations have a dotted ID, description, recursive parameter schema, effect, interface visibility, enable predicate, and optional deferred completion. Registry-derived MCP operations cover one-call context, live buffers, selected-window focus, windows, the opt-in recent-buffer trail, computed diagnostics, editable diffs, and existing compilation buffers. `project.list` stays CLI-only. `elisp.eval` remains CLI-only, hidden, and disabled unless `limen-enable-elisp-eval` is non-nil.

Two normalized events carry editor context:

- `context.selection` stores and deduplicates the latest project-confined snapshot.
- `context.push` records each explicit user-requested attachment with a monotonic sequence. Its optional typed `items` array carries multiple file references while the flat fields retain the primary item for compatibility.

An integration session owns its project root, opaque resource owner, generation, subscriptions, and deferred requests. Closing it invalidates late completions and releases only its buffers and owner-local Ediff state.

### Disclosure policy

Built-in operations and Limen's editor and Herdr context producers apply project confinement before file-backed reads, writes, diagnostics, diffs, focus snapshots, and context pushes. Canonical paths must remain local and beneath the session root. `limen-project-path-deny-regexps` adds canonical project-relative deny patterns; denied paths stay hidden across those built-in surfaces.

Virtual-buffer metadata remains listable. Content and positional state are denied by default. `limen-virtual-buffer-read-allow-condition` accepts the conditions supported by Emacs 29's `buffer-match-p`: `t`, name regexps, predicates, major- or derived-mode clauses, and recursive `and`, `or`, and `not` forms. Set it to `t` only for an explicit global allowance. Invalid conditions fail closed, and no condition bypasses project confinement or the internal-buffer exclusion.

### Focus and buffers

`context.get` is the one-call entrypoint. It composes `limen-context-sections`, an alist of section names to functions of the request: `project`, `focus`, `windows`, and `buffers` come from `limen.el` and reuse the standalone handlers with the same disclosure; `limen-compile.el` adds `compilations` and `limen-trail.el` adds `trail`. A section returning nil is omitted, `sections` selects a subset, and an unknown name is rejected.

`focus.get` reads the request window, or the selected window, without redisplay or UI refresh. It reports the shared buffer record, point, active selection, cached viewport bounds, narrowing, and bounded invisible spans. A missing cached `window-end` stays null. Disallowed virtual focus returns non-positional metadata with `redacted: true`; inaccessible focus returns null.

`limen-trail.el` keeps a bounded most-recently-used trail while `limen-trail-mode` is enabled; the mode is off by default, and `trail.list` stays hidden and disabled until it is on. Visits are recorded from window selection and buffer change hooks, and point is sampled by one idle timer, so no per-command work runs. Each entry keeps at most `limen-trail-point-limit` settled points as markers, newest first, merging moves shorter than `limen-trail-point-distance` lines into the latest point. Killing a file buffer freezes its points to line and column and keeps the entry as `live: false`; reopening the file resumes it. Virtual entries drop on kill. Disabling the mode clears the trail. `trail.list` applies the same confinement, deny patterns, and virtual redaction as `buffer.list`, returns newest first, and `limit` caps the disclosed entries.

Buffer records include kind, modification tick, modified state, major mode, and narrowing bounds. `buffer.read` returns live unsaved text and respects narrowing unless `widen` is explicit. `expected_tick` rejects stale reads. `buffer.save` requires a matching tick and unchanged on-disk state, then revalidates the destination after save hooks. Conflicts never prompt or overwrite silently.

Diagnostics merge existing Flymake results with Flycheck only when Flycheck is already loaded. URI filtering, path policy, deterministic deduplication, one-based lines, and zero-based logical character columns apply to the normalized records.

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

`limen-editor.el` owns selection publication and one shared `post-command-hook` that computes a snapshot once, then publishes it to matching live project sessions. `limen-herdr.el` is the optional bridge from Herdr agent sessions to Limen sessions. It owns provider capabilities, launch wiring, transport status, reconnect policy, and cleanup.

While `limen-herdr-mode` is active, Herdr's send-context commands receive Limen's normalized point or region snapshot when the selected composite target has a matching live integration. In Dired, the bridge reads exactly the marked files, preserves their order, and validates the full set before publishing. Empty marks, directories, symlinks, unreadable or disallowed paths, and item-limit overflow reject the push atomically. File contents are not copied. Codex and Pi render each item once; Limen's fixed Claude mapping sends the first item. Other project-confined buffers report their name, major mode, position, and the text at point instead of a path. Every snapshot ends with a one-line hint naming `limen context` and `limen buffer read` so the agent pulls the live state through the CLI instead of receiving it eagerly. Unmatched targets use Herdr's built-in context unchanged.

## Transports

### Claude Code

Each integrated Claude session gets a loopback WebSocket endpoint and an atomically published lockfile under `~/.claude/ide`, or `$CLAUDE_CONFIG_DIR/ide`. Limen sets the discovery directory to mode `0700`, the lockfile to `0600`, and launches with `ENABLE_IDE_INTEGRATION=true`. The discovery record contains no `authToken`.

Claude Code 2.1.251 sends `X-Claude-Code-Ide-Authorization` verbatim when discovery contains `authToken`; tokenless discovery also connects. The maintained `websocket.el` server API does not expose request headers before the HTTP 101 response, so Limen cannot enforce that token during the handshake. Publishing one would make a false authentication claim. Authentication remains blocked until a maintained transport offers a pre-upgrade authorization hook.

The fixed compatibility catalog is `openFile`, `getDiagnostics`, `close_tab`, `openDiff`, and `closeAllDiffTabs`; those names exist only at the Claude wire boundary. `notifications/initialized` is accepted silently. Prompts and resources list as empty. No runtime workspace, open-editor, dirty-document, or save-document RPC was observed in the 2.1.251 probe, so Limen implements none.

Shared events translate to Claude's `selection_changed` and `at_mentioned` notifications. Cleanup unpublishes discovery first, attempts every teardown stage, and retains failed resources for retry. Startup rollback preserves the original error. The detailed evidence ledger is in [claude-integration-parity.md](claude-integration-parity.md).

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
Integration:  p push context    s status    r reconnect
Claude:       a adopt           c connect   m auto-adopt
Diagnostics:  l protocol log    d enable    D disable
```

Claude-only controls appear when the current project target is Claude; adoption remains available to establish that target. The package installs no global keybinding.

The CLI remains the transport-independent fallback. Run `limen` for its canonical command index and `limen help COMMAND` for command-specific arguments. Compilation commands load `limen-compile` lazily; standalone MCP setups load it explicitly.
