# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`@marxbiotech/create-moltbot-env` is a scaffold CLI (`npx @marxbiotech/create-moltbot-env`) that generates a moltbot-env GitOps repository for deploying [moltbot-app](https://github.com/marxbiotech/moltbot-app) on Cloudflare Workers. It also provides an agent-native upgrade mechanism via the `diff` subcommand.

## Commands

```bash
npm run build          # tsup → dist/ (ESM, two entry points: index.ts + diff.ts)
node dist/index.js     # Run scaffold interactively (local test)
node dist/index.js diff # Run diff subcommand (must be in a moltbot-env repo)
npm publish --access public  # Publish to npm
```

## Architecture

### Two CLI modes

1. **Scaffold** (`npx @marxbiotech/create-moltbot-env`) — `src/index.ts`: interactive prompts → collect 6 template variables + AGE key → render EJS templates → copy static files → `chmod +x` shell scripts → `git init` + initial commit.
2. **Diff** (`npx @marxbiotech/create-moltbot-env diff`) — `src/diff.ts`: reads version metadata from `.moltbot-env.json` (or legacy `.moltbot-env-meta.json` for v0.1.x repos) → compares version against CLI's `package.json` version → builds migration chain from `migrations/*.md` → outputs markdown instructions to stdout. Supports `--json` flag. Exit 0 = migrations found, exit 1 = up-to-date or no path.

### Template rendering

EJS templates (`templates/**/*.ejs`) are rendered with these variables, then written with the `.ejs` suffix stripped. Non-EJS files are copied verbatim.

```typescript
interface TemplateVars {
  cfAccountId: string;        // 32-char hex Cloudflare Account ID
  workersSubdomain: string;   // e.g. "myteam" → *.myteam.workers.dev
  cfAccessTeamDomain: string; // e.g. "myteam.cloudflareaccess.com"
  accessPolicyEmail: string;  // email for CF Access allow-list
  appRepo: string;            // git URL for moltbot-app
  envRepo: string;            // GitHub slug for moltbot-env (e.g. "org/moltbot-env")
  managerAgeKey: string;      // AGE public key (age1...)
  version: string;            // CLI package.json version
  createdAt: string;          // ISO date (YYYY-MM-DD)
}
```

### Agent-native migration system

Instead of traditional diff/patch, migrations are markdown files with natural language instructions. The CLI is a pure data tool (computes what changed); Claude Code is the executor (applies changes semantically). The user runs `/upgrade` in their scaffolded repo, which calls `npx @marxbiotech/create-moltbot-env diff` and applies each instruction.

Migration files in `migrations/` are named `<from>-to-<to>.md` (e.g. `0.1.0-to-0.2.0.md`). The diff command chains them: `0.1.0 → 0.2.0 → 0.3.0`.

### Migration instruction conventions

1. **Idempotent** — "Ensure X exists" not "Add X"
2. **Semantic targets** — reference files by purpose, not line number
3. **Self-contained** — each instruction includes exact content/command
4. **Scoped** — one logical change per instruction
5. **Static files = overwrite** — for files users don't customize, "Replace file X with this content: ..."
6. **Verification hint** — each instruction ends with how to verify success

## Adding a New Template Variable

1. Add to `TemplateVars` interface in `src/index.ts`
2. Add a prompt in the `prompts()` array
3. Pass through in the `vars` object
4. Use `<%= varName %>` in `.ejs` templates

## When Bumping Version

Every time a template file changes, you must also:
1. Write a migration file `migrations/<old>-to-<new>.md` with atomic instructions
2. Bump `version` in `package.json`
3. Rebuild with `npm run build`

## Generated Repo Structure

The scaffold produces a moltbot-env repo with this layout:

```
moltbot-env/
├── .moltbot-env.json              # Runtime config (account IDs, repo slugs, credentials, version)
├── .sops.yaml                     # SOPS creation rules (starts with empty array)
├── Makefile                       # Shared make targets (deploy, secret, ensure-queue, etc.)
├── .claude/commands/
│   ├── create-env.md              # Claude Code command: create environment
│   ├── delete-env.md              # Claude Code command: delete environment
│   └── upgrade.md                 # Claude Code command: agent-native upgrade
├── .github/workflows/
│   └── deploy.yml                 # CI/CD: auto-deploy on overlay changes
├── scripts/
│   ├── deploy.sh                  # Clone app → merge config → wrangler deploy
│   ├── create-env.sh              # R2 bucket + CF Access + overlay scaffold
│   ├── delete-env.sh              # Reverse of create-env
│   ├── ensure-queue.sh            # Ensure Cloudflare Queues exist for overlay config
│   ├── setup-env-age-key.sh       # Generate/regenerate AGE key pair for environment
│   ├── sync-access.sh             # Reconcile CF Access webhook bypass apps
│   └── jsonc-strip.js             # JSONC → JSON converter
├── docs/
│   ├── cf-api-token.md            # How to create CF Access API token
│   └── sops-age.md                # SOPS + AGE secret management guide
└── overlays/                      # Empty — environments created via create-env.sh
```
