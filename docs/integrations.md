# Provider integrations

Limen serves Claude Code, Codex, Pi and Oh My Pi from one operation registry, and reaches each
through the channels that harness supports. This page lists what each harness gets and how.
[GUIDE.md](../GUIDE.md) explains the features; [REFERENCE.md](../REFERENCE.md) lists the options.

```text
                        ┌─ Claude Code: prompt hooks and the CLI
Limen operations/events ├─ Codex: prompt hooks, MCP Streamable HTTP and the CLI
                        └─ Pi, Oh My Pi: the limen-hooks and limen-mcp extensions and the CLI
                                      ▲
                                      │
                             limen-herdr-mode (optional)
```

The CLI works for every harness, launched by Herdr or not.

## Capabilities

| Capability | Claude Code | Codex | Pi and Oh My Pi |
| --- | --- | --- | --- |
| Operations | CLI | CLI and MCP tools | CLI and `limen_*` tools |
| Passive selection | `focus:` line on the next prompt | `focus:` line on the next prompt; MCP resource update | `focus:` line on the next prompt; latest selection injected before the next turn |
| Explicit context push | on the next prompt; without hooks, typed into the terminal | on the next prompt; without hooks, a `context.push` resource update | on the next prompt; without hooks, a message |
| Prompt hooks | `SessionStart`, `UserPromptSubmit` and the subscribed events, in `settings.json` | the same, in `hooks.json` | every event, translated by the `limen-hooks` extension |
| Question inbox | `AskUserQuestion`, through `PreToolUse` and `PostToolUse` | `request_user_input_async`, read from the transcript on `Stop` | none: no question tool is named |
| Herd notices | Herdr agent states, refined by hooks, with Claude's session name | Herdr agent states, refined by hooks | Herdr agent states, refined by hooks |
| Model and context columns | `SessionStart`, `PostModelSwitch`, `Stop` | `SessionStart`, `Stop` | `SessionStart`, `PostModelSwitch`, `Stop` |
| Edit review | `Edit`, `Write`, `MultiEdit` | none: no edit tool is named | `edit`, `write` |
| Interactive diffs | none | while `limen-editor-enable-diffs` is set | while `limen-editor-enable-diffs` is set |
| Launch wiring | `LIMEN_SESSION` | `LIMEN_SESSION` and a per-launch MCP route | `LIMEN_SESSION` and a per-launch MCP route |
| Adopted agent | everything above | everything but the MCP route | everything but the MCP route |

Rows that name hooks assume `limen-hooks-mode` and the feature's own mode are on. What a harness
can do is recorded once, in `limen-provider.el`, and the other modules read it from there.

A Codex resource notification tells its MCP client that the selection changed. It does not prove
that Codex put the resource into the model's context. Rely on the prompt hook, or send context
explicitly, when the model must see the current selection.

## Transports

### Claude Code

Claude Code has no Limen transport of its own. A launched pane carries `LIMEN_SESSION`, the
prompt hooks deliver context, and the CLI answers requests. Limen writes nothing under
`~/.claude` beyond its hook entries in `settings.json`, and a running pane stays connected across
an Emacs restart, since there is no connection to lose. An adopted Claude Code agent is
integrated as fully as a launched one.

### Codex

Herdr starts Codex with a per-launch MCP server:

```text
codex -c mcp_servers.limen.url="http://127.0.0.1:PORT/mcp/ROUTE" \
      -c mcp_servers.limen.bearer_token_env_var="LIMEN_MCP_TOKEN" ...
```

Your Codex configuration stays as it is. The endpoint serves the registry's MCP tools and the
`emacs://context/selection` and `emacs://context/push` resources. Codex reads its hooks from
`hooks.json`, so an adopted Codex agent answers them; it has no MCP route, since a route can only
be handed to a process at launch.

### Pi and Oh My Pi

Both harnesses take extensions instead of hook commands. `mise run install-extensions` links the
two in `extensions/` into `~/.pi/agent/extensions` and `~/.omp/agent/extensions`, where the
harness finds them in any pane, launched or adopted.

`extensions/limen-hooks` translates the harness's events into Limen's
[hook payload](hook-payload.md) and runs `limen hook pi` or `limen hook omp`:

| Harness event | Hook event |
| --- | --- |
| `session_start` | `SessionStart` |
| `before_agent_start` | `UserPromptSubmit`; the answer is injected as a message |
| `tool_call` | `PreToolUse` |
| `tool_result` | `PostToolUse` |
| `agent_settled` | `Stop` |
| `model_select` | `PostModelSwitch` |
| `session_shutdown` | `SessionEnd` |

`extensions/limen-mcp` connects to the route in `LIMEN_MCP_URL` with `LIMEN_MCP_TOKEN`. It
mirrors every MCP tool as a `limen_<tool>` Pi tool, refreshes them when the registry changes, and
handles deferred results over SSE. A selection update replaces one cached snapshot, which is
injected once before the next turn when it changed. An explicit push arrives as a message.
Shutdown withdraws the extension's tools and closes the session's event stream.

## Launch and adoption

`limen-herdr-mode` registers one adapter with Herdr for the `claude`, `codex`, `pi` and `omp`
kinds. Herdr calls it through an agent's life:

```elisp
(adapter session :prepare)
(adapter session :arguments complete-argv)
(adapter session :adopted agent)
(adapter session :attached)
(adapter session :status)
(adapter session :detach)
```

`:prepare` opens a Limen session rooted at the agent's project and bound to its Herdr server and
pane, registers an MCP route for harnesses that take one, and returns the pane environment.
`:arguments` rewrites the complete start, continue or resume command line, which is where Codex
gets its MCP flags. `:adopted` opens a session without a route for a harness with hooks, and
records a CLI-only state for one without. `:status` answers `limen-herdr-status`. `:detach`
closes the route and the session, and serves both cleanup and the rollback of a failed launch.

*Adoption* is Emacs taking up an agent Herdr already runs. *Attachment* is Emacs showing that
agent's terminal, which `limen-herdr-attached-p` reports; an attached agent is always adopted. A
prompt hook finds its session by `LIMEN_SESSION`, then by the Herdr server and pane it ran in, so
an adopted agent answers its hooks whether or not its terminal is on screen.

`limen-herdr-claude-auto-adopt-mode` adopts the Claude Code agents that run on the Herdr sessions
Emacs is attached to (`herdr-known-sessions`) and work in known projects. A Herdr session driven
from its own terminal is left alone, and its agents get neither context nor review.

## Adding a harness

`limen-provider-register` takes a `limen-provider` record, built with `limen-provider--make`:

| Field | Meaning |
| --- | --- |
| `name` | the harness symbol, which is also Herdr's agent kind |
| `config-directory` | function returning the harness's configuration directory |
| `hook-settings` | function returning the settings file Limen writes hooks into, or nil |
| `hook-transport` | `settings`, `extension`, or nil for a harness without hooks |
| `route` | `mcp` when a launched pane gets an MCP route |
| `arguments` | function of the endpoint, or nil, and the launch arguments, returning the complete arguments |
| `question-tools` | tool names that ask the user a question |
| `transcript-questions-p` | non-nil when those questions must be read from the transcript |
| `edit-tools` | tool names that change files |
| `session-name` | function from a session id to the name the harness gave it |
| `skill-source` | function from a project root to an alist of skill names and descriptions |
| `skill-reference` | function from a skill name to what the harness is sent to invoke it |
| `capabilities` | the plist `limen-herdr-status` reports |

`limen-herdr-mode` registers its adapter for the four built-in kinds only.
