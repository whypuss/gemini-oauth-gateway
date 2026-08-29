# 疑難排解

實際部署踩過嘅坑，按出現次序排。

---

## 1. `--help` 冇 `-gemini-login`

**症狀**：跟舊教學打 `cli-proxy-api -gemini-login` 或 `-login`，話 flag 唔存在。

**原因**：CLIProxyAPI v7.x 已經**移除咗 Gemini CLI OAuth 登入**。Gemini 系列模型而家經 **Antigravity** 拎。

```
$ ./cli-proxy-api --help
  -antigravity-login    Login to Antigravity using OAuth
  -claude-login         Login to Claude using OAuth
  -codex-login          Login to Codex using OAuth
  -kimi-login           Login to Kimi using OAuth
  -xai-login            Login to xAI using OAuth
```

**解法**：用 `-antigravity-login`。一樣係食你 Google 訂閱額度，只係中間層唔同。

---

## 2. `User location is not supported for the API use.`

**症狀**：OAuth 登入完全成功、`/v1/models` 見到模型，但一 `chat/completions` 就：

```json
{"error":{"code":400,"message":"User location is not supported for the API use.","status":"FAILED_PRECONDITION"}}
```

**原因**：Gemini / Antigravity 按地區封鎖。**OAuth 登入本身唔受地區限制**，只有真正 inference 受限 —— 所以好易誤以為設定啱晒。

**解法**：搞一個合規地區出口，再喺 `config.yaml` 填 `proxy-url`。見 README 步驟 2。

**踩多一腳**：`ALL_PROXY` 環境變數**冇用**。Go 嘅 `http.ProxyFromEnvironment` 只讀 `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`，唔讀 `ALL_PROXY`。systemd unit 入面寫 `Environment=ALL_PROXY=socks5://...` 會被靜靜哋忽略，你會以為行緊代理但其實係直連。用 `proxy-url` 設定項。

---

## 3. OAuth callback `ERR_CONNECTION_RESET`

**症狀**：Google 授權完，跳去 `http://localhost:<port>/oauth-callback?code=...` 顯示連線被重設。

**原因**（由最常見排落去）：

1. **登入程序 timeout 咗**。CLIProxyAPI 等 callback 只等 **300 秒**，之後就退出、放開個 port。慢慢手動撳 OAuth 好易爆呢個。
2. **冇開 SSH 隧道**。server 冇圖形界面，個 callback 打去瀏覽器嗰部機嘅 localhost，唔係 server 嘅。
3. 隧道開咗但 port 錯 —— callback port **每次登入都唔同**。

**解法**：

```bash
# 1. server 上面開登入，記低印出嚟嗰個 port
./scripts/02-antigravity-login.sh

# 2. 立即喺有瀏覽器嗰部機開隧道（port 要對）
ssh -f -N -L 51121:127.0.0.1:51121 user@your-server

# 3. 五分鐘之內撳完 OAuth
```

**確認隧道通咗**（應該回 404，代表有嘢聽住）：

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:51121/
```

---

## 4. 公網 IP 唔可以做 redirect_uri

**症狀**：想改 `redirect_uri` 做 `http://1.2.3.4:51121/oauth-callback` 免開隧道，俾 Google 拒絕。

**原因**：呢個 OAuth client 係 installed-app 類型，Google **只接受 loopback**（`localhost` / `127.0.0.1`）。改唔到。

**解法**：

- 開 SSH 隧道（見上）；或者
- 喺手機／其他機撳完 OAuth，最後果版會顯示「無法連線」，**由地址欄抄低成條 `http://localhost:<port>/oauth-callback?...` URL**，再喺 server 本機 `curl` 落去：

```bash
curl "http://127.0.0.1:51121/oauth-callback?state=...&code=..."
```

個 `code` 係一次性、幾分鐘就過期，抄完即刻用。

---

## 5. Google 擋自動化瀏覽器

**症狀**：用 Playwright / Puppeteer / CDP 控制嘅 Chrome 行 OAuth，一撳「下一步」（email 之後）就跳去：

> 目前無法登入帳戶 — 這個瀏覽器或應用程式可能有安全疑慮
> Couldn't sign you in — This browser or app may not be secure

留意係喺**輸入密碼之前**就攔截，即係密碼根本未送出過。

**原因**：Google 偵測到自動化 driver。

**解法**：

- 手動用一般瀏覽器撳；或者
- 用會沿用真實 user profile / 真實瀏覽器指紋嘅工具。
- 帳號開咗兩步驟驗證嘅話，推送嗰步一定要真人喺手機撳，冇得繞。

---

## 6. sing-box 1.13 拒絕舊 DNS 格式

**症狀**：

```
FATAL legacy DNS servers is deprecated in sing-box 1.12.0 and will be removed in sing-box 1.14.0
FATAL to continuing using this feature, set environment variable ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true
```

**原因**：`dns.servers` 舊格式（`{"address": "8.8.8.8", "detour": "..."}`）喺 1.12 起棄用，1.13 直接 fatal。

**解法**：純出口用嘅 socks 代理**根本唔需要 `dns` 段**，直接拆走最乾淨。`scripts/03-build-egress.py` 生成嘅設定已經冇 DNS 段。

---

## 7. Hermes provider 改名做 `gemini` 就壞

**症狀**：

```
No usable credentials found for provider 'gemini'. Set GOOGLE_API_KEY, GEMINI_API_KEY.
```

明明 `config.yaml` 入面已經寫咗 `base_url` 同 `api_key`。

**原因**：`gemini` 係 Hermes **內建 provider 名**，會行 Google 原生認證路徑，完全無視你寫嘅 `api_key`。

**解法**：改個唔撞嘅名（例如 `antigravity`）：

```bash
hermes config unset providers.gemini
hermes config set providers.antigravity.base_url "http://YOUR_SERVER:8081/v1"
hermes config set providers.antigravity.api_key "YOUR_API_KEY"
hermes config set providers.antigravity.api_mode "openai"
hermes config set providers.antigravity.default_model "gemini-3.1-pro-low"
```

---

## 8. 改咗 Hermes 預設模型但冇生效

**原因**：gateway 係**啟動時**讀 config。CLI 新開嘅 session 即刻用新設定，但 launchd / systemd supervise 緊嗰個 gateway 仍然行舊嘅。

**解法**：

```bash
hermes gateway restart
```

會先 drain 進行中嘅 turn（預設最多 180 秒），drain 唔切就強制重啟 —— 即係當時進行中嘅 turn 會被打斷。揀個靜嘅時間做。

重啟之後 gateway 需要少少時間 warm up，太快打 `hermes -z` 有機會食到 `API call failed after 3 retries: Connection error.`，等一陣再試。

---

## 9. LiteLLM 話 model 唔存在

**症狀**：`litellm_config.yaml` 加咗但用唔到。

**原因**：漏咗 `openai/` 前綴。LiteLLM 靠前綴決定用邊個 handler。

```yaml
# ✗ 錯
model: gemini-3.1-pro-low

# ✓ 啱
model: openai/gemini-3.1-pro-low
```

---

## 10. 其他 provider 突然全部改咗行代理

**原因**：`proxy-url` 係**全局**設定，一填就影響 config 入面每一個 provider。

**解法**：想只有 Google 走代理，就唔好填頂層 `proxy-url`，改為喺個別 auth / api-key entry 寫 per-entry `proxy-url`。想明確直連可以寫 `proxy-url: "direct"`。

---

## 11. Token 幾時過期

- Antigravity token 有 refresh token，CLIProxyAPI 會自動續。
- 帳號改密碼、撤銷授權、或者長期唔用，就要重行一次 `-antigravity-login`。
- 多帳號可以同時放喺 `auth-dir`，CLIProxyAPI 會 round-robin 兼自動 failover。

---

## 診斷次序建議

```bash
# 1. 服務生存？
systemctl is-active cliproxyapi

# 2. 有冇 token？
ls -la ~/.cli-proxy-api/*.json

# 3. 模型出唔出到？
curl -s -H "Authorization: Bearer KEY" http://127.0.0.1:8081/v1/models | jq '.data | length'

# 4. 出口啱唔啱？
curl -s --proxy socks5h://127.0.0.1:1081 https://ipinfo.io/json | jq '{ip,country}'

# 5. 真調用
curl -s -X POST http://127.0.0.1:8081/v1/chat/completions -H "Authorization: Bearer KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-3.1-pro-low","messages":[{"role":"user","content":"hi"}]}'

# 6. 詳細錯誤（config 開 debug: true 之後）
ls -t ~/.cli-proxy-api/logs/ | head -5
```
