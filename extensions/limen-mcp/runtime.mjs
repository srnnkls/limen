const SELECTION_URI = "emacs://context/selection";
const PUSH_URI = "emacs://context/push";
const PROTOCOL_VERSION = "2026-07-28";
const LOADED = Symbol.for("limen.mcp.loaded");

function parseSseFrame(frame) {
  const data = [];
  let id;
  let event;
  for (const line of frame.replaceAll("\r", "").split("\n")) {
    if (line.startsWith("id:")) id = line.slice(3).trimStart();
    if (line.startsWith("event:")) event = line.slice(6).trimStart();
    if (line.startsWith("data:")) data.push(line.slice(5).trimStart());
  }
  if (data.length === 0) return null;
  return { id, event, data: JSON.parse(data.join("\n")) };
}

async function consumeSse(reader, receive, stopAfterFirst = false) {
  const decoder = new TextDecoder();
  let pending = "";
  try {
    while (true) {
      const { done, value } = await reader.read();
      pending += decoder.decode(value, { stream: !done });
      let boundary;
      while ((boundary = pending.search(/\r?\n\r?\n/)) >= 0) {
        const separator = pending.slice(boundary).match(/^\r?\n\r?\n/)[0];
        const frame = parseSseFrame(pending.slice(0, boundary));
        pending = pending.slice(boundary + separator.length);
        if (frame) {
          const result = await receive(frame);
          if (stopAfterFirst && result !== undefined) {
            await reader.cancel();
            return result;
          }
        }
      }
      if (done) break;
    }
  } finally {
    reader.releaseLock();
  }
  return undefined;
}

function rpcError(payload, status) {
  const message = payload?.error?.message ?? `Emacs MCP request failed (${status})`;
  const error = new Error(message);
  error.code = payload?.error?.code;
  return error;
}

class McpClient {
  constructor(url, token, session, fetch) {
    this.url = url;
    this.token = token;
    this.session = session;
    this.fetch = fetch;
    this.nextId = 1;
    this.protocolVersion = null;
    this.streamAbort = null;
    this.streamReader = null;
    this.streamTask = null;
    this.closingStream = false;
  }

  headers(accept = "application/json, text/event-stream") {
    const headers = {
      accept,
      authorization: `Bearer ${this.token}`,
      "content-type": "application/json",
    };
    if (this.protocolVersion) {
      headers["mcp-session-id"] = this.session;
      headers["mcp-protocol-version"] = this.protocolVersion;
    }
    return headers;
  }

  async decodeResponse(response, id) {
    const contentType = response.headers.get("content-type") ?? "";
    if (response.status === 202 || response.status === 204) return null;
    if (contentType.includes("text/event-stream")) {
      const reader = response.body.getReader();
      const payload = await consumeSse(
        reader,
        ({ data }) => (data.id === id ? data : undefined),
        true,
      );
      if (!payload) throw new Error("Emacs MCP stream ended without a response");
      if (payload.error) throw rpcError(payload, response.status);
      return payload.result;
    }
    let payload;
    try {
      payload = await response.json();
    } catch {
      throw new Error(`Emacs MCP returned HTTP ${response.status}`);
    }
    if (!response.ok || payload.error) throw rpcError(payload, response.status);
    return payload.result;
  }

  async request(method, params = {}, signal) {
    const id = this.nextId;
    this.nextId += 1;
    const response = await this.fetch(this.url, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify({ jsonrpc: "2.0", id, method, params }),
      signal,
    });
    return { id, result: await this.decodeResponse(response, id) };
  }

  async notify(method, params = {}) {
    const response = await this.fetch(this.url, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify({ jsonrpc: "2.0", method, params }),
    });
    if (!response.ok) await this.decodeResponse(response, null);
  }

  async initialize() {
    const { result } = await this.request("initialize", {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: { name: "limen-mcp", version: "0.1.0" },
    });
    this.protocolVersion = result.protocolVersion;
    await this.notify("notifications/initialized");
  }

  async callTool(name, arguments_, signal) {
    const id = this.nextId;
    this.nextId += 1;
    try {
      const response = await this.fetch(this.url, {
        method: "POST",
        headers: this.headers(),
        body: JSON.stringify({
          jsonrpc: "2.0",
          id,
          method: "tools/call",
          params: { name, arguments: arguments_ },
        }),
        signal,
      });
      return await this.decodeResponse(response, id);
    } catch (error) {
      if (signal?.aborted) {
        await this.notify("notifications/cancelled", {
          requestId: id,
          reason: "Pi cancelled the tool call",
        }).catch(() => {});
      }
      throw error;
    }
  }

  async openNotifications(receive, closed) {
    this.closingStream = false;
    this.streamAbort = new AbortController();
    const response = await this.fetch(this.url, {
      method: "GET",
      headers: this.headers("text/event-stream"),
      signal: this.streamAbort.signal,
    });
    if (!response.ok || !response.body) {
      await this.decodeResponse(response, null);
      throw new Error("Emacs MCP did not open an event stream");
    }
    this.streamReader = response.body.getReader();
    this.streamTask = consumeSse(this.streamReader, ({ data }) => receive(data))
      .then(() => {
        if (!this.closingStream) closed();
      })
      .catch((error) => {
        if (!this.closingStream && error?.name !== "AbortError") closed(error);
      })
      .finally(() => {
        this.streamReader = null;
      });
  }

  async closeNotifications() {
    this.closingStream = true;
    this.streamAbort?.abort();
    await this.streamReader?.cancel().catch(() => {});
    await this.streamTask?.catch(() => {});
    this.streamAbort = null;
    this.streamTask = null;
  }

  async closeRoute() {
    const response = await this.fetch(this.url, {
      method: "DELETE",
      headers: this.headers(),
    });
    if (!response.ok && response.status !== 404) {
      throw new Error(`Emacs MCP route close failed (${response.status})`);
    }
  }
}

function contextKey(context) {
  return context?.sequence ?? JSON.stringify(context);
}

function contextItemText(item) {
  const coordinates = Number.isInteger(item.line) && Number.isInteger(item.column)
    ? `:${item.line}:${item.column}`
    : "";
  const location = `${item.path}${coordinates}`;
  return item.text ? `${location}\n\n${item.text}` : location;
}

function contextText(context) {
  const items = Array.isArray(context.items) && context.items.length > 0
    ? context.items
    : [context];
  return items.map(contextItemText).join("\n\n");
}

function resourceValue(result) {
  const text = result?.contents?.[0]?.text;
  if (typeof text !== "string") return null;
  return JSON.parse(text);
}

function errorText(result) {
  return (result?.content ?? [])
    .filter(({ type }) => type === "text")
    .map(({ text }) => text)
    .join("\n") || "Emacs operation failed";
}

export function createLimenExtension(Type, options = {}) {
  const env = options.env ?? process.env;
  const fetch = options.fetch ?? globalThis.fetch;

  return async function limenExtension(pi) {
    const url = env.LIMEN_MCP_URL;
    const token = env.LIMEN_MCP_TOKEN;
    const session = env.LIMEN_MCP_SESSION;
    if (!url || !token || !session || !fetch) return;
    if (pi[LOADED]) return;
    pi[LOADED] = true;

    const ownedTools = new Set();
    const subscriptions = [SELECTION_URI, PUSH_URI];
    let client = null;
    let started = false;
    let latestSelection = null;
    let injectedSelection;
    let deliveredPush;

    const disableTools = () => {
      pi.setActiveTools(pi.getActiveTools().filter((name) => !ownedTools.has(name)));
    };

    const readResource = async (uri) => {
      if (!client) return null;
      const { result } = await client.request("resources/read", { uri });
      return resourceValue(result);
    };

    const refreshTools = async () => {
      if (!client) return;
      const { result } = await client.request("tools/list");
      const active = [];
      for (const descriptor of result?.tools ?? []) {
        const name = `limen_${descriptor.name}`;
        active.push(name);
        if (ownedTools.has(name)) continue;
        ownedTools.add(name);
        pi.registerTool({
          name,
          label: descriptor.title ?? descriptor.name,
          description: descriptor.description ?? "Emacs operation",
          parameters: Type.Unsafe(descriptor.inputSchema),
          async execute(_toolCallId, params, signal) {
            if (!client) throw new Error("Emacs integration is disconnected");
            const result = await client.callTool(descriptor.name, params, signal);
            if (result?.isError) throw new Error(errorText(result));
            return {
              content: result?.content ?? [],
              details: result?.structuredContent ?? {},
            };
          },
        });
      }
      const retained = pi.getActiveTools().filter((name) => !ownedTools.has(name));
      pi.setActiveTools([...new Set([...retained, ...active])]);
    };

    const receive = async (message) => {
      if (message?.method === "notifications/tools/list_changed") {
        await refreshTools();
        return;
      }
      if (message?.method !== "notifications/resources/updated") return;
      const uri = message.params?.uri;
      const context = await readResource(uri);
      if (!context) return;
      if (uri === SELECTION_URI) {
        latestSelection = context;
      } else if (uri === PUSH_URI && contextKey(context) !== deliveredPush) {
        deliveredPush = contextKey(context);
        pi.sendMessage(
          {
            customType: "limen-push",
            content: contextText(context),
            display: true,
            details: context,
          },
          { deliverAs: "steer", triggerTurn: false },
        );
      }
    };

    const disconnected = () => {
      started = false;
      disableTools();
    };

    const start = async (_event, context) => {
      if (started) return;
      const nextClient = new McpClient(url, token, session, fetch);
      try {
        await nextClient.initialize();
        client = nextClient;
        started = true;
        await client.openNotifications(receive, disconnected);
        for (const uri of subscriptions) {
          await client.request("resources/subscribe", { uri });
        }
        latestSelection = await readResource(SELECTION_URI);
        await refreshTools();
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        context?.ui?.notify?.(`Emacs integration: ${message}`, "error");
        client = null;
        started = false;
        await nextClient.closeNotifications();
        disableTools();
      }
    };

    const stop = async (reason) => {
      const current = client;
      client = null;
      started = false;
      injectedSelection = undefined;
      disableTools();
      if (!current) return;
      for (const uri of subscriptions) {
        await current.request("resources/unsubscribe", { uri }).catch(() => {});
      }
      await current.closeNotifications();
      if (reason === "quit") await current.closeRoute().catch(() => {});
    };

    pi.on("session_start", start);
    pi.on("before_agent_start", () => {
      const key = contextKey(latestSelection);
      if (!latestSelection || key === injectedSelection) return undefined;
      injectedSelection = key;
      return {
        message: {
          customType: "limen-context",
          content: contextText(latestSelection),
          display: true,
          details: latestSelection,
        },
      };
    });
    pi.on("session_shutdown", (event) => stop(event.reason));
  };
}
