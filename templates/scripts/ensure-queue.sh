#!/usr/bin/env bash
set -euo pipefail

# ensure-queue.sh — Ensure Cloudflare Queues exist for overlay config
#
# Reads queue names from the overlay's wrangler.jsonc and creates any
# that don't already exist. Idempotent — safe to run on every deploy.
#
# Usage: ensure-queue.sh <env-name>
# Requires: npx wrangler (uses wrangler's own auth — OAuth locally, API token in CI)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_NAME="${1:?Usage: ensure-queue.sh <env-name>}"
OVERLAY_DIR="$ROOT_DIR/overlays/$ENV_NAME"

[[ -d "$OVERLAY_DIR" ]] || { echo "Error: overlay '$ENV_NAME' not found" >&2; exit 1; }

# Prevent wrangler from picking up CF_API_TOKEN (e.g. CF Access token leaked into env)
unset CF_API_TOKEN

STRIP="node $SCRIPT_DIR/jsonc-strip.js"
OVERLAY_JSON=$($STRIP "$OVERLAY_DIR/wrangler.jsonc")
WORKER_NAME=$(echo "$OVERLAY_JSON" | jq -r '.name // empty')
[[ -n "$WORKER_NAME" ]] || { echo "Error: 'name' missing from overlay wrangler.jsonc" >&2; exit 1; }

# Default queue naming pattern
DEFAULT_QUEUE="${WORKER_NAME}-telegram"
DEFAULT_DLQ="${WORKER_NAME}-telegram-dlq"

# Check if queue config already exists in overlay
HAS_QUEUES=$(echo "$OVERLAY_JSON" | jq 'has("queues")') || { echo "Error: failed to parse overlay wrangler.jsonc" >&2; exit 1; }

if [[ "$HAS_QUEUES" != "true" ]]; then
  echo "  ▶ No queues config found, injecting default pattern..."

  # Write queues block to a temp file, then splice into wrangler.jsonc
  WRANGLER_FILE="$OVERLAY_DIR/wrangler.jsonc"
  BLOCK_FILE=$(mktemp)
  cat > "$BLOCK_FILE" <<JSONEOF
  "queues": {
    "producers": [{ "binding": "TELEGRAM_QUEUE", "queue": "${DEFAULT_QUEUE}" }],
    "consumers": [{
      "queue": "${DEFAULT_QUEUE}",
      "dead_letter_queue": "${DEFAULT_DLQ}",
      "max_retries": 10,
      "max_batch_size": 5,
      "max_batch_timeout": 5,
    }],
  },
JSONEOF

  # Find the first JSON key line and insert the block before it
  FIRST_KEY_LINE=$(grep -n '^\s*"' "$WRANGLER_FILE" | head -1 | cut -d: -f1)
  if [[ -n "$FIRST_KEY_LINE" ]]; then
    tmp=$(mktemp)
    head -n $((FIRST_KEY_LINE - 1)) "$WRANGLER_FILE" > "$tmp"
    cat "$BLOCK_FILE" >> "$tmp"
    tail -n +$FIRST_KEY_LINE "$WRANGLER_FILE" >> "$tmp"
    mv "$tmp" "$WRANGLER_FILE"
    echo "  ✓ Injected queues config into wrangler.jsonc"
    echo "  ⚠ Modified $WRANGLER_FILE — commit this change to persist" >&2
  else
    echo "  ⚠ Could not inject queues config (no key found in wrangler.jsonc)" >&2
  fi
  rm -f "$BLOCK_FILE"

  # Re-read the updated file
  OVERLAY_JSON=$($STRIP "$OVERLAY_DIR/wrangler.jsonc")
fi

# Extract queue names from producers and consumers
QUEUE_NAMES=$(echo "$OVERLAY_JSON" | jq -r '
  [
    (.queues.producers // [] | .[].queue),
    (.queues.consumers // [] | .[].queue),
    (.queues.consumers // [] | .[].dead_letter_queue // empty)
  ] | unique | .[]') || { echo "Error: failed to extract queue names from overlay config" >&2; exit 1; }

if [[ -z "$QUEUE_NAMES" ]]; then
  echo "  ⏭ No queues to create"
  exit 0
fi

echo "▶ Ensuring queues for $ENV_NAME..."

# Fetch existing queues via wrangler
if ! EXISTING_RAW=$(npx wrangler queues list --json 2>&1); then
  echo "Error: failed to list queues:" >&2
  echo "$EXISTING_RAW" >&2
  exit 1
fi
EXISTING=$(echo "$EXISTING_RAW" | jq -r '.[].queue_name')

for QUEUE_NAME in $QUEUE_NAMES; do
  if echo "$EXISTING" | grep -qx "$QUEUE_NAME"; then
    echo "  ✓ $QUEUE_NAME (exists)"
  else
    echo "  ▶ Creating $QUEUE_NAME..."
    if npx wrangler queues create "$QUEUE_NAME" 2>&1; then
      echo "  ✓ $QUEUE_NAME (created)"
    else
      echo "Error: failed to create queue '$QUEUE_NAME'" >&2
      exit 1
    fi
  fi
done

echo "✅ Queues ensured for $ENV_NAME"
