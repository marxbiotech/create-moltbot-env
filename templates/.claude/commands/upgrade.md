# Upgrade moltbot-env

Run the diff command to check for available migrations:

```bash
npx @marxbiotech/create-moltbot-env diff
```

If migrations are available, apply each instruction in order:
- Read each migration instruction carefully
- Make the described changes to the repo files
- For shell scripts (.sh files), apply changes directly
- For .claude/commands/*.md files, update the natural language instructions
- For static files, replace with the provided content

After all migrations are applied:
- Update `.moltbot-env.json` → `meta.version` with the new version and `meta.lastUpgrade` with today's date
- Stage and show the user a summary of all changes made
- Do NOT commit automatically — let the user review first
