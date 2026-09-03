# Claude integration parity ledger

Committed protocol evidence lives under `testdata/claude/`:

- `client-originated.json` records messages sent by Claude Code 2.1.251.
- `compatibility-probed.json` records redacted discovery, handshake, selection, and diff behavior from the disposable live probe.
- `limen-decided.json` records Limen-owned responses, tools, authentication limits, and cleanup semantics.

| Wire behavior | Verification | State |
| --- | --- | --- |
| secure discovery publication, launch environment, and omitted token | ERT: `limen-claude-prepare-publishes-discovery-and-environment` | covered |
| startup rollback after listener acquisition | ERT: `limen-claude-startup-rolls-back-acquired-listener` | covered |
| MCP initialize, `notifications/initialized`, prompts, resources, and fixed tools | ERT: `limen-claude-mcp-initialize-and-listing-contract` | covered |
| JSON-RPC errors | ERT: `limen-claude-mcp-errors-are-json-rpc-specific` | covered |
| fixed tool catalog and exact diff result conversion | ERT: `limen-claude-mcp-initialize-and-listing-contract` | covered |
| reconnect deadline | ERT: `limen-claude-reconnect-deadline-is-current-client-scoped` | covered |
| selection event translation | ERT: `limen-claude-translates-shared-selection-for-one-project` | covered |
| primary-item at-mention translation and targeting | ERT: `limen-claude-at-mention-targets-session-or-state` | covered |
| best-effort retryable cleanup | ERT: `limen-claude-cleanup-is-best-effort-and-retryable` | covered |
| owner-local editable diffs | ERT: `limen-editor-diffs-resolve-through-the-operation-registry` | covered |

The 2.1.251 probe observed the startup sequence `initialize`, `notifications/initialized`, `ide_connected`, `tools/list`, `prompts/list`, and `resources/list`. It also established the raw `X-Claude-Code-Ide-Authorization` header behavior, successful tokenless discovery, latest-selection replacement, and the exact `FILE_SAVED`, `TAB_CLOSED`, and `DIFF_REJECTED` markers. Redacted fixtures contain no token values, private project content, or personal paths.

Claude compatibility remains isolated in `limen-claude.el`. Its loopback WebSocket `/ide` behavior and fixed `openFile`, `getDiagnostics`, `close_tab`, `openDiff`, and `closeAllDiffTabs` catalog do not determine the standard MCP or Pi extension surfaces. The maintained `websocket.el` API cannot authorize request headers before HTTP 101, so Limen does not publish an unenforceable `authToken`.

The provider capability, disclosure, and lifecycle contract is documented once in [integrations.md](integrations.md).
