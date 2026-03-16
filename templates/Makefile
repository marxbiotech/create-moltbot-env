SHELL := /bin/bash
ROOT := $(patsubst %/,%,$(dir $(realpath $(lastword $(MAKEFILE_LIST)))))
OVERLAY_DIR := $(CURDIR)
ENV_NAME := $(notdir $(OVERLAY_DIR))
STRIP_JSONC := node $(ROOT)/scripts/jsonc-strip.js

.PHONY: deploy secret wrangler merged-config edit-secrets push-secrets sync-access ensure-queue node

# Full deploy: clone app repo → npm ci → merge configs → wrangler deploy
deploy:
	@bash $(ROOT)/scripts/deploy.sh $(ENV_NAME)

# wrangler secret put — only needs overlay's name field, no app repo clone
secret:
	@test -n "$(KEY)" || (echo "Usage: make secret KEY=<name>" >&2; exit 1)
	@tmp=$$(mktemp).json && $(STRIP_JSONC) $(OVERLAY_DIR)/wrangler.jsonc > "$$tmp" \
		&& npx wrangler secret put $(KEY) --config "$$tmp"; rm -f "$$tmp"

# Arbitrary wrangler command using overlay config
wrangler:
	@test -n "$(CMD)" || (echo "Usage: make wrangler CMD='...'" >&2; exit 1)
	@tmp=$$(mktemp).json && $(STRIP_JSONC) $(OVERLAY_DIR)/wrangler.jsonc > "$$tmp" \
		&& npx wrangler $(CMD) --config "$$tmp"; rm -f "$$tmp"

# Output merged config for inspection (requires local app repo)
merged-config:
	@test -n "$(APP_DIR)" || (echo "Usage: make merged-config APP_DIR=/path/to/moltbot-app" >&2; exit 1)
	@jq -s '.[0] * .[1]' <($(STRIP_JSONC) $(APP_DIR)/wrangler.jsonc) <($(STRIP_JSONC) $(OVERLAY_DIR)/wrangler.jsonc)

# Sync Cloudflare Access apps (creates/removes webhook bypass as needed)
sync-access:
	@bash $(ROOT)/scripts/sync-access.sh $(ENV_NAME)

# Ensure Cloudflare Queues exist for overlay config
ensure-queue:
	@bash $(ROOT)/scripts/ensure-queue.sh $(ENV_NAME)

# Start paired node: relay + openclaw node via create-moltbot-env CLI
# Override node name: make node NODE_NAME=my-custom-name
NODE_NAME ?= $(ENV_NAME)-$(shell hostname -s)
node:
	@npx @marxbiotech/create-moltbot-env node --env $(ENV_NAME) --node-name "$(NODE_NAME)"

# Edit secrets via SOPS (requires SOPS_AGE_KEY env var)
edit-secrets:
	@test -n "$$SOPS_AGE_KEY" || (echo "Error: SOPS_AGE_KEY not set" >&2; exit 1)
	@sops $(OVERLAY_DIR)/secrets.json

# Decrypt and bulk-push secrets to Cloudflare Workers
push-secrets:
	@test -n "$$SOPS_AGE_KEY" || (echo "Error: SOPS_AGE_KEY not set" >&2; exit 1)
	@secrets=$$(mktemp) \
		&& sops decrypt $(OVERLAY_DIR)/secrets.json > "$$secrets" \
		&& tmp=$$(mktemp).json && $(STRIP_JSONC) $(OVERLAY_DIR)/wrangler.jsonc > "$$tmp" \
		&& npx wrangler secret bulk "$$secrets" --config "$$tmp"; \
		rm -f "$$secrets" "$$tmp"
