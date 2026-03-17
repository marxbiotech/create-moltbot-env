import { WebSocketServer, WebSocket, type RawData } from "ws";

export interface RelayOptions {
  remoteUrl: string;
  token: string;
  localPort: number;
  localHost?: string;
  /** Extra HTTP headers for the remote WebSocket upgrade request (e.g. CF Access Service Token) */
  remoteHeaders?: Record<string, string>;
  /** Heartbeat interval in ms (default: 30000) */
  heartbeatInterval?: number;
  /** Max reconnect attempts before giving up (default: Infinity) */
  maxReconnects?: number;
}

interface BufferedMessage {
  data: RawData;
  isBinary: boolean;
}

interface RelayState {
  wss: WebSocketServer;
  remote: WebSocket | null;
  local: WebSocket | null;
  heartbeatTimer: ReturnType<typeof setInterval> | null;
  reconnectTimer: ReturnType<typeof setTimeout> | null;
  reconnectAttempt: number;
  shuttingDown: boolean;
  /** Messages from local buffered while remote is connecting */
  pendingMessages: BufferedMessage[];
}

const MAX_BACKOFF_MS = 30_000;
const BASE_BACKOFF_MS = 1_000;
const MAX_PENDING_MESSAGES = 1000;

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
    remoteHeaders = {},
    heartbeatInterval = 30_000,
    maxReconnects = Infinity,
  } = opts;

  const authHeaders: Record<string, string> = {
    ...remoteHeaders,
    "Authorization": `Bearer ${token}`,
  };

  const state: RelayState = {
    wss: new WebSocketServer({ port: localPort, host: localHost }),
    remote: null,
    local: null,
    heartbeatTimer: null,
    reconnectTimer: null,
    reconnectAttempt: 0,
    shuttingDown: false,
    pendingMessages: [],
  };

  log(`listening on ${localHost}:${localPort}`);
  log(`remote: ${remoteUrl}`);

  state.wss.on("error", (err: NodeJS.ErrnoException) => {
    if (err.code === "EADDRINUSE") {
      logError(`port ${localPort} already in use — is another relay running?`);
    } else {
      logError(`server error: ${err.message}`);
    }
    process.exit(1);
  });

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

    log("connecting to remote...");
    const remote = new WebSocket(remoteUrl, { headers: authHeaders });
    state.remote = remote;

    remote.on("open", () => {
      log("remote connected");
      state.reconnectAttempt = 0;
      startHeartbeat(remote);

      // Flush buffered messages from local
      if (state.pendingMessages.length > 0) {
        log(`flushing ${state.pendingMessages.length} buffered message(s)`);
        for (const msg of state.pendingMessages) {
          if (remote.readyState !== WebSocket.OPEN) {
            logError(`remote closed during flush — remaining messages lost`);
            break;
          }
          remote.send(msg.data, { binary: msg.isBinary }, (err) => {
            if (err) logError(`flush send error: ${err.message}`);
          });
        }
        state.pendingMessages = [];
      }

      // If local is already connected, wire up live relay
      if (state.local && state.local.readyState === WebSocket.OPEN) {
        wireRelay(state.local, remote);
      }
    });

    remote.on("close", (code) => {
      log(`remote closed (code: ${code})`);
      clearHeartbeat();
      state.remote = null;

      if (state.shuttingDown) return;

      // Reconnect if local is still alive (regardless of close code)
      if (state.local && state.local.readyState === WebSocket.OPEN) {
        scheduleReconnect();
      }
    });

    remote.on("error", (err) => {
      logError(`remote error: ${err.message}`);
      // 'close' event fires after 'error', reconnect handled there
    });
  }

  function scheduleReconnect() {
    if (state.shuttingDown) return;
    if (state.reconnectAttempt >= maxReconnects) {
      logError(`max reconnect attempts (${maxReconnects}) reached — shutting down`);
      shutdown();
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
        remote.send(data, { binary: isBinary }, (err) => {
          if (err) logError(`send to remote failed: ${err.message}`);
        });
      }
    });

    remote.on("message", (data, isBinary) => {
      const preview = isBinary
        ? `[binary ${Buffer.isBuffer(data) ? data.length : "?"}B]`
        : String(data).slice(0, 200);
      log(`remote→local: ${preview}`);
      if (local.readyState === WebSocket.OPEN) {
        local.send(data, { binary: isBinary }, (err) => {
          if (err) logError(`send to local failed: ${err.message}`);
        });
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
    state.pendingMessages = [];

    local.on("close", (code) => {
      log(`local closed (code: ${code})`);
      state.local = null;
      state.pendingMessages = [];
      // Close remote when local disconnects (clean up server-side resources)
      if (state.remote && state.remote.readyState === WebSocket.OPEN) {
        state.remote.close(1000, "local disconnected");
      }
    });

    local.on("error", (err) => {
      logError(`local error: ${err.message}`);
    });

    // If remote is already connected and open, wire up immediately
    if (state.remote && state.remote.readyState === WebSocket.OPEN) {
      wireRelay(local, state.remote);
    } else {
      // Buffer local messages until remote is ready
      local.on("message", (data, isBinary) => {
        const preview = isBinary
          ? `[binary ${Buffer.isBuffer(data) ? data.length : "?"}B]`
          : String(data).slice(0, 200);
        log(`local→buffer: ${preview}`);
        if (state.pendingMessages.length >= MAX_PENDING_MESSAGES) {
          logError(`buffer full (${MAX_PENDING_MESSAGES} messages) — dropping oldest`);
          state.pendingMessages.shift();
        }
        state.pendingMessages.push({ data, isBinary });
      });

      // Lazy: connect remote when first local client arrives
      if (!state.remote || state.remote.readyState >= WebSocket.CLOSING) {
        connectRemote();
      }
      // else: remote is CONNECTING, wait for open event
    }
  });

  // Lazy connection: don't connect to remote until a local client arrives.
  // This avoids the container gateway timing out an idle WebSocket (which would
  // close with 1000 before openclaw has a chance to send the connect challenge).

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
