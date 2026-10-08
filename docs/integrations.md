# Provider integrations

Limen serves Claude Code, Codex, Pi and Oh My Pi from one operation registry, and reaches each
through the channels that harness supports. This page lists what each harness gets and how.
[GUIDE.md](../GUIDE.md) explains the features; [REFERENCE.md](../REFERENCE.md) lists the options.

```text
                 ┌─ Claude Code: prompt hooks and the CLI
Limen operations ├─ Codex: prompt hooks, the CLI and, opt-in, MCP diff tools
                 └─ Pi, Oh My Pi: the limen-hooks extension, the CLI and, opt-in, MCP diff tools
                               ▲
                               │
                      limen-herdr-mode (optional)
```

The CLI works for every harness, launched by Herdr or not.

## Capabilities

| Capability | Claude Code | Codex | Pi and Oh My Pi |
| --- | --- | --- | --- |
| Operations | CLI | CLI; the diff operations as MCP tools under `limen-herdr-mcp` | CLI; the diff operations as `limen_diff_*` tools under `limen-herdr-mcp` |
| Passive selection | `focus:` line on the next prompt | `focus:` line on the next prompt | `focus:` line on the next prompt |
| Explicit context push | on the next prompt; without hooks, typed into the terminal | on the next prompt; without hooks, typed into the terminal | on the next prompt; without hooks, typed into the terminal |
| Prompt hooks | `SessionStart`, `UserPromptSubmit` and the subscribed events, in `settings.json` | the same, in `hooks.json` | every event, translated by the `limen-hooks` extension |
| Question inbox | `AskUserQuestion`, through `PreToolUse` and `PostToolUse` | `request_user_input_async`, read from the transcript on `Stop` | none: no question tool is named |
| Herd notices | Herdr agent states, refined by hooks, with Claude's session name | Herdr agent states, refined by hooks | Herdr agent states, refined by hooks |
| Model and context columns | `SessionStart`, `PostModelSwitch`, `Stop` | `SessionStart`, `Stop` | `SessionStart`, `PostModelSwitch`, `Stop` |
| Edit review | `Edit`, `Write`, `MultiEdit` | none: no edit tool is named | `edit`, `write` |
| Interactive diffs | none | with an MCP route, while `limen-editor-enable-diffs` is set | with an MCP route, while `limen-editor-enable-diffs` is set |
| Launch wiring | `LIMEN_SESSION` | `LIMEN_SESSION`; a per-launch MCP route under `limen-herdr-mcp` | `LIMEN_SESSION`; a per-launch MCP route under `limen-herdr-mcp` |
| Adopted agent | everything above | everything but the MCP route | everything but the MCP route |

Rows that name hooks assume `limen-hooks-mode` and the feature's own mode are on. What a harness
can do is recorded once, in `limen-provider.el`, and the other modules read it from there.

## Transports

### Claude Code

Claude Code has no Limen transport of its own. A launched pane carries `LIMEN_SESSION`, the
prompt hooks deliver context, and the CLI answers requests. Limen writes nothing under
`~/.claude` beyond its hook entries in `settings.json`, and a running pane stays connected across
an Emacs restart, since there is no connection to lose. An adopted Claude Code agent is
integrated as fully as a launched one.

### Codex

With `limen-herdr-mcp` set, Herdr starts Codex with a per-launch MCP server:

```text
codex -c mcp_servers.limen.url="http://127.0.0.1:PORT/mcp/ROUTE" \
      -c mcp_servers.limen.bearer_token_env_var="LIMEN_MCP_TOKEN" ...
```

Your Codex configuration stays as it is. The endpoint serves only the diff tools, `diff_open`,
`diff_close` and `diff_close-all`, while `limen-editor-enable-diffs` is set. Codex reads its
hooks from `hooks.json`, so an adopted Codex agent answers them; it has no MCP route, since a
route can only be handed to a process at launch.

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

`extensions/limen-mcp` does nothing unless `LIMEN_MCP_URL`, `LIMEN_MCP_TOKEN` and
`LIMEN_MCP_SESSION` are set, which `limen-herdr-mcp` arranges for a launched pane. It then mirrors
the route's MCP tools, the diff tools, as `limen_diff_open`, `limen_diff_close` and
`limen_diff_close-all`, refreshes them when the registry changes, and handles deferred results over
SSE. Shutdown withdraws the extension's tools. The selection reaches Pi and Oh My Pi through the
`limen-hooks` extension's `UserPromptSubmit` answer.

## Launch and adoption

`limen-herdr-mode` registers one adapter with Herdr for the `claude`, `codex`, `pi` and `omp`
kinds. It also tells Herdr, through `herdr-message-shown-functions`, that a memex view of an
agent's conversation already shows that agent, so a message written from the view leaves the
agent's terminal where it is. Herdr calls the adapter through an agent's life:

```elisp
(adapter session :prepare)
(adapter session :arguments complete-argv)
(adapter session :adopted agent)
(adapter session :attached)
(adapter session :status)
(adapter session :detach)
```

`:prepare` opens a Limen session rooted at the agent's project and bound to its Herdr server and
pane, registers an MCP route for harnesses that take one when `limen-herdr-mcp` is set, and
returns the pane environment.
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

`limen-herdr-mode` names and titles Herdr agents through Limen while Herdr's own
`herdr-agent-name-function` and `herdr-agent-title-function` stand. `limen-herdr-agent-name` asks
`claude -p` with `limen-provider-claude-small-model`, the model recaps use as well, for a Title Case
name after the task the agent's terminal title shows; Herdr keeps its slug as the agent's name, and
`limen-herdr-agent-title` shows that slug as Title Case again. Where Claude answers no valid name
within `limen-herdr-name-timeout` seconds, Herdr's derived name stands.

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
