import { execFileSync } from "child_process";
import fs from "fs";
import path from "path";

export interface MoltbotEnvConfig {
  appRepo: string;
  envRepo: string;
  cfAccountId: string;
  workersSubdomain: string;
  cfAccessTeamDomain: string;
  accessPolicyEmail: string;
  managerAgeKey: string;
  credentials: {
    sopsAgeKey?: CredentialSource;
    cfAccessApiToken?: CredentialSource;
  };
}

interface CredentialSource {
  source: string;
  keychainAccount?: string;
  keychainService?: string;
}

export interface OverlayVars {
  WORKER_URL: string;
  NODE_ROUTE?: string;
  [key: string]: string | undefined;
}

/**
 * Walk up from `startDir` looking for `.moltbot-env.json`.
 * Returns the directory containing it (the moltbot-env root).
 */
export function findEnvRoot(startDir: string): string {
  let dir = path.resolve(startDir);
  while (true) {
    if (fs.existsSync(path.join(dir, ".moltbot-env.json"))) {
      return dir;
    }
    const parent = path.dirname(dir);
    if (parent === dir) {
      throw new Error(
        "Could not find .moltbot-env.json — are you inside a moltbot-env repo?"
      );
    }
    dir = parent;
  }
}

/**
 * Read and parse `.moltbot-env.json` from the given root directory.
 */
export function readConfig(root: string): MoltbotEnvConfig {
  const configPath = path.join(root, ".moltbot-env.json");
  const raw = fs.readFileSync(configPath, "utf8");
  try {
    return JSON.parse(raw) as MoltbotEnvConfig;
  } catch (err) {
    throw new Error(`Invalid JSON in ${configPath}: ${err instanceof Error ? err.message : err}`);
  }
}

/**
 * Strip JSONC comments and trailing commas, return parsed JSON.
 * Reuses the same logic as scripts/jsonc-strip.js but inline.
 */
export function parseJsonc(text: string): Record<string, unknown> {
  // Strip // comments (not inside strings)
  let stripped = text.replace(
    /("(?:[^"\\]|\\.)*")|\/\/[^\n]*/g,
    (_, str) => str || ""
  );
  // Strip /* */ block comments
  stripped = stripped.replace(
    /("(?:[^"\\]|\\.)*")|\/\*[\s\S]*?\*\//g,
    (_, str) => str || ""
  );
  // Remove trailing commas before } or ]
  stripped = stripped.replace(/,(\s*[}\]])/g, "$1");
  return JSON.parse(stripped);
}

/**
 * Read overlay wrangler.jsonc and return the vars block.
 */
export function readOverlayVars(root: string, envName: string): OverlayVars {
  const wranglerPath = path.join(root, "overlays", envName, "wrangler.jsonc");
  if (!fs.existsSync(wranglerPath)) {
    throw new Error(`Overlay not found: overlays/${envName}/wrangler.jsonc`);
  }
  const raw = fs.readFileSync(wranglerPath, "utf8");
  let config: Record<string, unknown>;
  try {
    config = parseJsonc(raw);
  } catch (err) {
    throw new Error(`Failed to parse ${wranglerPath}: ${err instanceof Error ? err.message : err}`);
  }
  const vars = config.vars as Record<string, string> | undefined;
  if (!vars) {
    throw new Error(`No vars block in overlays/${envName}/wrangler.jsonc`);
  }
  return vars as OverlayVars;
}

/**
 * Load a credential from macOS Keychain based on config.
 */
export function loadKeychainCredential(cred: CredentialSource): string {
  if (cred.source !== "keychain") {
    throw new Error(`Unsupported credential source: ${cred.source}`);
  }
  if (!cred.keychainAccount || !cred.keychainService) {
    throw new Error("Keychain credential missing account or service");
  }
  try {
    return execFileSync(
      "security",
      [
        "find-generic-password",
        "-a",
        cred.keychainAccount,
        "-s",
        cred.keychainService,
        "-w",
      ],
      { encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] }
    ).trim();
  } catch (err) {
    throw new Error(
      `Failed to load from Keychain: account=${cred.keychainAccount}, service=${cred.keychainService}: ${err instanceof Error ? err.message : err}`
    );
  }
}

/**
 * Decrypt a single key from a SOPS-encrypted JSON file.
 */
export function decryptSopsKey(
  filePath: string,
  key: string,
  sopsAgeKey: string
): string {
  try {
    return execFileSync(
      "sops",
      ["--decrypt", "--extract", `["${key}"]`, filePath],
      {
        encoding: "utf8",
        env: { ...process.env, SOPS_AGE_KEY: sopsAgeKey },
        stdio: ["pipe", "pipe", "pipe"],
      }
    ).trim();
  } catch (err) {
    throw new Error(
      `Failed to decrypt ${key} from ${filePath}: ${err instanceof Error ? err.message : err}`
    );
  }
}
