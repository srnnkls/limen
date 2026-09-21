import assert from "node:assert/strict";
import test from "node:test";

import { createLimenHooks } from "./runtime.mjs";

async function waitFor(predicate) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 1));
  }
  assert.fail("condition was not reached");
}

function fakeSpawn(answers = {}) {
  const calls = [];
  const spawn = (command, args, options) => {
    const call = { command, args, options, payload: null };
    calls.push(call);
    const listeners = {};
    const stdout = {};
    const finish = () => {
      queueMicrotask(() => {
        const answer = answers[call.payload?.hook_event_name];
        if (answer) {
          stdout.data?.(
            JSON.stringify({
              hookSpecificOutput: {
                hookEventName: call.payload.hook_event_name,
                additionalContext: answer,
              },
            }),
          );
        }
        listeners.close?.(0);
      });
    };
    return {
      stdin: {
        end(text) {
          call.payload = JSON.parse(text);
          finish();
        },
      },
      stdout: {
        setEncoding() {},
        on(event, handler) {
          stdout[event] = handler;
        },
      },
      on(event, handler) {
        listeners[event] = handler;
      },
    };
  };
  return { spawn, calls };
}

function fakePi() {
  const handlers = new Map();
  return {
    handlers,
    on(event, handler) {
      handlers.set(event, handler);
    },
  };
}

function fakeContext() {
  return {
    model: { id: "gpt-5.6-luna" },
    sessionManager: { getSessionId: () => "session-7", getCwd: () => "/project" },
    getContextUsage: () => ({ tokens: 48135, contextWindow: 258400, percent: 19 }),
  };
}

test("Hooks translate every Pi event onto the canonical shape", async () => {
  const pi = fakePi();
  const hooks = fakeSpawn({ UserPromptSubmit: "focus: limen-usage.el:12" });
  const context = fakeContext();

  await createLimenHooks({
    env: { LIMEN_PROVIDER: "omp", LIMEN_COMMAND: "/usr/local/bin/limen" },
    spawn: hooks.spawn,
  })(pi);

  await pi.handlers.get("session_start")({ type: "session_start", reason: "new" }, context);
  await pi.handlers.get("tool_call")(
    { type: "tool_call", toolName: "edit", toolCallId: "call-1", input: { path: "/project/a.el" } },
    context,
  );
  await pi.handlers.get("tool_result")(
    { type: "tool_result", toolName: "edit", toolCallId: "call-1", input: { path: "/project/a.el" } },
    context,
  );
  await pi.handlers.get("agent_settled")({ type: "agent_settled" }, context);
  await pi.handlers.get("model_select")(
    { type: "model_select", model: { id: "claude-opus-5" } },
    context,
  );
  const injected = await pi.handlers.get("before_agent_start")(
    { type: "before_agent_start", prompt: "fix the column" },
    context,
  );
  await pi.handlers.get("session_shutdown")({ type: "session_shutdown", reason: "quit" }, context);
  await waitFor(() => hooks.calls.length === 7 && hooks.calls.every(({ payload }) => payload));

  const payloads = hooks.calls.map(({ payload }) => payload);
  assert.deepEqual(
    payloads.map(({ hook_event_name }) => hook_event_name),
    [
      "SessionStart",
      "PreToolUse",
      "PostToolUse",
      "Stop",
      "PostModelSwitch",
      "UserPromptSubmit",
      "SessionEnd",
    ],
  );
  for (const call of hooks.calls) {
    assert.equal(call.command, "/usr/local/bin/limen");
    assert.deepEqual(call.args, ["hook", "omp"]);
    assert.equal(call.payload.session_id, "session-7");
    assert.equal(call.payload.cwd, "/project");
  }

  const [start, pre, post, stop, switched, prompt, end] = payloads;
  assert.equal(start.source, "clear");
  assert.equal(start.model, "gpt-5.6-luna");
  assert.equal(pre.tool_name, "edit");
  assert.equal(pre.tool_use_id, "call-1");
  assert.equal(post.tool_input.file_path, "/project/a.el");
  assert.equal(stop.context_tokens, 48135);
  assert.equal(stop.context_window, 258400);
  assert.equal(stop.stop_hook_active, false);
  assert.equal(switched.to_model, "claude-opus-5");
  assert.equal(prompt.prompt, "fix the column");
  assert.equal(end.reason, "quit");

  assert.equal(injected.message.customType, "limen-hook-context");
  assert.equal(injected.message.content, "focus: limen-usage.el:12");
});

test("Hooks fire without any Emacs route and inject nothing unanswered", async () => {
  const pi = fakePi();
  const hooks = fakeSpawn();

  await createLimenHooks({ env: { LIMEN_PROVIDER: "pi" }, spawn: hooks.spawn })(pi);
  const injected = await pi.handlers.get("before_agent_start")(
    { type: "before_agent_start", prompt: "carry on" },
    fakeContext(),
  );

  assert.equal(injected, undefined);
  assert.equal(hooks.calls.length, 1);
  assert.deepEqual(hooks.calls[0].args, ["hook", "pi"]);
});

test("Hooks name the harness they run under when nothing else does", async () => {
  const pi = fakePi();
  const hooks = fakeSpawn();

  await createLimenHooks({ env: {}, harness: "omp", spawn: hooks.spawn })(pi);
  await pi.handlers.get("agent_settled")({ type: "agent_settled" }, fakeContext());
  await waitFor(() => hooks.calls.length === 1);

  assert.deepEqual(hooks.calls[0].args, ["hook", "omp"]);
  assert.equal(hooks.calls[0].command, "limen");
});

test("Hooks register once when the module is loaded twice", async () => {
  const pi = fakePi();
  const hooks = fakeSpawn();
  const build = () => createLimenHooks({ env: { LIMEN_PROVIDER: "omp" }, spawn: hooks.spawn });

  await build()(pi);
  const registered = [...pi.handlers.keys()];
  await build()(pi);

  assert.deepEqual([...pi.handlers.keys()], registered);
  await pi.handlers.get("agent_settled")({ type: "agent_settled" }, fakeContext());
  await waitFor(() => hooks.calls.length > 0);
  assert.equal(hooks.calls.length, 1);
});
