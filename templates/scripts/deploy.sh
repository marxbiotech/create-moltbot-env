#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_NAME="${1:?Usage: deploy.sh <environment>}"
OVERLAY_DIR="$ROOT_DIR/overlays/$ENV_NAME"

if [[ ! -d "$OVERLAY_DIR" ]]; then
  echo "Error: overlay '$ENV_NAME' not found at $OVERLAY_DIR" >&2; exit 1
fi

# In CI, CLOUDFLARE_API_TOKEN must be set; locally, wrangler uses its own OAuth session
if [[ -n "${CI:-}" ]]; then
  [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || { echo "Error: CLOUDFLARE_API_TOKEN not set" >&2; exit 1; }
else
  # Locally: unset deprecated CF_API_TOKEN so wrangler uses OAuth instead of a
  # potentially wrong token (e.g. CF Access token leaked into the env)
  unset CF_API_TOKEN
fi

CONFIG="$ROOT_DIR/.moltbot-env.json"
[[ -f "$CONFIG" ]] || { echo "Error: .moltbot-env.json not found" >&2; exit 1; }

APP_REPO_SLUG=$(jq -re '.appRepo // empty' "$CONFIG") || { echo "Error: appRepo missing from .moltbot-env.json" >&2; exit 1; }
CF_ACCOUNT_ID=$(jq -re '.cfAccountId // empty' "$CONFIG") || { echo "Error: cfAccountId missing from .moltbot-env.json" >&2; exit 1; }

VERSION=$(tr -d '[:space:]' < "$OVERLAY_DIR/version.txt")
[[ -n "$VERSION" ]] || { echo "Error: version.txt is empty" >&2; exit 1; }
APP_REPO="${APP_REPO:-git@github.com:${APP_REPO_SLUG}.git}"
case "$APP_REPO" in
  https://*|git@*|/*) ;;
  */*) APP_REPO="git@github.com:${APP_REPO}.git" ;;
esac

# --- Credential loading (local only) ---
if [[ -z "${CI:-}" ]]; then
  load_credential() {
    local key="$1"
    local source=$(jq -r --arg k "$key" '.credentials[$k].source // empty' "$CONFIG")
    [[ -n "$source" ]] || return 0
    if [[ "$source" == "keychain" ]]; then
      if ! command -v security &>/dev/null; then
        echo "Warning: credential '$key' configured for keychain but 'security' not found" >&2
        return 1
      fi
      local account=$(jq -r --arg k "$key" '.credentials[$k].keychainAccount // empty' "$CONFIG")
      local service=$(jq -r --arg k "$key" '.credentials[$k].keychainService // empty' "$CONFIG")
      if [[ -z "$account" || -z "$service" ]]; then
        echo "Warning: credential '$key' missing keychainAccount or keychainService" >&2
        return 1
      fi
      security find-generic-password -a "$account" -s "$service" -w 2>/dev/null || {
        echo "Warning: failed to load '$key' from keychain" >&2
        return 1
      }
    else
      echo "Warning: unknown credential source '$source' for '$key'" >&2
    fi
  }

  # Load SOPS_AGE_KEY from keychain if not set
  if [[ -z "${SOPS_AGE_KEY:-}" ]]; then
    SOPS_AGE_KEY=$(load_credential sopsAgeKey) || true
    export SOPS_AGE_KEY
  fi

  # Load CF_ACCESS_API_TOKEN from keychain if not set (for sync-access pre-deploy check)
  if [[ -z "${CF_ACCESS_API_TOKEN:-}" ]]; then
    CF_ACCESS_API_TOKEN=$(load_credential cfAccessApiToken) || true
    export CF_ACCESS_API_TOKEN
  fi
fi

# Validate SOPS_AGE_KEY before deploying to prevent partial deploys (code without secrets)
if [[ -f "$OVERLAY_DIR/secrets.json" ]]; then
  [[ -n "${SOPS_AGE_KEY:-}" ]] || { echo "Error: SOPS_AGE_KEY not set but secrets.json exists — would cause partial deploy" >&2; exit 1; }
fi

WORK_DIR="/tmp/deploy-moltbot-$$"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "▶ Deploying moltbot @ ${VERSION} (${ENV_NAME})"

# 0. Pre-deploy: ensure infrastructure is in sync
echo "▶ Pre-deploy checks..."
bash "$SCRIPT_DIR/ensure-queue.sh" "$ENV_NAME"

# sync-access needs CF_ACCESS_API_TOKEN (separate from CLOUDFLARE_API_TOKEN)
if [[ -n "${CF_ACCESS_API_TOKEN:-}" ]]; then
  bash "$SCRIPT_DIR/sync-access.sh" "$ENV_NAME"
else
  echo "  ⏭ Skipping Access sync (CF_ACCESS_API_TOKEN not set)"
fi

# 1. Clone app repo at pinned version
git clone "$APP_REPO" "$WORK_DIR"
cd "$WORK_DIR"
git checkout "$VERSION"
RESOLVED_SHA=$(git rev-parse --short HEAD)
echo "  Resolved: ${VERSION} → ${RESOLVED_SHA}"

# 1b. Install env-managed skills into app repo before build
SKILLS_FILE="$OVERLAY_DIR/skills.txt"
if [[ -f "$SKILLS_FILE" ]]; then
  skill_count=0
  while IFS= read -r skill_name || [[ -n "$skill_name" ]]; do
    skill_name="${skill_name%%#*}"          # strip inline comments
    skill_name="$(echo "$skill_name" | xargs)" # trim whitespace
    [[ -z "$skill_name" ]] && continue
    skill_src="$ROOT_DIR/skills/$skill_name"
    if [[ ! -d "$skill_src" ]]; then
      echo "Error: skill '$skill_name' not found in skills/" >&2; exit 1
    fi
    mkdir -p "$WORK_DIR/skills/$skill_name"
    cp -r "$skill_src"/* "$WORK_DIR/skills/$skill_name/"
    ((skill_count++))
  done < "$SKILLS_FILE"
  [[ $skill_count -gt 0 ]] && echo "  Skills injected: $skill_count"
fi

# 2. Install dependencies
npm ci

# 3. Merge configs: base (app repo) + overlay (env repo)
echo "▶ Merging wrangler config..."
STRIP="node $SCRIPT_DIR/jsonc-strip.js"
merged=$(mktemp)
jq -s --arg acct "$CF_ACCOUNT_ID" '.[0] * .[1] * {account_id: $acct}' <($STRIP "$WORK_DIR/wrangler.jsonc") <($STRIP "$OVERLAY_DIR/wrangler.jsonc") > "$merged"
mv "$merged" "$WORK_DIR/wrangler.jsonc"

# 4. Deploy
npx wrangler deploy

# 5. Push secrets (if secrets.json exists)
if [[ -f "$OVERLAY_DIR/secrets.json" ]]; then
  echo "▶ Deploying secrets..."
  secrets=$(mktemp)
  trap 'rm -rf "$WORK_DIR" "$secrets"' EXIT
  sops decrypt "$OVERLAY_DIR/secrets.json" \
    | jq 'to_entries | map(if .value | type != "string" then .value = (.value | tojson) else . end) | from_entries' \
    > "$secrets"
  npx wrangler secret bulk "$secrets"
  rm -f "$secrets"
fi

echo "✅ Deploy complete: moltbot @ ${RESOLVED_SHA} (${ENV_NAME})"
