---
name: limen
description: |
  Read and act on the user's live Emacs session through the `limen` CLI. Use when the task depends on what Emacs holds rather than the disk: the file and region the user is on, unsaved buffer text, Flymake/Flycheck diagnostics, compilation output, recently visited buffers, or opening a file at a location for the user.
metadata:
  type: generic
---

# limen

`limen` asks the user's running Emacs server and prints one JSON envelope per call. Every path is
confined to the project of the working directory.

## Live index

The enabled operations change with the user's Emacs configuration. Read them from Emacs, not from
memory:

```bash
limen skill                  # enabled operations with their command lines and effect
limen help COMMAND           # arguments of one command
```

A prompt hook may already have injected the `limen skill` output; reuse it when present.

## Orient

```bash
limen context                          # project, focus, windows, buffers, compilations, trail
limen context --section focus --section trail
limen focus                            # buffer, point, selection, viewport
```

Start with `limen context` when a request says "this", "here", "the error" or "what I selected"
without naming a file. The focus is the window the user came from, not the agent's terminal.

## Envelope and exit status

Success is `{"ok": true, "operation": ..., "result": ...}`; failure is
`{"ok": false, "error": {"code": ..., "message": ...}}`. Branch on `ok`, then on `error.code`:

| Exit | Code | Response |
| --- | --- | --- |
| 3 | `unknown_operation`, `disabled_operation`, `invalid_arguments` | check `limen skill` and `limen help COMMAND` |
| 4 | none | Emacs server unreachable; fall back to the disk and say so |
| 5 | `operation_failed` | read the message, e.g. `File is not visited` |
| 6 | `conflict` | the buffer or file changed; re-read before acting |

## Buffers versus the disk

- `limen buffer list` reports each file buffer's `modified` flag and `tick`.
- `limen buffer read PATH [--line N --end-line N]` returns the live text, including unsaved
  edits. It works only for visited files; for anything else, read the file from disk.
- Prefer the live text whenever `modified` is true: the disk copy is stale.
- Before editing a file on disk that Emacs visits with `modified` true, stop and ask; writing
  would fork the user's unsaved work.

## Saving

`limen buffer save PATH --expected-tick TICK` saves only while the buffer's tick and the file on
disk are unchanged. Take `TICK` from the `buffer read` or `buffer list` just before; a `conflict`
means the user kept editing, so re-read instead of retrying.

## Showing the user something

```bash
limen buffer open PATH --line 42 --column 0
limen buffer open PATH --start-text "defun foo" --end-text "))"
```

Opens the file in Emacs and places point and the region. It changes what the user sees, so use it
when asked to show or jump to code.

## Diagnostics and builds

```bash
limen diagnostics                      # computed Flymake/Flycheck diagnostics
limen diagnostics --uri file:///abs/path.el
limen compile list                     # existing compilation buffers
limen compile read "*compilation*"     # last 64 KiB of output
```

These read what Emacs already computed; they start no checker and run no build.
