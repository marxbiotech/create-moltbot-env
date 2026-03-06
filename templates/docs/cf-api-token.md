# CF_ACCESS_API_TOKEN

`scripts/create-env.sh` 需要 `CF_ACCESS_API_TOKEN` 來呼叫 Cloudflare Access API（建立 Access 應用程式與存取政策）。這與 `wrangler login` 是分開的 — wrangler 的 OAuth token 不包含 Access 權限。

變數刻意命名為 `CF_ACCESS_API_TOKEN`（而非 `CF_API_TOKEN` 或 `CLOUDFLARE_API_TOKEN`），避免被 wrangler 誤讀。wrangler 使用自己的登入 session。

## 建立 Token

1. 前往 https://dash.cloudflare.com/profile/api-tokens
2. 點擊 **Create Token**
3. 選擇 **Create Custom Token**
4. 設定：
   - **Token name:** `moltbot-env-setup`（或任意名稱）
   - **Permissions:** Account > Access: Apps and Policies > **Edit**
   - **Account Resources:** Include > （選擇你的帳戶）
5. 點擊 **Continue to summary** > **Create Token**
6. 複製 token

## 存入 macOS Keychain

```bash
security add-generic-password -a "cf-access-api-token" -s "cf-access-api-token" -w "<your-token>"
```

加入 `~/.zshrc`：
```bash
export CF_ACCESS_API_TOKEN=$(security find-generic-password -a "cf-access-api-token" -s "cf-access-api-token" -w 2>/dev/null)
```

## 使用方式

```bash
CF_ACCESS_API_TOKEN="<your-token>" bash scripts/create-env.sh <env-name>
```

如果已存入 Keychain 並透過 `.zshrc` export，直接執行即可：
```bash
bash scripts/create-env.sh <env-name>
```

## 為什麼不用 wrangler？

`wrangler` CLI 沒有管理 Cloudflare Access 應用程式/政策的指令。wrangler OAuth token 的 scope（`workers:write`、`account:read` 等）不包含 Access 管理權限，必須使用獨立的 token 直接呼叫 Cloudflare API。
