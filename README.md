# create-moltbot-env

Scaffold a GitOps environment repository for deploying [moltbot-app](https://github.com/marxbiotech/moltbot-app) on Cloudflare Workers.

```bash
npx @marxbiotech/create-moltbot-env
```

## What It Does

Generates a complete `moltbot-env` repository with:

- **Overlay pattern** — per-environment config directories (`overlays/<env>/`) with Wrangler config, pinned app version, and SOPS-encrypted secrets
- **Make targets** — deploy, secret management, wrangler commands, CF Access sync
- **Shell scripts** — create/delete environments, deploy pipeline, Access app reconciliation
- **Claude Code commands** — `/create-env`, `/delete-env`, `/upgrade` for agent-assisted operations
- **Secret management** — SOPS + AGE encryption with multi-recipient support

## Prerequisites

Install these before running:

```bash
brew install sops age node jq
npm install -g wrangler
```

## Usage

```bash
npx @marxbiotech/create-moltbot-env
```

The CLI walks you through these prompts:

| Prompt | Example | Notes |
|--------|---------|-------|
| Project directory name | `moltbot-env` | Must not already exist |
| Cloudflare Account ID | `cc38da97...` | 32-character hex, from [CF dashboard](https://dash.cloudflare.com/) |
| Workers subdomain | `myteam` | Your `*.myteam.workers.dev` subdomain |
| CF Access team domain | `myteam.cloudflareaccess.com` | Auto-derived from subdomain |
| Access policy email | `you@example.com` | Email for initial Access allow-list |
| App repo slug | `marxbiotech/moltbot-app` | `owner/repo` format |
| Env repo slug | `marxbiotech/moltbot-env` | Auto-derived from app repo owner |
| Generate AGE key pair? | `Y` | Creates manager key for secret encryption |

On completion, the CLI:
1. Renders all templates with your values
2. Optionally generates an AGE key pair and saves to macOS Keychain
3. Initializes a git repo with an initial commit

## Generated Repository

```
moltbot-env/
├── .moltbot-env.json                # Runtime config (account IDs, repo slugs, credentials, version)
├── .sops.yaml                       # SOPS encryption rules (empty initially)
├── Makefile                         # Shared make targets
├── .claude/commands/
│   ├── create-env.md                # Claude Code: guided environment creation
│   ├── delete-env.md                # Claude Code: guided environment deletion
│   ├── setup-env-age-key.md         # Claude Code: AGE key setup for CI/CD
│   └── upgrade.md                   # Claude Code: agent-native upgrade
├── .github/workflows/
│   └── deploy.yml                   # CI/CD: auto-deploy on overlay changes
├── scripts/
│   ├── deploy.sh                    # Clone app → merge config → wrangler deploy
│   ├── create-env.sh                # Create: R2 bucket + CF Access + overlay
│   ├── delete-env.sh                # Delete: reverse of create-env
│   ├── ensure-queue.sh              # Ensure Cloudflare Queues exist
│   ├── setup-env-age-key.sh         # Generate/regenerate AGE key pair
│   ├── sync-access.sh               # Reconcile CF Access webhook bypass apps
│   └── jsonc-strip.js               # JSONC → JSON converter
├── docs/
│   ├── cf-api-token.md              # How to create CF Access API token
│   └── sops-age.md                  # SOPS + AGE guide
└── overlays/                        # Per-environment directories (created via create-env.sh)
```

## Quick Start

After scaffolding:

```bash
cd moltbot-env
npx wrangler login
```

### Create your first environment

The `create-env.sh` script requires a `CF_ACCESS_API_TOKEN` for Cloudflare Access API calls. Create one at [CF API Tokens](https://dash.cloudflare.com/profile/api-tokens) with **Account > Access: Apps and Policies > Edit** permission. See `docs/cf-api-token.md` for details.

```bash
CF_ACCESS_API_TOKEN="<token>" bash scripts/create-env.sh my-env
```

This creates:
- R2 bucket (`moltbot-my-env-data`)
- Cloudflare Access app with email policy
- Overlay directory with `wrangler.jsonc`, `version.txt`, Makefile symlink
- `.sops.yaml` rule for the new environment

### Create and encrypt secrets

```bash
cd overlays/my-env
make edit-secrets    # Opens $EDITOR with decrypted JSON; re-encrypts on save
```

### Deploy

```bash
cd overlays/my-env
make deploy          # Clone app → npm ci → merge config → wrangler deploy → push secrets
```

### Using with Claude Code

If you use [Claude Code](https://claude.ai/code), the generated repo includes slash commands:

- `/create-env` — guided environment creation (collects info, runs script, creates secrets)
- `/delete-env` — guided environment deletion with confirmation
- `/upgrade` — apply migrations from newer CLI versions

## Secret Management with SOPS + AGE

Secrets are stored as SOPS-encrypted JSON files (`overlays/<env>/secrets.json`) using [AGE](https://github.com/FiloSottile/age) encryption, committed directly to git.

### How it works

Each environment's `secrets.json` is encrypted to multiple AGE recipients:

- **Manager key** — your personal key, decrypts all environments
- **Env key** — per-environment key for CI/CD, decrypts only that environment

```yaml
# .sops.yaml
creation_rules:
  - path_regex: overlays/my-env/secrets\.json$
    age: >-
      age1abc...env_key,
      age1xyz...manager_key
```

### Initial setup (one-time)

The scaffold CLI can generate the manager key pair automatically. If you chose to generate one, it's already saved to macOS Keychain. Add this to `~/.zshrc`:

```bash
export SOPS_AGE_KEY=$(security find-generic-password -a "sops-age" -s "sops-age-key" -w 2>/dev/null)
```

If you skipped key generation during scaffold, create one manually:

```bash
age-keygen
# Save private key (AGE-SECRET-KEY-1...) to Keychain:
security add-generic-password -a "sops-age" -s "sops-age-key" -w "AGE-SECRET-KEY-1..."
```

### Daily operations

All commands run from an overlay directory (`cd overlays/<env>`):

```bash
make edit-secrets                # Edit secrets (opens $EDITOR, re-encrypts on save)
make push-secrets                # Push decrypted secrets to Cloudflare Workers
make deploy                      # Full deploy (code + secrets)
sops decrypt secrets.json | jq . # View secrets (read-only)
```

### Adding a new manager

1. New manager runs `age-keygen` and shares their public key
2. Add the public key to every rule in `.sops.yaml`
3. Re-encrypt all environments:
   ```bash
   sops updatekeys overlays/<env>/secrets.json
   ```

### CI/CD keys

Each environment can have a dedicated AGE key for CI/CD:

1. `age-keygen` — save private key as CI/CD secret (`SOPS_AGE_KEY`)
2. Add public key to the environment's `.sops.yaml` rule
3. `sops updatekeys overlays/<env>/secrets.json`

### Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `no matching creation rules found` | SOPS can't find a rule for the file | Run from repo root; check `.sops.yaml` has the env's `path_regex` |
| `could not decrypt data key` | Your private key can't decrypt this file | Verify `SOPS_AGE_KEY` is set; ensure your public key is in `.sops.yaml`; run `sops updatekeys` if newly added |

## Upgrading

When a new version of this CLI is released with template changes, upgrade your existing repo:

```bash
# Check for available migrations
npx @marxbiotech/create-moltbot-env diff

# Or use Claude Code
/upgrade
```

The `diff` subcommand reads `.moltbot-env.json` in your repo, compares against the latest CLI version, and outputs migration instructions as markdown. Claude Code's `/upgrade` command runs this automatically and applies changes semantically.

## License

MIT
