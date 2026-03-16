#!/usr/bin/env node
import { execFileSync } from "child_process";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import prompts from "prompts";
import chalk from "chalk";
import ejs from "ejs";
import { diff } from "./diff.js";
import { node } from "./node.js";
import { getCliVersion } from "./utils.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TEMPLATES_DIR = path.resolve(__dirname, "..", "templates");

interface TemplateVars {
  appRepo: string;
  envRepo: string;
  cfAccountId: string;
  workersSubdomain: string;
  cfAccessTeamDomain: string;
  accessPolicyEmail: string;
  managerAgeKey: string;
  version: string;
  createdAt: string;
}

function banner() {
  console.log();
  console.log(chalk.bold("create-moltbot-env"));
  console.log(chalk.dim("Scaffold a moltbot-env GitOps repository"));
  console.log();
}

function commandExists(cmd: string): boolean {
  try {
    execFileSync("which", [cmd], { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

async function main() {
  // Route subcommands
  const subcommand = process.argv[2];
  if (subcommand === "diff") {
    await diff(process.argv.slice(3));
    return;
  }
  if (subcommand === "node") {
    await node(process.argv.slice(3));
    return;
  }

  banner();

  const response = await prompts(
    [
      {
        type: "text",
        name: "projectDir",
        message: "Project directory name",
        initial: "moltbot-env",
        validate: (v: string) =>
          fs.existsSync(path.resolve(process.cwd(), v))
            ? `Directory "${v}" already exists`
            : true,
      },
      {
        type: "text",
        name: "cfAccountId",
        message: "Cloudflare Account ID",
        validate: (v: string) =>
          /^[a-f0-9]{32}$/.test(v) ? true : "Must be a 32-character hex string",
      },
      {
        type: "text",
        name: "workersSubdomain",
        message: 'Workers subdomain (e.g. "myteam" for myteam.workers.dev)',
        validate: (v: string) =>
          /^[a-z0-9][a-z0-9-]*[a-z0-9]$/.test(v) || /^[a-z0-9]$/.test(v)
            ? true
            : "Must be lowercase kebab-case",
      },
      {
        type: "text",
        name: "cfAccessTeamDomain",
        message: "Cloudflare Access team domain",
        initial: (_: unknown, values: Record<string, string>) =>
          `${values.workersSubdomain}.cloudflareaccess.com`,
        validate: (v: string) => (v.length > 0 ? true : "Required"),
      },
      {
        type: "text",
        name: "accessPolicyEmail",
        message: "Access policy email (for initial allow-list)",
        validate: (v: string) =>
          /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v) ? true : "Must be a valid email",
      },
      {
        type: "text",
        name: "appRepo",
        message: "App repo (owner/repo slug)",
        initial: "marxbiotech/moltbot-app",
        validate: (v: string) =>
          /^[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+$/.test(v)
            ? true
            : 'Must be owner/repo format (e.g. "marxbiotech/moltbot-app")',
      },
      {
        type: "text",
        name: "envRepo",
        message: "Env repo (owner/repo slug)",
        initial: (_: unknown, values: Record<string, string>) => {
          const owner = values.appRepo?.split("/")[0] ?? "owner";
          return `${owner}/moltbot-env`;
        },
        validate: (v: string) =>
          /^[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+$/.test(v)
            ? true
            : 'Must be owner/repo format (e.g. "myorg/moltbot-env")',
      },
      {
        type: "confirm",
        name: "generateAge",
        message: "Generate AGE manager key pair?",
        initial: true,
      },
      {
        type: (prev: boolean) => (prev ? null : "text"),
        name: "existingAgeKey",
        message: "Existing AGE public key",
        validate: (v: string) =>
          v.startsWith("age1") ? true : 'Must start with "age1"',
      },
    ],
    { onCancel: () => process.exit(1) }
  );

  // Resolve AGE key
  let managerAgeKey: string;
  let agePrivateKey: string | null = null;

  if (response.generateAge) {
    if (!commandExists("age-keygen")) {
      console.error(
        chalk.red("Error: age-keygen not found. Install age: https://github.com/FiloSottile/age")
      );
      process.exit(1);
    }

    console.log();
    console.log("Generating AGE key pair...");
    // age-keygen outputs public key line to stderr, private key to stdout
    const output = execFileSync("age-keygen", [], {
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    });
    // stdout contains lines like:
    // # created: 2024-01-01T00:00:00Z
    // # public key: age1...
    // AGE-SECRET-KEY-1...
    const pubMatch = output.match(/public key: (age1\w+)/);
    const privMatch = output.match(/(AGE-SECRET-KEY-\S+)/);

    if (!pubMatch || !privMatch) {
      console.error(chalk.red("Error: Could not parse age-keygen output"));
      process.exit(1);
    }

    managerAgeKey = pubMatch[1];
    agePrivateKey = privMatch[1];

    console.log(chalk.green("  ✔ Key pair generated"));
    console.log(chalk.dim(`  Public key: ${managerAgeKey}`));

    // Try to save to macOS Keychain
    if (process.platform === "darwin") {
      try {
        execFileSync(
          "security",
          [
            "add-generic-password",
            "-a", "sops-age",
            "-s", "sops-age-key",
            "-w", agePrivateKey,
            "-U", // update if exists
          ],
          { stdio: "pipe" }
        );
        console.log(chalk.green("  ✔ Private key saved to macOS Keychain (sops-age)"));
      } catch {
        console.log(
          chalk.yellow("  ⚠ Could not save to Keychain — save the private key manually")
        );
      }
    }

    console.log();
    console.log(chalk.bold.yellow("  ⚠ Save this private key somewhere safe:"));
    console.log(chalk.cyan(`  ${agePrivateKey}`));
    console.log();
  } else {
    managerAgeKey = response.existingAgeKey;
  }

  const vars: TemplateVars = {
    appRepo: response.appRepo,
    envRepo: response.envRepo,
    cfAccountId: response.cfAccountId,
    workersSubdomain: response.workersSubdomain,
    cfAccessTeamDomain: response.cfAccessTeamDomain,
    accessPolicyEmail: response.accessPolicyEmail,
    managerAgeKey,
    version: getCliVersion(),
    createdAt: new Date().toISOString().slice(0, 10),
  };

  const targetDir = path.resolve(process.cwd(), response.projectDir);

  console.log("Scaffolding project...");
  scaffold(targetDir, vars);

  // Init git repo
  try {
    execFileSync("git", ["init"], { cwd: targetDir, stdio: "pipe" });
    execFileSync("git", ["add", "-A"], { cwd: targetDir, stdio: "pipe" });
    execFileSync("git", ["commit", "-m", "Initial scaffold from @marxbiotech/create-moltbot-env"], {
      cwd: targetDir,
      stdio: "pipe",
    });
    console.log(chalk.green("✔ Initialized git repo with initial commit"));
  } catch {
    console.log(chalk.yellow("⚠ Could not initialize git repo"));
  }

  console.log();
  console.log(chalk.green(`✔ Created ${response.projectDir}/`));
  console.log();
  console.log(chalk.bold("Next steps:"));
  console.log(`  cd ${response.projectDir}`);
  console.log("  npx wrangler login");
  console.log("  bash scripts/create-env.sh <env-name>");
  if (agePrivateKey) {
    console.log();
    console.log(chalk.dim("To use SOPS, set the AGE key:"));
    console.log(
      chalk.dim(
        '  export SOPS_AGE_KEY=$(security find-generic-password -a "sops-age" -s "sops-age-key" -w 2>/dev/null)'
      )
    );
  }
  console.log();
}

function scaffold(targetDir: string, vars: TemplateVars) {
  fs.mkdirSync(targetDir, { recursive: true });

  // Walk templates directory
  walkDir(TEMPLATES_DIR, (templatePath) => {
    const relativePath = path.relative(TEMPLATES_DIR, templatePath);
    const isEjs = templatePath.endsWith(".ejs");
    let outputRelative = isEjs ? relativePath.replace(/\.ejs$/, "") : relativePath;
    // npm strips .gitignore from packages, so we ship it as "gitignore" and rename here
    if (path.basename(outputRelative) === "gitignore") {
      outputRelative = path.join(path.dirname(outputRelative), ".gitignore");
    }
    const outputPath = path.join(targetDir, outputRelative);

    fs.mkdirSync(path.dirname(outputPath), { recursive: true });

    if (isEjs) {
      const template = fs.readFileSync(templatePath, "utf8");
      const rendered = ejs.render(template, vars);
      fs.writeFileSync(outputPath, rendered);
    } else {
      fs.copyFileSync(templatePath, outputPath);
    }

    // Make .sh files executable
    if (outputPath.endsWith(".sh")) {
      fs.chmodSync(outputPath, 0o755);
    }
  });

  // Create empty overlays directory
  fs.mkdirSync(path.join(targetDir, "overlays"), { recursive: true });
}

function walkDir(dir: string, callback: (filePath: string) => void) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walkDir(fullPath, callback);
    } else {
      callback(fullPath);
    }
  }
}

main().catch((err) => {
  console.error(chalk.red("Error:"), err.message);
  process.exit(1);
});
