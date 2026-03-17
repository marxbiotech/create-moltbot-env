#!/usr/bin/env bash
set -euo pipefail

# sync-access.sh — Ensure Cloudflare Access Applications match desired state
#
# For each overlay, ensures:
# 1. A main Access app exists (domain-level protection)
# 2. Webhook bypass apps exist for configured channels:
#    - /telegram/webhook if TELEGRAM_WEBHOOK_SECRET is in secrets
#    - /slack/events if SLACK_SIGNING_SECRET is in secrets
#
# Usage: sync-access.sh <env-name>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_NAME="${1:?Usage: sync-access.sh <env-name>}"
OVERLAY_DIR="$ROOT_DIR/overlays/$ENV_NAME"

CONFIG="$ROOT_DIR/.moltbot-env.json"
[[ -f "$CONFIG" ]] || { echo "Error: .moltbot-env.json not found" >&2; exit 1; }

CF_ACCOUNT_ID=$(jq -re '.cfAccountId // empty' "$CONFIG") || { echo "Error: cfAccountId missing from .moltbot-env.json" >&2; exit 1; }
WORKERS_SUBDOMAIN=$(jq -re '.workersSubdomain // empty' "$CONFIG") || { echo "Error: workersSubdomain missing from .moltbot-env.json" >&2; exit 1; }
API_BASE="https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/access/apps"

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

if [[ ! -d "$OVERLAY_DIR" ]]; then
  echo "Error: overlay '$ENV_NAME' not found at $OVERLAY_DIR" >&2
  exit 1
fi

for cmd in curl jq node npx; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: required tool not found: $cmd" >&2
    exit 1
  fi
done

if [[ -z "${CF_ACCESS_API_TOKEN:-}" ]]; then
  CF_ACCESS_API_TOKEN=$(load_credential cfAccessApiToken "$CONFIG")
  export CF_ACCESS_API_TOKEN
fi

if [[ -z "${CF_ACCESS_API_TOKEN:-}" ]]; then
  echo "Error: CF_ACCESS_API_TOKEN environment variable is required." >&2
  echo "  See docs/cf-api-token.md for how to create one." >&2
  exit 1
fi

# Unset wrangler-recognized token vars so wrangler uses its own login session
unset CF_API_TOKEN CLOUDFLARE_API_TOKEN

STRIP="node $SCRIPT_DIR/jsonc-strip.js"
WORKER_NAME=$($STRIP "$OVERLAY_DIR/wrangler.jsonc" | jq -r '.name')
WORKER_DOMAIN="${WORKER_NAME}.${WORKERS_SUBDOMAIN}.workers.dev"
MAIN_APP_NAME="${WORKER_NAME} - Cloudflare Workers"

# Access apps: name_suffix|path|secret_name|policy_type
# policy_type: "bypass" (default) or "service_auth"
OVERLAY_JSON=$($STRIP "$OVERLAY_DIR/wrangler.jsonc")
NODE_ROUTE=$(echo "$OVERLAY_JSON" | jq -r '.vars.NODE_ROUTE // empty')
NODE_SERVICE_TOKEN_ID=$(echo "$OVERLAY_JSON" | jq -r '.vars.NODE_SERVICE_TOKEN_ID // empty')
ACCESS_CONFIGS=(
  "telegram-webhook|/telegram/webhook|TELEGRAM_WEBHOOK_SECRET|bypass"
  "slack-events|/slack/events|SLACK_SIGNING_SECRET|bypass"
)
if [[ -n "$NODE_ROUTE" ]]; then
  ACCESS_CONFIGS+=("node|${NODE_ROUTE}|MOLTBOT_GATEWAY_TOKEN|service_auth")
fi

# --- Fetch current Access apps ---

echo "▶ Fetching Access apps for account..."
APPS_RESPONSE=$(curl -s "$API_BASE" \
  -H "Authorization: Bearer $CF_ACCESS_API_TOKEN")

if [[ "$(echo "$APPS_RESPONSE" | jq -r '.success')" != "true" ]]; then
  echo "Error: Failed to list Access apps:" >&2
  echo "$APPS_RESPONSE" | jq . >&2
  exit 1
fi

# Check main app
MAIN_APP=$(echo "$APPS_RESPONSE" | jq -r --arg name "$MAIN_APP_NAME" '.result[] | select(.name == $name)')
if [[ -z "$MAIN_APP" ]]; then
  echo "  ⚠ Main Access app '$MAIN_APP_NAME' not found"
  echo "  Run create-env.sh first or create it manually." >&2
  exit 1
fi
MAIN_APP_ID=$(echo "$MAIN_APP" | jq -r '.id')
echo "  Main app: $MAIN_APP_NAME (ID: $MAIN_APP_ID)"

# --- Check wrangler secrets (once, shared across all bypass checks) ---

echo ""
echo "▶ Checking wrangler secrets..."
WRANGLER_TMP=$(mktemp).json
trap 'rm -f "$WRANGLER_TMP"' EXIT
$STRIP "$OVERLAY_DIR/wrangler.jsonc" > "$WRANGLER_TMP"
SECRET_LIST=$(npx wrangler secret list --config "$WRANGLER_TMP" 2>/dev/null) || {
  echo "Error: Failed to list wrangler secrets" >&2
  exit 1
}
if ! echo "$SECRET_LIST" | jq empty 2>/dev/null; then
  echo "Error: wrangler secret list returned non-JSON output:" >&2
  echo "$SECRET_LIST" >&2
  exit 1
fi

# --- Reconcile each access app ---

for config in "${ACCESS_CONFIGS[@]}"; do
  IFS='|' read -r SUFFIX URL_PATH SECRET_NAME POLICY_TYPE <<< "$config"
  POLICY_TYPE="${POLICY_TYPE:-bypass}"
  APP_NAME="${WORKER_NAME}-${SUFFIX}"
  APP_DOMAIN="${WORKER_DOMAIN}${URL_PATH}"

  # Check current state
  EXISTING_APP=$(echo "$APPS_RESPONSE" | jq -r --arg name "$APP_NAME" '.result[] | select(.name == $name)')
  EXISTING_ID=""
  if [[ -n "$EXISTING_APP" ]]; then
    EXISTING_ID=$(echo "$EXISTING_APP" | jq -r '.id')
    echo "  Access app: $APP_NAME (ID: $EXISTING_ID)"
  else
    echo "  Access app: $APP_NAME — not found"
  fi

  # Determine if app is needed
  WANTS=false
  if echo "$SECRET_LIST" | jq -e --arg name "$SECRET_NAME" '.[] | select(.name == $name)' &>/dev/null; then
    WANTS=true
  fi
  echo "  Desired: $WANTS (policy: $POLICY_TYPE)"

  if [[ "$WANTS" == "true" && -z "$EXISTING_ID" ]]; then
    echo ""
    echo "▶ Creating access app: $APP_NAME"
    echo "  Domain: $APP_DOMAIN"

    CREATE_RESPONSE=$(curl -s -X POST "$API_BASE" \
      -H "Authorization: Bearer $CF_ACCESS_API_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{
        \"name\": \"${APP_NAME}\",
        \"type\": \"self_hosted\",
        \"domain\": \"${APP_DOMAIN}\",
        \"session_duration\": \"24h\"
      }")

    if [[ "$(echo "$CREATE_RESPONSE" | jq -r '.success')" != "true" ]]; then
      echo "Error: Failed to create access app $APP_NAME:" >&2
      echo "$CREATE_RESPONSE" | jq . >&2
      exit 1
    fi

    NEW_ID=$(echo "$CREATE_RESPONSE" | jq -r '.result.id')
    echo "  Created (ID: $NEW_ID)"

    # Create policy based on type
    if [[ "$POLICY_TYPE" == "service_auth" ]]; then
      # Use specific token if NODE_SERVICE_TOKEN_ID is set, otherwise allow any valid service token
      if [[ -n "$NODE_SERVICE_TOKEN_ID" ]]; then
        echo "▶ Creating policy: Allow Service Token ($NODE_SERVICE_TOKEN_ID)"
        POLICY_DATA="{\"name\":\"Allow Service Token\",\"decision\":\"non_identity\",\"include\":[{\"service_token\":{\"token_id\":\"${NODE_SERVICE_TOKEN_ID}\"}}]}"
      else
        echo "▶ Creating policy: Allow Any Service Token"
        POLICY_DATA='{"name":"Allow Service Tokens","decision":"non_identity","include":[{"any_valid_service_token":{}}]}'
      fi
      POLICY_RESPONSE=$(curl -s -X POST \
        "$API_BASE/$NEW_ID/policies" \
        -H "Authorization: Bearer $CF_ACCESS_API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$POLICY_DATA")
    else
      echo "▶ Creating policy: Bypass Everyone"
      POLICY_RESPONSE=$(curl -s -X POST \
        "$API_BASE/$NEW_ID/policies" \
        -H "Authorization: Bearer $CF_ACCESS_API_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{
          "name": "Bypass Everyone",
          "decision": "bypass",
          "include": [{"everyone": {}}]
        }')
    fi

    # Design Decision: On policy failure, the just-created app is left orphaned (blocks route
    # with Access but has no policy). Re-running will NOT fix this — it sees the app
    # exists and skips it. Manual deletion from the CF dashboard is required before re-running.
    if [[ "$(echo "$POLICY_RESPONSE" | jq -r '.success')" != "true" ]]; then
      echo "Error: Failed to create policy for $APP_NAME:" >&2
      echo "$POLICY_RESPONSE" | jq . >&2
      exit 1
    fi

    echo "  Policy created"
    echo "✅ Access app created: $APP_DOMAIN ($POLICY_TYPE)"

  elif [[ "$WANTS" == "false" && -n "$EXISTING_ID" ]]; then
    echo ""
    echo "▶ Deleting access app: $APP_NAME (no longer needed)"

    DELETE_RESPONSE=$(curl -s -X DELETE \
      "$API_BASE/$EXISTING_ID" \
      -H "Authorization: Bearer $CF_ACCESS_API_TOKEN")

    if [[ "$(echo "$DELETE_RESPONSE" | jq -r '.success')" == "true" ]]; then
      echo "  Deleted"
      echo "✅ Access app removed: $APP_NAME"
    # Design Decision: Deletion failure is non-fatal (warning only, no exit 1).
    else
      echo "  ⚠ Failed to delete $APP_NAME:" >&2
      echo "$DELETE_RESPONSE" | jq . >&2
    fi

  else
    if [[ "$WANTS" == "true" ]]; then
      echo "  ✅ Already exists — no changes needed"
    else
      echo "  ✅ Not needed — no changes needed"
    fi
  fi
  echo ""
done
