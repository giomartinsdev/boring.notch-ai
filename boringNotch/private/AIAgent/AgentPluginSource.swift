//
//  AgentPluginSource.swift
//  boringNotch
//
//  The OpenCode bridge plugin source, embedded so the app can install it
//  into ~/.config/opencode/plugins/ without shipping a resource bundle.
//

import Foundation

enum AgentPluginSource {
    static let fileName = "boring-notch.js"

    static let source = ##"""
// Boring Notch bridge plugin for OpenCode.
//
// Keeps a persistent Unix-socket channel open to the Boring Notch app and:
//   - forwards live agent events (sessions, prompts, tools, errors)
//   - surfaces permission / question requests and holds them until the
//     user answers from the notch
//   - executes REST commands on behalf of the app through the in-process
//     SDK fetch, which works for every OpenCode instance (TUI, run, serve)
//
// Fail-open principle: if Boring Notch is not running, or anything fails,
// the plugin stays silent and OpenCode continues completely unaffected.

import { connect } from "net";
import { homedir } from "os";
import { randomUUID } from "crypto";

const SOCKET_PATH =
  process.env.BORING_NOTCH_SOCKET_PATH ||
  `${homedir()}/Library/Application Support/boringNotch/agent-bridge.sock`;

const INSTANCE_ID = randomUUID();
const MANAGED = process.env.BORING_NOTCH_MANAGED === "1";

const RECONNECT_MIN_MS = 2_000;
const RECONNECT_MAX_MS = 30_000;
const PING_INTERVAL_MS = 25_000;
const HOLD_TIMEOUT_MS = 3_600_000; // permission / question hold: 1 hour

let wire = null; // active persistent connection

// ---------------------------------------------------------------------------
// Wire helpers
// ---------------------------------------------------------------------------

function writeLine(sock, obj) {
  try {
    sock.write(JSON.stringify(obj) + "\n");
    return true;
  } catch {
    return false;
  }
}

function send(obj) {
  if (wire && !wire.destroyed) return writeLine(wire, obj);
  return false;
}

// One-shot connection used before the persistent channel is established
// (or as a fallback when it is down).
function sendOnce(obj, timeoutMs = 4_000) {
  return new Promise((resolve) => {
    let settled = false;
    const done = (v) => {
      if (settled) return;
      settled = true;
      resolve(v);
    };
    let sock;
    try {
      sock = connect({ path: SOCKET_PATH }, () => {
        try {
          sock.write(JSON.stringify(obj) + "\n");
        } catch {
          done(null);
        }
      });
    } catch {
      done(null);
      return;
    }
    let buf = "";
    sock.on("data", (chunk) => {
      buf += chunk.toString("utf8");
      const i = buf.indexOf("\n");
      if (i >= 0) {
        const line = buf.slice(0, i).trim();
        let parsed = null;
        try {
          parsed = JSON.parse(line);
        } catch {}
        done(parsed);
        try {
          sock.destroy();
        } catch {}
      }
    });
    sock.on("error", () => {
      try {
        sock.destroy();
      } catch {}
      done(null);
    });
    sock.on("close", () => done(null));
    sock.setTimeout(timeoutMs, () => {
      try {
        sock.destroy();
      } catch {}
      done(null);
    });
  });
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

const msgRoles = new Map(); // messageID -> { role, sessionID }
const sessionCwd = new Map(); // sessionID -> directory
const sessions = new Map(); // sessionID -> { lastAssistantText }
const pendingHolds = new Map(); // requestID -> resolve(directive)
const pendingCommands = new Map(); // command id -> resolve(result)

function getSession(sid) {
  if (!sessions.has(sid)) sessions.set(sid, { lastAssistantText: "" });
  return sessions.get(sid);
}

// ---------------------------------------------------------------------------
// Event normalization
// ---------------------------------------------------------------------------

function baseEvent(type, sessionID) {
  return {
    type,
    sessionID,
    directory: sessionCwd.get(sessionID) || undefined,
  };
}

function titleFromInfo(info) {
  return typeof info?.title === "string" && info.title.trim() ? info.title.trim() : undefined;
}

function summarizeToolInput(input) {
  if (input == null) return "";
  if (typeof input === "string") return input.slice(0, 240);
  try {
    return JSON.stringify(input).slice(0, 240);
  } catch {
    return "";
  }
}

function describePermission(p) {
  const permission = p.permission || "action";
  const patterns = Array.isArray(p.patterns) ? p.patterns : [];
  const label = permission.charAt(0).toUpperCase() + permission.slice(1);
  let command = "";
  if (permission === "bash" && patterns.length > 0) command = patterns.join(" && ");
  else if (patterns.length > 0) command = patterns.join(", ");
  return {
    label,
    command,
    description: command
      ? `wants to ${permission}: ${command}`
      : `wants to run ${label}`,
  };
}

function normalizeQuestionOption(option) {
  if (typeof option === "string") return { label: option, description: "" };
  if (!option || typeof option !== "object") return null;
  const label = option.label || option.text || option.value || option.name;
  if (!label) return null;
  return {
    label: String(label),
    description: String(option.description || option.hint || option.detail || ""),
  };
}

function normalizeQuestion(question, index) {
  if (!question || typeof question !== "object") return null;
  const text = question.question || question.title || question.prompt;
  if (!text) return null;
  const options = Array.isArray(question.options)
    ? question.options.map(normalizeQuestionOption).filter(Boolean)
    : [];
  if (options.length === 0) return null;
  return {
    question: String(text),
    header: String(question.header || question.label || `Question ${index + 1}`),
    options,
    multiple: Boolean(question.multiple || question.multi_select || question.multiSelect),
    custom: Boolean(question.custom),
  };
}

function mapEvent(ev) {
  const t = ev?.type;
  const p = ev?.properties || {};

  if (t === "session.created" && p.info) {
    sessionCwd.set(p.info.id, p.info.directory);
    const e = baseEvent("session.start", p.info.id);
    e.title = titleFromInfo(p.info);
    return e;
  }

  if (t === "session.updated" && p.info) {
    if (p.info.directory) sessionCwd.set(p.info.id, p.info.directory);
    if (p.info.time?.archived) {
      sessions.delete(p.info.id);
      sessionCwd.delete(p.info.id);
      return baseEvent("session.end", p.info.id);
    }
    const title = titleFromInfo(p.info);
    if (title) {
      const e = baseEvent("session.title", p.info.id);
      e.title = title;
      return e;
    }
    return null;
  }

  if (t === "session.deleted" && p.info) {
    sessions.delete(p.info.id);
    sessionCwd.delete(p.info.id);
    return baseEvent("session.end", p.info.id);
  }

  if (t === "session.status" && p.sessionID) {
    if (p.status?.type === "busy") return baseEvent("session.busy", p.sessionID);
    if (p.status?.type === "idle") return baseEvent("session.idle", p.sessionID);
    return null;
  }

  if (t === "session.idle" && p.sessionID) {
    return baseEvent("session.idle", p.sessionID);
  }

  if (t === "session.error" && p.sessionID) {
    const e = baseEvent("session.error", p.sessionID);
    try {
      const err = p.error;
      e.message = err?.data?.message || err?.message || err?.name || "Unknown agent error";
    } catch {
      e.message = "Unknown agent error";
    }
    return e;
  }

  if (t === "message.updated" && p.info?.id && p.info?.sessionID) {
    msgRoles.set(p.info.id, { role: p.info.role, sessionID: p.info.sessionID });
    if (msgRoles.size > 400) {
      msgRoles.delete(msgRoles.keys().next().value);
    }
    return null;
  }

  if (t === "message.part.updated" && p.part?.type === "text" && p.part?.messageID) {
    const meta = msgRoles.get(p.part.messageID);
    if (!meta) return null;
    const text = p.part.text || "";
    if (meta.role === "user" && text) {
      const e = baseEvent("prompt.sent", meta.sessionID);
      e.text = text;
      return e;
    }
    if (meta.role === "assistant" && text) {
      getSession(meta.sessionID).lastAssistantText = text;
      const e = baseEvent("assistant.text", meta.sessionID);
      e.text = text;
      return e;
    }
    return null;
  }

  if (t === "message.part.updated" && p.part?.type === "tool" && p.part?.sessionID) {
    const st = p.part.state?.status;
    const toolName = p.part.tool || "tool";
    const cwd = sessionCwd.get(p.part.sessionID);
    if (st === "running" || st === "pending") {
      return {
        type: "tool.start",
        sessionID: p.part.sessionID,
        directory: cwd,
        tool: toolName,
        detail: summarizeToolInput(p.part.state?.input),
      };
    }
    if (st === "completed" || st === "error") {
      return {
        type: "tool.end",
        sessionID: p.part.sessionID,
        directory: cwd,
        tool: toolName,
        status: st === "error" ? "error" : "ok",
      };
    }
    return null;
  }

  return null;
}

// ---------------------------------------------------------------------------
// Plugin entry
// ---------------------------------------------------------------------------

export default async ({ client, serverUrl }) => {
  let origin = "http://localhost:4096";
  try {
    if (serverUrl) origin = new URL(serverUrl).origin;
  } catch {}

  let internalFetch = null;
  try {
    internalFetch = client?._client?.getConfig?.()?.fetch || null;
  } catch {
    internalFetch = null;
  }

  const envPassword = process.env.OPENCODE_SERVER_PASSWORD;
  const authHeader = envPassword
    ? "Basic " + Buffer.from(`opencode:${envPassword}`).toString("base64")
    : null;

  async function fetchInProcess(method, path, body) {
    const url = origin + path;
    const init = {
      method,
      headers: { "Content-Type": "application/json" },
    };
    if (body !== undefined) init.body = JSON.stringify(body);
    if (internalFetch) {
      return internalFetch(new Request(url, init));
    }
    const headers = { "Content-Type": "application/json" };
    if (authHeader) headers["Authorization"] = authHeader;
    return fetch(url, { ...init, headers });
  }

  async function replyPermission(requestID, directive) {
    const body = {
      reply: directive.type === "allow" ? "once" : directive.type === "always" ? "always" : "reject",
    };
    if (directive.type === "deny" && directive.reason) body.message = directive.reason;
    try {
      await fetchInProcess("POST", `/permission/${requestID}/reply`, body);
    } catch {}
  }

  async function replyQuestion(requestID, answers) {
    try {
      await fetchInProcess("POST", `/question/${requestID}/reply`, { answers });
    } catch {}
  }

  // ------------------------------------------------------------------
  // Persistent channel
  // ------------------------------------------------------------------

  let pingTimer = null;

  function handleAppMessage(msg) {
    const kind = msg?.kind;
    const data = msg?.data || {};

    if (kind === "directive") {
      const resolve = pendingHolds.get(data.requestID);
      if (resolve) {
        pendingHolds.delete(data.requestID);
        resolve(data);
      }
      return;
    }

    if (kind === "command") {
      const { id, method, path, body } = data;
      (async () => {
        let result;
        try {
          const resp = await fetchInProcess(method || "GET", path || "/api/health", body);
          const text = await resp.text();
          let parsed = null;
          try {
            parsed = JSON.parse(text);
          } catch {
            parsed = { raw: text.slice(0, 4000) };
          }
          result = { v: 1, kind: "command.result", data: { id, ok: resp.ok, status: resp.status, body: parsed } };
        } catch (e) {
          result = { v: 1, kind: "command.result", data: { id, ok: false, status: 0, error: String(e?.message || e) } };
        }
        send(result);
      })();
      return;
    }

    if (kind === "ping") {
      send({ v: 1, kind: "pong", data: { instanceID: INSTANCE_ID } });
    }
  }

  function startPing() {
    stopPing();
    pingTimer = setInterval(() => {
      send({ v: 1, kind: "ping", data: { instanceID: INSTANCE_ID } });
    }, PING_INTERVAL_MS);
  }

  function stopPing() {
    if (pingTimer) {
      clearInterval(pingTimer);
      pingTimer = null;
    }
  }

  function connectChannel() {
    let sock;
    try {
      sock = connect({ path: SOCKET_PATH });
    } catch {
      scheduleReconnect();
      return;
    }

    let buf = "";
    let gotHello = false;

    sock.on("connect", () => {
      wire = sock;
      writeLine(sock, {
        v: 1,
        kind: "hello",
        data: {
          instanceID: INSTANCE_ID,
          serverUrl: origin,
          authHeader,
          managed: MANAGED,
          directory: process.cwd(),
          pid: process.pid,
          agent: "opencode",
        },
      });
      startPing();
    });

    sock.on("data", (chunk) => {
      buf += chunk.toString("utf8");
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i).trim();
        buf = buf.slice(i + 1);
        if (!line) continue;
        let msg = null;
        try {
          msg = JSON.parse(line);
        } catch {
          continue;
        }
        if (msg?.kind === "hello") {
          gotHello = true;
          continue;
        }
        try {
          handleAppMessage(msg);
        } catch {}
      }
    });

    const onDown = () => {
      if (wire === sock) wire = null;
      stopPing();
      scheduleReconnect();
    };
    sock.on("error", onDown);
    sock.on("close", onDown);
  }

  let reconnectDelay = RECONNECT_MIN_MS;
  let reconnectTimer = null;
  let stopped = false;

  function scheduleReconnect() {
    if (stopped || reconnectTimer) return;
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      connectChannel();
      reconnectDelay = Math.min(reconnectDelay * 2, RECONNECT_MAX_MS);
    }, reconnectDelay);
  }

  connectChannel();

  // ------------------------------------------------------------------
  // Event hook
  // ------------------------------------------------------------------

  return {
    "event": async ({ event }) => {
      try {
        const t = event?.type;
        const p = event?.properties || {};

        // -- permission.asked: hold until the user answers in the notch ----
        if (t === "permission.asked" && p.id && p.sessionID) {
          const info = describePermission(p);
          const directive = await holdForDirective({
            v: 1,
            kind: "permission",
            data: {
              requestID: p.id,
              sessionID: p.sessionID,
              permission: p.permission || "",
              patterns: Array.isArray(p.patterns) ? p.patterns : [],
              label: info.label,
              command: info.command,
              description: info.description,
              directory: sessionCwd.get(p.sessionID),
            },
          });
          if (!directive || directive.type === "cancel") return;
          if (directive.type === "allow" || directive.type === "always" || directive.type === "deny") {
            await replyPermission(p.id, directive);
          }
          return;
        }

        // -- question.asked: hold until the user answers in the notch ------
        if (t === "question.asked" && p.id && p.sessionID) {
          const questions = Array.isArray(p.questions)
            ? p.questions.map(normalizeQuestion).filter(Boolean)
            : [];
          const directive = await holdForDirective({
            v: 1,
            kind: "question",
            data: {
              requestID: p.id,
              sessionID: p.sessionID,
              questions,
              directory: sessionCwd.get(p.sessionID),
            },
          });
          if (!directive || directive.type === "cancel") return;
          if (directive.type === "answer" && Array.isArray(directive.answers)) {
            await replyQuestion(p.id, directive.answers);
          }
          return;
        }

        // -- settled notifications (user replied in the TUI directly) ------
        if (t === "permission.replied" && p.sessionID) {
          const e = baseEvent("permission.settled", p.sessionID);
          e.requestID = p.requestID;
          emit(e);
          return;
        }
        if ((t === "question.replied" || t === "question.rejected") && p.sessionID) {
          const e = baseEvent("question.settled", p.sessionID);
          e.requestID = p.requestID;
          emit(e);
          return;
        }

        // -- regular lifecycle events --------------------------------------
        const mapped = mapEvent(event);
        if (!mapped) return;

        if (mapped.type === "session.idle") {
          const s = getSession(mapped.sessionID);
          if (s.lastAssistantText) mapped.reply = s.lastAssistantText;
        }

        emit(mapped);
      } catch {
        // Fail open: never break OpenCode because of the bridge.
      }
    },
  };

  function emit(mapped) {
    const ok = send({ v: 1, kind: "event", data: mapped });
    if (!ok) {
      // Channel down — fall back to a one-shot send so the app still
      // hears about lifecycle events while reconnecting.
      sendOnce({ v: 1, kind: "event", data: mapped }).catch(() => {});
    }
  }

  function holdForDirective(msg) {
    return new Promise((resolve) => {
      const rid = msg.data.requestID;
      let settled = false;
      const done = (v) => {
        if (settled) return;
        settled = true;
        pendingHolds.delete(rid);
        clearTimeout(timer);
        resolve(v);
      };
      pendingHolds.set(rid, done);
      const timer = setTimeout(() => done(null), HOLD_TIMEOUT_MS);
      const ok = send(msg);
      if (!ok) {
        // Channel down: try one-shot (works for fire-and-forget replies).
        sendOnce(msg, HOLD_TIMEOUT_MS).then((response) => {
          done(response?.data || null);
        });
      }
    });
  }
};

"""##
}
