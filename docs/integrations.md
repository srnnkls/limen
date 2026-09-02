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
| Explicit context push | native `at_mentioned` | submitted through the Herdr terminal | model-visible extension message |
| Interactive diffs | fixed compatibility tools | registry-derived MCP tools | registry-derived Pi tools |
| Launch wiring | `/ide` discovery and environment | per-launch MCP URL and bearer token | per-launch packaged extension and MCP environment |
| Adopted external process | full integration | CLI only | CLI only |

A Codex resource notification reports changed Emacs context to its MCP client. It does not prove that Codex inserted that resource into model context. Use the explicit context command when the model must receive the current selection.

Codex and Pi startup wiring cannot be retrofitted into an externally started process. Their adopted sessions report `cli-only` rather than claiming tool or context integration. Claude can reconnect at runtime through `/ide`.

## Shared contract

`limen.el` owns operation, event, request, and integration-session contracts without depending on Herdr or a provider.

Operations have a dotted ID, description, parameter schema, effect, interface visibility, enable predicate, and optional deferred completion. Built-in MCP operations cover buffers, windows, Flymake diagnostics, and editable diffs. `elisp.eval` remains CLI-only, hidden, and disabled unless `limen-enable-elisp-eval` is non-nil.

Two normalized events carry editor context:

- `context.selection` stores and deduplicates the latest project-confined snapshot;
- `context.push` records each explicit user-requested attachment with a monotonic sequence.

An integration session owns its project root, opaque resource owner, generation, subscriptions, and deferred requests. Closing it invalidates late completions and releases only its buffers and owner-local Ediff state.

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

While `limen-herdr-mode` is active, Herdr's send-context commands receive Limen's normalized point or region snapshot when the selected composite target has a matching live integration. Unmatched targets use Herdr's built-in context unchanged.

## Transports

### Claude Code

Each integrated Claude session gets a loopback WebSocket endpoint and discovery lockfile under `~/.claude/ide`, or `$CLAUDE_CONFIG_DIR/ide`. The fixed compatibility catalog is `openFile`, `getDiagnostics`, `close_tab`, `openDiff`, and `closeAllDiffTabs`; those names exist only at the Claude wire boundary.

Shared events translate to Claude's `selection_changed` and `at_mentioned` notifications. The detailed evidence ledger is in [claude-integration-parity.md](claude-integration-parity.md).

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

The CLI remains the transport-independent fallback. Run `limen` for its command index and `limen help COMMAND` for command-specific arguments.
