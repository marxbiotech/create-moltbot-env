# Reset Durable Object Alarm Loop

You are resetting a stuck Durable Object alarm loop for an environment. This happens when the DO's internal alarm chain gets into a self-sustaining cycle (e.g., caused by a rogue cron trigger or external polling that has since been removed). Symptoms: repeated lifecycle notifications (e.g., "💤 Container 即將休眠" every ~10 minutes) without any external traffic, while other environments running the same code are unaffected.

## Root Cause

The `SANDBOX_SLEEP_AFTER` alarm fires → `onActivityExpired` runs → any outbound fetch (e.g., Telegram notification) may reset the DO activity timer → `super.onActivityExpired()` doesn't actually sleep → alarm reschedules → loop repeats. Once the cycle starts (e.g., from a cron trigger), it persists even after the original trigger is removed.

## Phase 1 — Select Environment

Use AskUserQuestion to ask "Which environment has a stuck DO alarm loop?" with options from the existing overlays.

## Phase 2 — Diagnose

Confirm the issue by tailing the worker logs:

```bash
make -C overlays/<env-name> wrangler CMD='tail --format json'
```

Look for:
- Recurring `durableObject` events with `entrypoint: "Sandbox"` and no corresponding `stateless` requests
- `wallTime` of ~180000 (3 minutes) repeating
- No `cron` events (if cron is still present, that's the primary issue — tell the user to remove it from Cloudflare Dashboard first)

If you don't see DO alarm events, the issue is something else — stop and investigate further.

## Phase 3 — Clear the Alarm Loop

The fix is a two-step deploy: first disable sleep to break the alarm chain, then re-enable it.

### Step 1: Deploy with sleep disabled

Read the current `SANDBOX_SLEEP_AFTER` value from `overlays/<env-name>/wrangler.jsonc` and save it (e.g., `ORIGINAL_VALUE="10m"`).

Change `SANDBOX_SLEEP_AFTER` to `"never"`:

```bash
# Edit overlays/<env-name>/wrangler.jsonc: "SANDBOX_SLEEP_AFTER": "never"
```

Deploy:

```bash
make -C overlays/<env-name> deploy
```

### Step 2: Wait for the alarm to clear

Wait 3 minutes for the current alarm cycle to expire. The DO will process its last alarm and, with `SANDBOX_SLEEP_AFTER` set to `"never"`, won't schedule a new one.

### Step 3: Restore original sleep value and redeploy

Change `SANDBOX_SLEEP_AFTER` back to the original value:

```bash
# Edit overlays/<env-name>/wrangler.jsonc: "SANDBOX_SLEEP_AFTER": "<original-value>"
```

Deploy again:

```bash
make -C overlays/<env-name> deploy
```

## Phase 4 — Verify

After restoring, monitor for ~15 minutes to confirm no more spurious 💤 notifications.

Optionally tail the logs again to confirm no recurring DO alarm events:

```bash
make -C overlays/<env-name> wrangler CMD='tail --format json'
```

Tell the user:

> DO alarm loop cleared for `<env-name>`.
>
> The alarm cycle was broken by temporarily deploying with `SANDBOX_SLEEP_AFTER: "never"`, then restoring `<original-value>`. The DO will now only schedule sleep alarms when triggered by real activity.
>
> **If the issue recurs**, check for:
> - Cron triggers in Cloudflare Dashboard (Workers → Triggers → Cron)
> - External health checks or monitoring hitting the worker URL
> - Queue messages stuck in retry loops

## Important Notes

- This does NOT lose any data — the DO's storage is preserved, only the alarm state is reset
- The `wrangler.jsonc` change is temporary and should NOT be committed — the file should be back to its original value after the fix
- Other environments are unaffected — the alarm loop is per-DO-instance
- The 3-minute wait is conservative; the alarm typically clears within one cycle (~180 seconds based on observed `wallTime`)
