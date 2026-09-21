const LOADED = Symbol.for("limen.hooks.loaded");

const SESSION_SOURCES = {
  startup: "startup",
  new: "clear",
  resume: "resume",
  fork: "fork",
};

function harnessName() {
  const path = typeof process === "undefined" ? null : process.execPath;
  const name = typeof path === "string" ? path.split("/").pop() : null;
  return name === "omp" ? "omp" : "pi";
}

function sessionFields(context) {
  const manager = context?.sessionManager;
  return {
    session_id: manager?.getSessionId?.(),
    cwd: manager?.getCwd?.() ?? context?.cwd,
  };
}

function usageFields(context) {
  const usage = context?.getContextUsage?.();
  if (!usage || typeof usage.tokens !== "number") return {};
  return {
    context_tokens: usage.tokens,
    ...(typeof usage.contextWindow === "number"
      ? { context_window: usage.contextWindow }
      : {}),
  };
}

function editFields(input) {
  if (!input || typeof input !== "object") return {};
  const path = typeof input.path === "string" ? input.path : undefined;
  return { tool_input: path ? { ...input, file_path: path } : input };
}

export function createHookCaller(options = {}) {
  const env = options.env ?? process.env;
  const provider = env.LIMEN_PROVIDER ?? options.harness ?? harnessName();
  const command = env.LIMEN_COMMAND ?? "limen";
  let loading;
  const spawned = () =>
    options.spawn
      ? Promise.resolve(options.spawn)
      : (loading ??= import("node:child_process")
          .then((module) => module.spawn)
          .catch(() => null));

  return async function callHook(event, fields) {
    const spawn = await spawned();
    if (!spawn) return null;
    return new Promise((resolve) => {
      let child;
      try {
        child = spawn(command, ["hook", provider], {
          env,
          stdio: ["pipe", "pipe", "ignore"],
        });
      } catch {
        resolve(null);
        return;
      }
      let answer = "";
      child.stdout?.setEncoding?.("utf8");
      child.stdout?.on?.("data", (chunk) => {
        answer += chunk;
      });
      child.on?.("error", () => resolve(null));
      child.on?.("close", () => {
        try {
          const context = JSON.parse(answer)?.hookSpecificOutput?.additionalContext;
          resolve(typeof context === "string" && context !== "" ? context : null);
        } catch {
          resolve(null);
        }
      });
      child.stdin?.end?.(JSON.stringify({ hook_event_name: event, ...fields }));
    });
  };
}

export function createLimenHooks(options = {}) {
  const callHook = createHookCaller(options);

  return async function limenHooks(pi) {
    if (pi[LOADED]) return;
    pi[LOADED] = true;

    pi.on("session_start", (event, context) =>
      callHook("SessionStart", {
        source: SESSION_SOURCES[event?.reason] ?? "startup",
        model: context?.model?.id,
        ...sessionFields(context),
        ...usageFields(context),
      }),
    );

    pi.on("before_agent_start", async (event, context) => {
      const answer = await callHook("UserPromptSubmit", {
        prompt: event?.prompt,
        ...sessionFields(context),
      });
      if (!answer) return undefined;
      return {
        message: { customType: "limen-hook-context", content: answer, display: true },
      };
    });

    pi.on("tool_call", (event, context) => {
      callHook("PreToolUse", {
        tool_name: event?.toolName,
        tool_use_id: event?.toolCallId,
        ...editFields(event?.input),
        ...sessionFields(context),
      });
    });

    pi.on("tool_result", (event, context) => {
      callHook("PostToolUse", {
        tool_name: event?.toolName,
        tool_use_id: event?.toolCallId,
        ...editFields(event?.input),
        ...sessionFields(context),
      });
    });

    pi.on("agent_settled", (_event, context) => {
      callHook("Stop", {
        stop_hook_active: false,
        ...sessionFields(context),
        ...usageFields(context),
      });
    });

    pi.on("model_select", (event, context) => {
      callHook("PostModelSwitch", {
        to_model: event?.model?.id ?? event?.model,
        ...sessionFields(context),
        ...usageFields(context),
      });
    });

    pi.on("session_shutdown", (event, context) =>
      callHook("SessionEnd", { reason: event?.reason, ...sessionFields(context) }),
    );
  };
}
