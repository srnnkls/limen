# The hook payload

Every harness reaches Limen through one shape. A harness that emits it natively is passed through; one that does not is translated at its own edge, before `limen hook <provider>` is called. `limen-hooks-output` appends `server` and `pane` from the Herdr pane the hook ran in, then hands it to the function of every subscribed feature.

The names are Claude Code's. Claude and Codex speak them already; Pi and Oh My Pi are translated into them by `extensions/limen-hooks`.

## Carried by every event

| Field | Meaning |
|---|---|
| `hook_event_name` | Which of the events below this is |
| `session_id` | The harness's own id for the conversation |
| `cwd` | The working directory the agent runs in |
| `transcript_path` | The conversation file, when the harness writes one |

## The events

| Event | Further fields | Read by |
|---|---|---|
| `SessionStart` | `source` (`startup`, `resume`, `clear`, `compact`, `fork`), `model`, `context_tokens`, `context_window` | skill injection, `limen-herd`, `limen-model`, `limen-usage` |
| `UserPromptSubmit` | `prompt` | prompt context, `limen-herd`, `limen-inbox`, `limen-memex` |
| `PreToolUse` | `tool_name`, `tool_input`, `tool_use_id` | `limen-inbox` |
| `PostToolUse` | `tool_name`, `tool_input` (with `file_path` for an edit), `tool_use_id` | edit review, `limen-inbox`, `limen-memex` |
| `Stop` | `stop_hook_active`, `last_assistant_message`, `context_tokens`, `context_window` | `limen-usage`, `limen-inbox`, `limen-herd`, `limen-memex` |
| `PostModelSwitch` | `to_model`, `context_tokens`, `context_window` | `limen-model`, `limen-usage` |
| `SessionEnd` | `reason` | `limen-inbox`, `limen-herd`, `limen-memex` |

`limen-hooks-event-names` holds these names, and a subscription naming any other is refused.

`context_tokens` is what the next request re-sends: the last main-thread answer's input, cached reads, cache writes and output. `context_window` is what it is sent against. A harness that counts neither leaves both out, and `limen-usage` reads the transcript instead.

## Subscribing

A feature reads events through one call:

```elisp
(limen-hooks-subscribe "inbox"
                       :events '(("PreToolUse" . "AskUserQuestion") ("Stop"))
                       :provider-events '((claude ("PostModelSwitch")))
                       :function #'limen-inbox--on-event)
```

`:events` are `(EVENT . MATCHER)` specs every provider installs; `:provider-events` are those only the named provider does, for an event the others lack. `:function` is called for every answered event — not only the ones subscribed — with the provider name, the payload, the resolved Limen session or nil, and the request; a string it returns for `UserPromptSubmit` joins the injected context. Subscribing requests the missing hooks through `limen-hooks-request-install`, under the feature's name.

`limen-hooks-unsubscribe` drops the feature and removes, per provider, the specs it asked for that no remaining subscription needs. Removal goes by event and matcher, so one feature's `PostToolUse` group goes while another's stays. `limen-hooks-events` is always the union of what the subscriptions ask for.

## The answer

`SessionStart` and `UserPromptSubmit` are answered with

```json
{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": "..."}}
```

and every other event with an empty string. A harness whose extension asked the hook injects that context itself; one running the hook natively lets its own harness do it.

## Transports

`limen-provider-hook-transport` says which end installs the hooks.

- `settings` — Limen writes a command into the harness's own settings file, and the harness runs `limen hook <provider>`. Claude and Codex.
- `extension` — the harness loads an extension, which translates its events and calls `limen hook <provider>` itself. Pi and Oh My Pi, whose `--hook` takes a JavaScript file rather than a command, so there is no settings file to write into. `extensions/limen-hooks` is that translator; `mise run install-extensions` links it where the harness discovers it, so an adopted pane answers hooks as readily as a launched one. It knows nothing of Limen's MCP route: `extensions/limen-mcp` is a separate extension, loaded or not on its own terms.

Both answer the same payload. `limen-hooks-providers` names every harness that answers; `limen-hooks-installing-providers` names only those whose settings Limen writes.

## The metadata tokens

What Limen reports of an agent, Herdr carries and its dashboard draws, so
the name of each token is shared between them.  The dashboard owns the
name - `herdr-status-context-token' and `herdr-status-model-token' - and
Limen follows it: `limen-usage-token' and `limen-model-token' are nil by
default, which means "whatever reads it", and a string only where Limen
reports to a reader of its own.
