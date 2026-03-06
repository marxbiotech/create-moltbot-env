# Ensure Telegram Queue for Environment

You are ensuring a Cloudflare Queue exists for an environment's Telegram webhook cold-start buffering. If the queue already exists, skip creation and just ensure the overlay config is correct.

## Context

When a Telegram webhook arrives during container cold start, messages are enqueued to a Cloudflare Queue instead of being dropped. The queue consumer delivers messages after the container starts. This requires:

1. A Cloudflare Queue resource
2. A dead letter queue (DLQ) for failed messages
3. Queue producer + consumer config in the overlay's `wrangler.jsonc`

## Phase 1 — Select Environment

Use AskUserQuestion to ask "Which environment?" with options:
- ryougi-shiki
- magata-shiki
- da-vinci

## Phase 2 — Ensure Queues Exist

Run the ensure-queue script, which uses `npx wrangler` for authentication (OAuth locally, API token in CI):

```bash
bash scripts/ensure-queue.sh <env-name>
```

The script will:
- Read queue names from the overlay's `wrangler.jsonc`
- If no `queues` block exists, auto-inject a default config (with `max_retries: 10`, `max_batch_size: 5`, `max_batch_timeout: 5`)
- Check existing queues via `npx wrangler queues list`
- Create any missing queues via `npx wrangler queues create`

If wrangler's OAuth session has expired locally, it will prompt the user to re-authenticate. If the user prefers to use an API token instead, they can set `CLOUDFLARE_API_TOKEN` in the environment before running.

## Phase 3 — Verify Overlay wrangler.jsonc Config

After the script runs, read `overlays/<env-name>/wrangler.jsonc` and verify the `queues` block is present and correct.

The expected structure (values are environment-specific and can be tuned):

```jsonc
  "queues": {
    "producers": [
      {
        "binding": "TELEGRAM_QUEUE",
        "queue": "moltbot-<env-name>-telegram",
      },
    ],
    "consumers": [
      {
        "queue": "moltbot-<env-name>-telegram",
        "dead_letter_queue": "moltbot-<env-name>-telegram-dlq",
        "max_retries": 10,
        "max_batch_size": 5,
        "max_batch_timeout": 5,
      },
    ],
  },
```

If the script auto-injected the config, remind the user to review and commit the change. The `max_retries`, `max_batch_size`, and `max_batch_timeout` values can be tuned per environment (e.g., ryougi-shiki uses `max_retries: 30`).

## Phase 4 — Verify

Show the user:

> Queue ensured for `<env-name>`:
> - Main: `moltbot-<env-name>-telegram`
> - DLQ: `moltbot-<env-name>-telegram-dlq`
> - Binding: `TELEGRAM_QUEUE` in `overlays/<env-name>/wrangler.jsonc`
>
> To activate, deploy the environment:
> ```bash
> cd overlays/<env-name> && make deploy
> ```
>
> Don't forget to also set `TELEGRAM_LIFECYCLE_CHAT_ID` in the overlay's `vars` if you want lifecycle notifications.

## Important Notes

- Queue names must be globally unique within the Cloudflare account
- The queue consumer `max_retries` controls how many times a message is retried before going to DLQ (default: 10, tune per environment)
- The `TELEGRAM_QUEUE` binding is optional in the app code — if not configured, webhook handling falls back to fire-and-forget behavior
- The script is idempotent — safe to run on every deploy
