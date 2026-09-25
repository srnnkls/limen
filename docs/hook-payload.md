# The hook payload

Every harness reaches Limen through one payload shape, and every feature built on hooks reads
that shape. This page specifies the events, how a feature subscribes to them, and what Limen
answers. [GUIDE.md](../GUIDE.md#prompt-hooks) covers the features themselves.

The names are Claude Code's. Claude Code and Codex send them natively; for Pi and Oh My Pi,
`extensions/limen-hooks` translates the harness's events before it runs `limen hook <provider>`.
`limen-hooks-output` adds `server` and `pane`, the Herdr server and pane the hook ran in, and
hands the payload to every subscribed feature.

## Fields of every event

| Field | Meaning |
| --- | --- |
| `hook_event_name` | which of the events below this is |
| `session_id` | the harness's own id for the conversation |
| `cwd` | the working directory the agent runs in |
| `transcript_path` | the conversation file, when the harness writes one |

## The events

| Event | Further fields | Read by |
| --- | --- | --- |
| `SessionStart` | `source` (`startup`, `resume`, `clear`, `compact`, `fork`), `model`, `context_tokens`, `context_window` | skill injection, `limen-herd`, `limen-model`, `limen-usage` |
| `UserPromptSubmit` | `prompt` | the context block, `limen-herd`, `limen-inbox`, `limen-memex` |
| `PreToolUse` | `tool_name`, `tool_input`, `tool_use_id` | `limen-inbox` |
| `PostToolUse` | `tool_name`, `tool_input` (with `file_path` for an edit), `tool_use_id` | edit review, `limen-inbox`, `limen-memex` |
| `Stop` | `stop_hook_active`, `last_assistant_message`, `context_tokens`, `context_window` | `limen-usage`, `limen-model`, `limen-inbox`, `limen-herd`, `limen-memex` |
| `PostModelSwitch` | `to_model`, `context_tokens`, `context_window` | `limen-model`, `limen-usage` |
| `SessionEnd` | `reason` | `limen-inbox`, `limen-herd`, `limen-memex` |

`limen-hooks-event-names` holds these names, and a subscription naming any other is refused.

`context_tokens` is what the next request re-sends: the last main-thread answer's input, cache
reads, cache writes and output. `context_window` is the window it is sent against. A harness that
counts neither leaves both out, and `limen-usage` reads the transcript instead.

## Subscribing

A feature claims events with one call:

```elisp
(limen-hooks-subscribe "inbox"
                       :events '(("PreToolUse" . "AskUserQuestion") ("Stop"))
                       :provider-events '((claude ("PostModelSwitch")))
                       :function #'my-inbox-on-event)
```

`:events` are `(EVENT . MATCHER)` specs every harness installs, where `MATCHER` is nil or the
harness's tool matcher. `:provider-events` maps a harness to specs only it installs, for an event
the others lack. Subscribing the same feature again replaces its specs.

`:function` joins `limen-hooks-event-functions`. It is called for every answered event, not only
the subscribed ones, with the provider name, the payload, the resolved Limen session or nil, and
the request. A string it returns for `UserPromptSubmit` follows the context block.

Subscribing requests the missing hooks through `limen-hooks-request-install`, under the
feature's name. Requests from the same command, or from startup, share one `y-or-n-p` per
harness that names every requesting feature; in batch they install without asking.

`limen-hooks-unsubscribe` drops the feature and removes, per harness, the specs it asked for that
no remaining subscription needs. Removal matches event and matcher, so one feature's
`PostToolUse` group goes while another's stays. `limen-hooks-events` returns the union of what
the subscriptions ask for.

The built-in subscriptions:

| Feature | Subscribed by | Events |
| --- | --- | --- |
| `context` | `limen-hooks-mode` | `UserPromptSubmit`, `SessionStart` |
| `review` | `limen-hooks-mode` with `limen-hooks-review-edits` | `PostToolUse` matching every harness's edit tools |
| `inbox` | `limen-inbox-mode` | `PreToolUse` and `PostToolUse` matching the question tools, `Stop`, `SessionEnd` |
| `herd` | `limen-herd-mode` | `Stop`, `SessionEnd` |
| `model` | `limen-model-mode` | `limen-model-provider-events` |
| `context window` | `limen-usage-mode` | `limen-usage-provider-events` |
| `memex` | `limen-memex-live-mode` | `limen-memex-live-events` |

A tool matcher lists names joined by `|`. Claude Code reads it as exact names, Codex as a regexp.

## The answer

`SessionStart` and `UserPromptSubmit` are answered with

```json
{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": "..."}}
```

when there is context to add, and every other event with nothing. A harness that runs the hook
natively injects the context itself; the Pi extension injects it as a message.

## Transports

`limen-provider-hook-transport` says which end installs a harness's hooks:

- `settings`: Limen writes `limen hook <provider>` into the harness's settings file, and the
  harness runs it. Claude Code and Codex.
- `extension`: the harness loads an extension that translates its events and runs
  `limen hook <provider>`. Pi and Oh My Pi, whose hooks are JavaScript modules, not commands.
  `extensions/limen-hooks` is that extension; `mise run install-extensions` links it where the
  harness discovers it, so an adopted pane answers hooks as a launched one does. The MCP route is
  a separate extension, `extensions/limen-mcp`.

Both answer the same payload. `limen-hooks-providers` names every harness Limen answers;
`limen-hooks-installing-providers` names those whose settings Limen writes.

## Metadata tokens

`limen-model` and `limen-usage` report to Herdr as pane metadata, and `herdr-status` draws its
model and context columns from it. The dashboard owns the token names, `herdr-status-model-token`
and `herdr-status-context-token`, and Limen follows them: `limen-model-token` and
`limen-usage-token` are nil by default, which means whatever the dashboard reads. Set a string
only for a reader of your own.
