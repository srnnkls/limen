import assert from "node:assert/strict";
import test from "node:test";

import { createLimenExtension } from "./runtime.mjs";

const encoder = new TextEncoder();

function jsonResponse(id, result) {
  return new Response(JSON.stringify({ jsonrpc: "2.0", id, result }), {
    headers: { "content-type": "application/json" },
  });
}

function sseResponse(payload, id) {
  const frame = `id: ${id}\nevent: message\ndata: ${JSON.stringify(payload)}\n\n`;
  return new Response(
    new ReadableStream({
      start(controller) {
        const split = Math.floor(frame.length / 2);
        controller.enqueue(encoder.encode(frame.slice(0, split)));
        controller.enqueue(encoder.encode(frame.slice(split)));
        controller.close();
      },
    }),
    { headers: { "content-type": "text/event-stream" } },
  );
}

async function waitFor(predicate) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 1));
  }
  assert.fail("condition was not reached");
}

function occurrences(text, needle) {
  return text.split(needle).length - 1;
}

function fakePi() {
  const handlers = new Map();
  const tools = new Map();
  const messages = [];
  let active = ["read"];
  let loading = true;
  const action = () => {
    if (loading) throw new Error("action called during extension loading");
  };

  return {
    handlers,
    tools,
    messages,
    on(event, handler) {
      handlers.set(event, handler);
    },
    registerTool(tool) {
      action();
      tools.set(tool.name, tool);
    },
    getActiveTools() {
      action();
      return [...active];
    },
    setActiveTools(names) {
      action();
      active = [...names];
    },
    sendMessage(message, options) {
      action();
      messages.push({ message, options });
    },
    finishLoading() {
      loading = false;
    },
    activeTools() {
      return [...active];
    },
  };
}

test("Pi extension mirrors tools, injects latest context, and shuts down", async () => {
  let streamController;
  let selection = null;
  let pushed = null;
  let descriptors = [
    {
      name: "buffer_list",
      description: "List project buffers.",
      inputSchema: { type: "object", properties: {}, additionalProperties: false },
    },
    {
      name: "diff_open",
      description: "Open an editable diff.",
      inputSchema: {
        type: "object",
        properties: { name: { type: "string" } },
        required: ["name"],
        additionalProperties: false,
      },
    },
  ];
  const calls = [];
  const fetch = async (_url, options = {}) => {
    const headers = new Headers(options.headers);
    calls.push({ method: options.method ?? "GET", headers, body: options.body });

    assert.equal(headers.get("authorization"), "Bearer secret");
    if ((options.method ?? "GET") === "GET") {
      return new Response(
        new ReadableStream({
          start(controller) {
            streamController = controller;
          },
        }),
        { headers: { "content-type": "text/event-stream" } },
      );
    }
    if (options.method === "DELETE") return new Response(null, { status: 204 });

    const request = JSON.parse(options.body);
    if (request.method !== "initialize") {
      assert.equal(headers.get("mcp-session-id"), "route-1");
      assert.equal(headers.get("mcp-protocol-version"), "2026-07-28");
    }
    switch (request.method) {
      case "initialize":
        assert.deepEqual(request.params.capabilities, {});
        return jsonResponse(request.id, {
          protocolVersion: "2026-07-28",
          capabilities: { tools: { listChanged: true }, resources: { subscribe: true } },
          serverInfo: { name: "limen", version: "0.1.0" },
        });
      case "notifications/initialized":
      case "notifications/cancelled":
        return new Response(null, { status: 202 });
      case "tools/list":
        return jsonResponse(request.id, { tools: descriptors });
      case "tools/call": {
        const result = {
          content: [{ type: "text", text: `${request.params.name} complete` }],
          structuredContent: { called: request.params.name },
          isError: false,
        };
        return request.params.name === "diff_open"
          ? sseResponse({ jsonrpc: "2.0", id: request.id, result }, request.id)
          : jsonResponse(request.id, result);
      }
      case "resources/subscribe":
      case "resources/unsubscribe":
        return jsonResponse(request.id, {});
      case "resources/read": {
        const value = request.params.uri.endsWith("selection") ? selection : pushed;
        return jsonResponse(request.id, {
          contents: [{ uri: request.params.uri, mimeType: "application/json", text: JSON.stringify(value) }],
        });
      }
      default:
        throw new Error(`unexpected MCP method: ${request.method}`);
    }
  };
  const pi = fakePi();
  const extension = createLimenExtension(
    { Unsafe: (schema) => schema },
    {
      env: {
        LIMEN_MCP_URL: "http://127.0.0.1:4100/mcp/route-1",
        LIMEN_MCP_TOKEN: "secret",
        LIMEN_MCP_SESSION: "route-1",
      },
      fetch,
    },
  );

  await extension(pi);
  assert.deepEqual([...pi.tools.keys()], []);
  pi.finishLoading();
  await pi.handlers.get("session_start")({ type: "session_start" }, {});
  assert.deepEqual([...pi.tools.keys()].sort(), ["limen_buffer_list", "limen_diff_open"]);
  assert.deepEqual(pi.activeTools().sort(), ["limen_buffer_list", "limen_diff_open", "read"]);

  const diff = await pi.tools.get("limen_diff_open").execute("tool-1", { name: "change" });
  assert.equal(diff.content[0].text, "diff_open complete");
  assert.deepEqual(diff.details, { called: "diff_open" });

  selection = {
    path: "/project/a.el",
    line: 4,
    column: 2,
    end_line: 4,
    end_column: 5,
    text: "value",
    sequence: 7,
  };
  const selectionFrame = `event: message\ndata: ${JSON.stringify({
    jsonrpc: "2.0",
    method: "notifications/resources/updated",
    params: { uri: "emacs://context/selection" },
  })}\n\n`;
  streamController.enqueue(encoder.encode(selectionFrame.slice(0, 19)));
  streamController.enqueue(encoder.encode(selectionFrame.slice(19)));
  await waitFor(() => calls.filter(({ body }) =>
    body?.includes('"resources/read"') && body.includes("context/selection")
  ).length >= 2);

  const beforeStart = pi.handlers.get("before_agent_start");
  const firstContext = await beforeStart({ type: "before_agent_start" }, {});
  assert.match(firstContext.message.content, /a\.el:4:2\n\nvalue/);
  assert.equal(await beforeStart({ type: "before_agent_start" }, {}), undefined);

  pushed = {
    ...selection,
    path: "/project/first.el",
    text: "explicit",
    sequence: 8,
    items: [
      {
        type: "file",
        path: "/project/first.el",
        line: 4,
        column: 2,
        end_line: 4,
        end_column: 5,
        text: "explicit",
      },
      {
        type: "file",
        path: "/project/second.el",
        line: 9,
        column: 1,
        end_line: 10,
        end_column: 3,
        text: "second excerpt",
      },
    ],
  };
  streamController.enqueue(
    encoder.encode(`event: message\ndata: ${JSON.stringify({
      jsonrpc: "2.0",
      method: "notifications/resources/updated",
      params: { uri: "emacs://context/push" },
    })}\n\n`),
  );
  await waitFor(() => pi.messages.length === 1);
  assert.equal(pi.messages[0].options.deliverAs, "steer");
  const pushText = pi.messages[0].message.content;
  assert.equal(occurrences(pushText, "/project/first.el"), 1);
  assert.equal(occurrences(pushText, "/project/second.el"), 1);
  assert.equal(occurrences(pushText, "explicit"), 1);
  assert.equal(occurrences(pushText, "second excerpt"), 1);
  assert(pushText.includes("/project/first.el:4:2"));
  assert(pushText.includes("/project/second.el:9:1"));
  assert(pushText.indexOf("/project/first.el") < pushText.indexOf("/project/second.el"));

  descriptors = [...descriptors, {
    name: "window_list",
    description: "List windows.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  }];
  streamController.enqueue(
    encoder.encode(`event: message\ndata: ${JSON.stringify({
      jsonrpc: "2.0",
      method: "notifications/tools/list_changed",
    })}\n\n`),
  );
  await waitFor(() => pi.tools.has("limen_window_list"));
  assert(pi.activeTools().includes("limen_window_list"));

  streamController.close();
  await waitFor(() => pi.activeTools().length === 1);
  assert.deepEqual(pi.activeTools(), ["read"]);

  const shutdown = pi.handlers.get("session_shutdown");
  await shutdown({ type: "session_shutdown", reason: "new" }, {});
  assert(!calls.some(({ method }) => method === "DELETE"));
  await pi.handlers.get("session_start")({ type: "session_start" }, {});
  assert(pi.activeTools().includes("limen_buffer_list"));
  const restartedContext = await beforeStart({ type: "before_agent_start" }, {});
  assert.match(restartedContext.message.content, /a\.el:4:2/);

  await shutdown({ type: "session_shutdown", reason: "quit" }, {});
  assert.deepEqual(pi.activeTools(), ["read"]);
  assert(calls.some(({ method }) => method === "DELETE"));
});

test("Pi extension reports startup failures after loading", async () => {
  const pi = fakePi();
  const extension = createLimenExtension(
    { Unsafe: (schema) => schema },
    {
      env: {
        LIMEN_MCP_URL: "http://127.0.0.1:4100/mcp/route-1",
        LIMEN_MCP_TOKEN: "secret",
        LIMEN_MCP_SESSION: "route-1",
      },
      fetch: async () => {
        throw new Error("stream framing failed");
      },
    },
  );
  const notifications = [];

  await extension(pi);
  pi.finishLoading();
  await pi.handlers.get("session_start")(
    { type: "session_start" },
    { ui: { notify: (...arguments_) => notifications.push(arguments_) } },
  );

  assert.deepEqual(notifications, [
    ["Emacs integration: stream framing failed", "error"],
  ]);
});
