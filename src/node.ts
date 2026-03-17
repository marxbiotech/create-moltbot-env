import { spawn } from "child_process";
import os from "os";
import chalk from "chalk";
import {
  findEnvRoot,
  readConfig,
  readOverlayVars,
  loadKeychainCredential,
  decryptSopsKey,
} from "./config-reader.js";
import { startRelay } from "./ws-relay.js";

const DEFAULT_PORT = 18790;

function usage(): never {
  console.error("Usage: create-moltbot-env node --env <name> [--node-name <name>] [--port <n>]");
  process.exit(1);
}

function parseArgs(argv: string[]): {
  envName: string;
  nodeName?: string;
  port: number;
} {
  let envName = "";
  let nodeName: string | undefined;
  let port = DEFAULT_PORT;

  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case "--env":
        envName = argv[++i] || "";
        break;
      case "--node-name":
        nodeName = argv[++i] || "";
        break;
      case "--port":
        port = parseInt(argv[++i] || "", 10);
        if (isNaN(port)) {
          console.error("Error: --port must be a number");
          process.exit(1);
        }
        break;
      default:
        console.error(`Unknown option: ${argv[i]}`);
        usage();
    }
  }

  if (!envName) usage();
  return { envName, nodeName, port };
}

export async function node(argv: string[]): Promise<void> {
  const { envName, nodeName, port } = parseArgs(argv);
  const displayName = nodeName || `${envName}-${os.hostname().split(".")[0]}`;

  // 1. Find moltbot-env root
  const root = findEnvRoot(process.cwd());
  console.log(chalk.dim(`moltbot-env root: ${root}`));

  // 2. Read config
  const config = readConfig(root);

  // 3. Read overlay vars
  const vars = readOverlayVars(root, envName);
  if (!vars.WORKER_URL) {
    console.error(chalk.red(`Error: WORKER_URL not set in overlays/${envName}/wrangler.jsonc`));
    process.exit(1);
  }
  if (!vars.NODE_ROUTE) {
    console.error(chalk.red(`Error: NODE_ROUTE not set in overlays/${envName}/wrangler.jsonc`));
    process.exit(1);
  }

  // 4. Load SOPS_AGE_KEY from Keychain
  const sopsCredConfig = config.credentials.sopsAgeKey;
  let sopsAgeKey = process.env.SOPS_AGE_KEY || "";
  if (!sopsAgeKey && sopsCredConfig) {
    console.log(chalk.dim("Loading SOPS_AGE_KEY from Keychain..."));
    sopsAgeKey = loadKeychainCredential(sopsCredConfig);
  }
  if (!sopsAgeKey) {
    console.error(chalk.red("Error: SOPS_AGE_KEY not available (set env var or configure Keychain)"));
    process.exit(1);
  }

  // 5. Decrypt MOLTBOT_GATEWAY_TOKEN
  const secretsPath = `${root}/overlays/${envName}/secrets.json`;
  console.log(chalk.dim("Decrypting MOLTBOT_GATEWAY_TOKEN..."));
  const gatewayToken = decryptSopsKey(secretsPath, "MOLTBOT_GATEWAY_TOKEN", sopsAgeKey);

  // 6. Compute relay URL
  const workerHost = new URL(vars.WORKER_URL).host;
  const relayUrl = `wss://${workerHost}${vars.NODE_ROUTE}`;

  // 7. Build remote headers (CF Access Service Token from env vars)
  const remoteHeaders: Record<string, string> = {};
  const clientId = process.env.CF_ACCESS_CLIENT_ID;
  const clientSecret = process.env.CF_ACCESS_CLIENT_SECRET;
  if (clientId && clientSecret) {
    remoteHeaders["CF-Access-Client-Id"] = clientId;
    remoteHeaders["CF-Access-Client-Secret"] = clientSecret;
  } else {
    console.log(chalk.yellow("Warning: CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET not set — relay will connect without Service Token"));
  }

  console.log();
  console.log(chalk.bold(`Node: ${displayName}`));
  console.log(chalk.dim(`Relay: localhost:${port} → ${relayUrl}`));
  console.log();

  // 8. Start ws-relay
  const relay = startRelay({
    remoteUrl: relayUrl,
    token: gatewayToken,
    localPort: port,
    remoteHeaders,
  });

  // 9. Spawn openclaw node run
  const child = spawn(
    "openclaw",
    ["node", "run", "--host", "127.0.0.1", "--port", String(port), "--display-name", displayName],
    {
      env: { ...process.env, OPENCLAW_GATEWAY_TOKEN: gatewayToken },
      stdio: "inherit",
    }
  );

  child.on("error", (err) => {
    console.error(chalk.red(`Failed to start openclaw: ${err.message}`));
    relay.shutdown();
    process.exit(1);
  });

  let signalReceived = false;

  child.on("exit", (code) => {
    if (signalReceived) return; // shutdown handled by signal handler
    console.log(chalk.dim(`openclaw node exited (code: ${code})`));
    relay.shutdown();
    process.exit(code ?? 0);
  });

  // 10. Graceful shutdown on SIGINT/SIGTERM
  function handleSignal(signal: string) {
    if (signalReceived) return;
    signalReceived = true;
    console.log(chalk.dim(`\nReceived ${signal}, shutting down...`));
    child.kill("SIGTERM");
    relay.shutdown();
    // Give child time to exit gracefully, then force kill
    setTimeout(() => {
      child.kill("SIGKILL");
      process.exit(1);
    }, 5000);
  }

  process.on("SIGINT", () => handleSignal("SIGINT"));
  process.on("SIGTERM", () => handleSignal("SIGTERM"));
}
