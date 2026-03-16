import { WebSocketServer, WebSocket } from "ws";

export interface RelayOptions {
  remoteUrl: string;
  token: string;
  localPort: number;
  localHost?: string;
  /** Heartbeat interval in ms (default: 30000) */
  heartbeatInterval?: number;
  /** Max reconnect attempts before giving up (default: Infinity) */
  maxReconnects?: number;
}

interface RelayState {
  wss: WebSocketServer;
  remote: WebSocket | null;
  local: WebSocket | null;
  heartbeatTimer: ReturnType<typeof setInterval> | null;
  reconnectTimer: ReturnType<typeof setTimeout> | null;
  reconnectAttempt: number;
  shuttingDown: boolean;
}

const MAX_BACKOFF_MS = 30_000;
const BASE_BACKOFF_MS = 1_000;

function log(msg: string) {
  const ts = new Date().toISOString().slice(11, 23);
  console.log(`[${ts}] relay: ${msg}`);
}

function logError(msg: string) {
  const ts = new Date().toISOString().slice(11, 23);
  console.error(`[${ts}] relay: ${msg}`);
}

/**
 * Compute reconnect delay with exponential backoff + jitter.
 */
function reconnectDelay(attempt: number): number {
  const base = Math.min(BASE_BACKOFF_MS * 2 ** attempt, MAX_BACKOFF_MS);
  const jitter = Math.random() * base * 0.5;
  return base + jitter;
}

/**
 * Start the WebSocket relay server.
 * Returns a cleanup function for graceful shutdown.
 */
export function startRelay(opts: RelayOptions): { shutdown: () => void } {
  const {
    remoteUrl,
    token,
    localPort,
    localHost = "127.0.0.1",
    heartbeatInterval = 30_000,
    maxReconnects = Infinity,
  } = opts;

  const remoteWithToken = `${remoteUrl}?token=${token}`;

  const state: RelayState = {
    wss: new WebSocketServer({ port: localPort, host: localHost }),
    remote: null,
    local: null,
    heartbeatTimer: null,
    reconnectTimer: null,
    reconnectAttempt: 0,
    shuttingDown: false,
  };

  log(`listening on ${localHost}:${localPort}`);
  log(`remote: ${remoteUrl}`);

  function clearHeartbeat() {
    if (state.heartbeatTimer) {
      clearInterval(state.heartbeatTimer);
      state.heartbeatTimer = null;
    }
  }

  function clearReconnect() {
    if (state.reconnectTimer) {
      clearTimeout(state.reconnectTimer);
      state.reconnectTimer = null;
    }
  }

  function startHeartbeat(ws: WebSocket) {
    clearHeartbeat();
    state.heartbeatTimer = setInterval(() => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.ping();
      }
    }, heartbeatInterval);
  }

  function connectRemote() {
    if (state.shuttingDown) return;

    const remote = new WebSocket(remoteWithToken);
    state.remote = remote;

    remote.on("open", () => {
      log("remote connected");
      state.reconnectAttempt = 0;
      startHeartbeat(remote);

      // If local is already connected, wire up message relay
      if (state.local && state.local.readyState === WebSocket.OPEN) {
        wireRelay(state.local, remote);
      }
    });

    remote.on("close", (code) => {
      log(`remote closed (code: ${code})`);
      clearHeartbeat();
      state.remote = null;

      // Don't reconnect on normal close (1000) or if shutting down
      if (state.shuttingDown || code === 1000) return;

      scheduleReconnect();
    });

    remote.on("error", (err) => {
      logError(`remote error: ${err.message}`);
      // 'close' event fires after 'error', reconnect handled there
    });
  }

  function scheduleReconnect() {
    if (state.shuttingDown) return;
    if (state.reconnectAttempt >= maxReconnects) {
      logError(`max reconnect attempts (${maxReconnects}) reached, giving up`);
      return;
    }

    const delay = reconnectDelay(state.reconnectAttempt);
    state.reconnectAttempt++;
    log(`reconnecting in ${Math.round(delay)}ms (attempt ${state.reconnectAttempt})`);

    clearReconnect();
    state.reconnectTimer = setTimeout(() => connectRemote(), delay);
  }

  function wireRelay(local: WebSocket, remote: WebSocket) {
    // Remove any previous message listeners to avoid double-wiring
    local.removeAllListeners("message");
    remote.removeAllListeners("message");

    local.on("message", (data, isBinary) => {
      const preview = isBinary
        ? `[binary ${Buffer.isBuffer(data) ? data.length : "?"}B]`
        : String(data).slice(0, 200);
      log(`local→remote: ${preview}`);
      if (remote.readyState === WebSocket.OPEN) {
        remote.send(data, { binary: isBinary });
      }
    });

    remote.on("message", (data, isBinary) => {
      const preview = isBinary
        ? `[binary ${Buffer.isBuffer(data) ? data.length : "?"}B]`
        : String(data).slice(0, 200);
      log(`remote→local: ${preview}`);
      if (local.readyState === WebSocket.OPEN) {
        local.send(data, { binary: isBinary });
      }
    });
  }

  state.wss.on("connection", (local) => {
    log("local client connected");

    // Only one local client at a time
    if (state.local && state.local.readyState === WebSocket.OPEN) {
      log("closing previous local client");
      state.local.close(1000, "replaced by new connection");
    }
    state.local = local;

    local.on("close", (code) => {
      log(`local closed (code: ${code})`);
      state.local = null;
    });

    local.on("error", (err) => {
      logError(`local error: ${err.message}`);
    });

    // If remote is already connected, wire up immediately
    if (state.remote && state.remote.readyState === WebSocket.OPEN) {
      wireRelay(local, state.remote);
    }

    // If no remote connection, start one
    if (!state.remote || state.remote.readyState === WebSocket.CLOSED) {
      connectRemote();
    }
  });

  // Design Decision: Eager remote connection — connect immediately so the relay is
  // "warm" when openclaw node starts, avoiding ~200-500ms TLS+upgrade latency on
  // first message. Tradeoff: wastes a WebSocket if openclaw fails to start, and may
  // wake the container before the node is ready. For the `make node` interactive use
  // case this is acceptable. If resource usage becomes a concern, switch to lazy mode:
  // remove this call and only connectRemote() inside wss.on("connection"), plus guard
  // reconnect to only fire when state.local is alive.
  connectRemote();

  function shutdown() {
    if (state.shuttingDown) return;
    state.shuttingDown = true;
    log("shutting down...");

    clearHeartbeat();
    clearReconnect();

    if (state.remote && state.remote.readyState === WebSocket.OPEN) {
      state.remote.close(1000, "relay shutdown");
    }
    if (state.local && state.local.readyState === WebSocket.OPEN) {
      state.local.close(1000, "relay shutdown");
    }

    state.wss.close(() => {
      log("server closed");
    });
  }

  return { shutdown };
}
