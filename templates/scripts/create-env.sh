#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_NAME="${1:?Usage: create-env.sh <env-name>}"
OVERLAY_DIR="$ROOT_DIR/overlays/$ENV_NAME"

CONFIG="$ROOT_DIR/.moltbot-env.json"
[[ -f "$CONFIG" ]] || { echo "Error: .moltbot-env.json not found" >&2; exit 1; }

CF_ACCOUNT_ID=$(jq -re '.cfAccountId // empty' "$CONFIG") || { echo "Error: cfAccountId missing from .moltbot-env.json" >&2; exit 1; }
CF_ACCESS_TEAM_DOMAIN=$(jq -re '.cfAccessTeamDomain // empty' "$CONFIG") || { echo "Error: cfAccessTeamDomain missing from .moltbot-env.json" >&2; exit 1; }
ACCESS_POLICY_EMAIL=$(jq -re '.accessPolicyEmail // empty' "$CONFIG") || { echo "Error: accessPolicyEmail missing from .moltbot-env.json" >&2; exit 1; }
MANAGER_AGE_KEY=$(jq -re '.managerAgeKey // empty' "$CONFIG") || { echo "Error: managerAgeKey missing from .moltbot-env.json" >&2; exit 1; }
APP_REPO_SLUG=$(jq -re '.appRepo // empty' "$CONFIG") || { echo "Error: appRepo missing from .moltbot-env.json" >&2; exit 1; }
WORKERS_SUBDOMAIN=$(jq -re '.workersSubdomain // empty' "$CONFIG") || { echo "Error: workersSubdomain missing from .moltbot-env.json" >&2; exit 1; }

APP_REPO="${APP_REPO:-git@github.com:${APP_REPO_SLUG}.git}"
case "$APP_REPO" in
  https://*|git@*|/*) ;;
  */*) APP_REPO="git@github.com:${APP_REPO}.git" ;;
esac
WORKER_DOMAIN="moltbot-${ENV_NAME}.${WORKERS_SUBDOMAIN}.workers.dev"

# --- Credential loading ---

load_credential() {
  local key="$1" config="$2"
  local source=$(jq -r --arg k "$key" '.credentials[$k].source' "$config")
  if [[ "$source" == "keychain" ]] && command -v security &>/dev/null; then
    local account=$(jq -r --arg k "$key" '.credentials[$k].keychainAccount' "$config")
    local service=$(jq -r --arg k "$key" '.credentials[$k].keychainService' "$config")
    security find-generic-password -a "$account" -s "$service" -w 2>/dev/null || true
  fi
}

# --- Validation ---

if [[ -d "$OVERLAY_DIR" ]]; then
  echo "Error: overlay directory already exists: $OVERLAY_DIR" >&2
  exit 1
fi

for cmd in npx jq sops age age-keygen curl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: required tool not found: $cmd" >&2
    exit 1
  fi
done

echo "▶ Checking wrangler auth..."
if ! npx wrangler whoami &>/dev/null; then
  echo "Error: wrangler is not logged in. Run 'npx wrangler login' first." >&2
  exit 1
fi

if [[ -z "${CF_ACCESS_API_TOKEN:-}" ]]; then
  CF_ACCESS_API_TOKEN=$(load_credential cfAccessApiToken "$CONFIG")
  export CF_ACCESS_API_TOKEN
fi

if [[ -z "${CF_ACCESS_API_TOKEN:-}" ]]; then
  echo "Error: CF_ACCESS_API_TOKEN environment variable is required (for Cloudflare Access API)." >&2
  echo "  See docs/cf-api-token.md for how to create one." >&2
  exit 1
fi

# Unset wrangler-recognized token vars so wrangler uses its own login session
unset CF_API_TOKEN CLOUDFLARE_API_TOKEN

# --- R2 Bucket ---

BUCKET_NAME="moltbot-${ENV_NAME}-data"
echo "▶ Creating R2 bucket: $BUCKET_NAME"
npx wrangler r2 bucket create "$BUCKET_NAME"

# --- CF Access App ---

MAIN_APP_NAME="moltbot-${ENV_NAME} - Cloudflare Workers"
echo "▶ Creating Cloudflare Access app: $MAIN_APP_NAME"
APP_RESPONSE=$(curl -s -X POST \
  "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/access/apps" \
  -H "Authorization: Bearer $CF_ACCESS_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"${MAIN_APP_NAME}\",
    \"type\": \"self_hosted\",
    \"domain\": \"${WORKER_DOMAIN}\",
    \"session_duration\": \"24h\"
  }")

if [[ "$(echo "$APP_RESPONSE" | jq -r '.success')" != "true" ]]; then
  echo "Error: Failed to create Access app:" >&2
  echo "$APP_RESPONSE" | jq . >&2
  exit 1
fi

CF_ACCESS_AUD=$(echo "$APP_RESPONSE" | jq -r '.result.aud')
APP_ID=$(echo "$APP_RESPONSE" | jq -r '.result.id')
echo "  AUD: $CF_ACCESS_AUD"

echo "▶ Creating Access policy: Allow owner"
POLICY_RESPONSE=$(curl -s -X POST \
  "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/access/apps/$APP_ID/policies" \
  -H "Authorization: Bearer $CF_ACCESS_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"Allow owner\",
    \"decision\": \"allow\",
    \"include\": [{\"email\": {\"email\": \"${ACCESS_POLICY_EMAIL}\"}}]
  }")

if [[ "$(echo "$POLICY_RESPONSE" | jq -r '.success')" != "true" ]]; then
  echo "Error: Failed to create Access policy:" >&2
  echo "$POLICY_RESPONSE" | jq . >&2
  exit 1
fi

# --- Overlay Directory ---

echo "▶ Creating overlay directory: overlays/$ENV_NAME"
mkdir -p "$OVERLAY_DIR"

# wrangler.jsonc — use printf to avoid trailing newline issues
DEFAULT_MODEL="${DEFAULT_MODEL:-google/gemini-3-flash-preview}"

# Write as jsonc with comment header and trailing commas (match existing style)
{
  echo "{"
  echo "  // Environment: ${ENV_NAME}"
  echo "  \"name\": \"moltbot-${ENV_NAME}\","
  echo "  \"workers_dev\": true,"
  echo "  \"r2_buckets\": ["
  echo "    {"
  echo "      \"binding\": \"MOLTBOT_BUCKET\","
  echo "      \"bucket_name\": \"${BUCKET_NAME}\","
  echo "      \"preview_bucket_name\": \"${BUCKET_NAME}\","
  echo "    },"
  echo "  ],"
  echo "  \"vars\": {"
  echo "    \"SANDBOX_SLEEP_AFTER\": \"10m\","
  echo "    \"DEBUG_ROUTES\": \"true\","
  echo "    \"CF_ACCESS_TEAM_DOMAIN\": \"${CF_ACCESS_TEAM_DOMAIN}\","
  echo "    \"CF_ACCOUNT_ID\": \"${CF_ACCOUNT_ID}\","
  echo "    \"CF_ACCESS_AUD\": \"${CF_ACCESS_AUD}\","
  echo "    \"R2_BUCKET_NAME\": \"${BUCKET_NAME}\","
  echo "    \"DEFAULT_MODEL\": \"${DEFAULT_MODEL}\","
  echo "    \"NODE_BYPASS_ROUTE\": \"/node-$(openssl rand -hex 8)\","
  echo "    \"WORKER_URL\": \"https://${WORKER_DOMAIN}\","
  if [[ -n "${BEDROCK_DEFAULT_MODEL:-}" ]]; then
    echo "    \"BEDROCK_DEFAULT_MODEL\": \"${BEDROCK_DEFAULT_MODEL}\","
  fi
  if [[ "${SUBSCRIPTION_AUTH:-}" == "true" ]]; then
    echo "    \"SUBSCRIPTION_AUTH\": \"true\","
  fi
  echo "  },"
  echo "}"
} > "$OVERLAY_DIR/wrangler.jsonc"

# version.txt — latest main SHA from app repo
echo "▶ Fetching latest app version..."
# Design Decision: LATEST_SHA not validated for empty; git ls-remote failure is caught by set -e,
# and an empty main branch is unlikely. Proper validation deferred to a future PR.
LATEST_SHA=$(git ls-remote "$APP_REPO" refs/heads/main | cut -c1-7)
echo "$LATEST_SHA" > "$OVERLAY_DIR/version.txt"
echo "  Version: $LATEST_SHA"

# Makefile symlink
ln -s ../../Makefile "$OVERLAY_DIR/Makefile"

# --- .sops.yaml + env AGE key ---

echo "▶ Generating env AGE key pair..."
KEYGEN_OUTPUT=$(age-keygen 2>&1)
ENV_AGE_PUBLIC_KEY=$(echo "$KEYGEN_OUTPUT" | grep "public key:" | awk '{print $NF}')
ENV_AGE_PRIVATE_KEY=$(echo "$KEYGEN_OUTPUT" | grep "AGE-SECRET-KEY-")

if [[ -z "$ENV_AGE_PUBLIC_KEY" || -z "$ENV_AGE_PRIVATE_KEY" ]]; then
  echo "Error: failed to generate AGE key pair" >&2
  exit 1
fi

echo "▶ Updating .sops.yaml"
SOPS_FILE="$ROOT_DIR/.sops.yaml"

if grep -q "path_regex: overlays/${ENV_NAME}/secrets" "$SOPS_FILE" 2>/dev/null; then
  echo "  .sops.yaml rule for $ENV_NAME already exists, skipping"
else
  SOPS_TMP=$(mktemp)
  trap 'rm -f "$SOPS_TMP"' EXIT
  awk -v env="$ENV_NAME" -v env_key="$ENV_AGE_PUBLIC_KEY" -v mgr_key="$MANAGER_AGE_KEY" '
    /^# Per-env key generation steps/ {
      print "  - path_regex: overlays/" env "/secrets\\.json$"
      print "    age: >-"
      print "      " env_key ","
      print "      " mgr_key
      print "    # env, manager"
      print ""
    }
    { print }
  ' "$SOPS_FILE" > "$SOPS_TMP"
  mv "$SOPS_TMP" "$SOPS_FILE"
fi

# --- Summary ---

echo ""
echo "✅ Environment '$ENV_NAME' created successfully!"
echo ""
echo "  R2 bucket:    $BUCKET_NAME"
echo "  CF Access AUD: $CF_ACCESS_AUD"
echo "  Worker domain: $WORKER_DOMAIN"
echo "  Overlay dir:   overlays/$ENV_NAME/"
echo "  App version:   $LATEST_SHA"
echo ""
# Design Decision: Private key printed to stdout for now; these scripts are interactive-only
# and not invoked in CI. Separating stdout/stderr output is deferred to a future PR.
echo "ENV_AGE_PUBLIC_KEY=$ENV_AGE_PUBLIC_KEY"
echo "ENV_AGE_PRIVATE_KEY=$ENV_AGE_PRIVATE_KEY"
echo ""
echo "Next steps:"
echo "  1. Create R2 API Token at: https://dash.cloudflare.com/${CF_ACCOUNT_ID}/r2/api-tokens"
echo "  2. Create secrets.json with sops"
echo "  3. Deploy: cd overlays/$ENV_NAME && make deploy"
