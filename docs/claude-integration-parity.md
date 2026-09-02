# Claude integration parity ledger

Committed protocol evidence lives under `testdata/claude/`:

- `client-originated.json` records observed and probed Claude WebSocket messages.
- `compatibility-probed.json` records discovery and transport behavior.
- `limen-decided.json` records Limen-owned responses, tools, errors, and cleanup semantics.

| Wire behavior | Verification | State |
| --- | --- | --- |
| discovery lockfile and environment | ERT: `limen-claude-prepare-publishes-discovery-and-environment` | covered |
| MCP initialize and capabilities | ERT: `limen-claude-mcp-initialize-and-listing-contract` | covered |
| JSON-RPC errors | ERT: `limen-claude-mcp-errors-are-json-rpc-specific` | covered |
| fixed tool catalog and result conversion | ERT: `limen-claude-mcp-tool-call-converts-operation-results` | covered |
| reconnect deadline | ERT: `limen-claude-reconnect-deadline-is-current-client-scoped` | covered |
| selection event translation | ERT: `limen-claude-translates-shared-selection-for-one-project` | covered |
| at-mention translation and targeting | ERT: `limen-claude-at-mention-targets-session-or-state` | covered |
| session cleanup | ERT: `limen-claude-cleanup-closes-session` | covered |
| owner-local editable diffs | ERT: `limen-editor-diffs-resolve-through-the-operation-registry` | covered |

Claude compatibility remains isolated in `limen-claude.el`. Its exact loopback WebSocket `/ide` behavior and fixed `openFile`, `getDiagnostics`, `close_tab`, `openDiff`, and `closeAllDiffTabs` catalog do not determine the standard MCP or Pi extension surfaces.

The provider capability contract and shared lifecycle are documented once in [integrations.md](integrations.md).
