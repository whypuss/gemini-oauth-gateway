# gemini-oauth-gateway

把 **Google AI Pro / Antigravity 訂閱** 經 OAuth 反代成一個 **OpenAI 相容 API**，再接落 LiteLLM、Hermes、OpenCode、Claude Code 等任何 OpenAI client。唔使 API key、唔使 GCP 帳單。

> Turn a Google AI Pro (Antigravity) subscription into a self-hosted OpenAI-compatible endpoint via OAuth, then fan it out through LiteLLM to any OpenAI client. Written in Traditional Chinese.

```
Google AI Pro 帳號
      │  Antigravity OAuth
      ▼
CLIProxyAPI  :8081 ──────────── OpenAI / Gemini / Claude 相容端點
      │                                    │
      │ proxy-url                          ├─► LiteLLM :4002  （別名、負載平衡、fallback）
      ▼                                    ├─► Hermes / OpenCode / Claude Code
sing-box socks5 :1081                      └─► 任何 OpenAI SDK
      │
      ▼
合規地區出口（例：美國節點）
```

拎到嘅模型（`owned_by: antigravity`）：

| 類別 | 模型 |
|---|---|
| Gemini Pro | `gemini-3.1-pro-low`、`gemini-pro-agent` |
| Gemini Flash | `gemini-3.7-flash-high`、`gemini-3.6-flash-high`、`gemini-3.5-flash-low`、`gemini-3.5-flash-extra-low`、`gemini-3.1-flash-lite`、`gemini-3-flash`、`gemini-3-flash-agent` |
| 多模態 | `gemini-3.1-flash-image` |
| 附送 | `claude-sonnet-4-6`、`claude-opus-4-6-thinking`、`gpt-oss-120b-medium` |

實際清單以你帳號嘅 `/v1/models` 為準。

---

## ⚠️ 開波前必讀

- 呢個做法用緊 **Antigravity 嘅內部 endpoint 同內建 OAuth client**，唔係 Google 公開 API。**有可能違反 Google ToS，帳號有被限制嘅風險**，上游隨時可以改到你用唔到。自行衡量，後果自負。
- 用你自己嘅帳號、自己嘅機。唔好攞去做共享服務。
- 本 repo **唔包含任何憑證**。所有 key、UUID、訂閱連結、節點資料都係 placeholder，你要自己填。

---

## 你需要有

| 項目 | 說明 |
|---|---|
| 一部 Linux 機 | VPS 或內網機都得。本文以 Ubuntu 24.04 x86_64 為例 |
| 一個 Google 帳號 | 有 Google AI Pro / Antigravity 權限 |
| 一個合規地區出口 | **關鍵**，見 [步驟 2](#步驟-2先搞掂出口否則後面一定失敗) |
| 一部有圖形瀏覽器嘅機 | 行 OAuth 用，可以同 server 唔同機 |

---

## 步驟 1：安裝 CLIProxyAPI

```bash
./scripts/01-install-cliproxyapi.sh
```

或者自己去 [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) releases 攞 binary。

裝完抄一份設定：

```bash
cp examples/config.yaml.example ~/CLIProxyAPI/config.yaml
$EDITOR ~/CLIProxyAPI/config.yaml   # 改 api-keys
```

最少要改嘅欄位：

```yaml
port: 8081
auth-dir: ~/.cli-proxy-api
api-keys:
  - CHANGE_ME_TO_A_LONG_RANDOM_STRING   # 下游 client 用呢個做 Bearer token
proxy-url: ""                            # 步驟 2 之後填
```

> **`proxy-url` 係全局設定** —— 填咗之後 config 入面每一個 provider 都會行呢條線。想只有 Google 走代理，就唔好填呢度，改為喺個別 auth / api-key entry 上面寫 per-entry `proxy-url`。

---

## 步驟 2：先搞掂出口（否則後面一定失敗）

Gemini / Antigravity **按地區封鎖**。出口 IP 喺唔支援嘅地區（例如澳門 MO），OAuth 登入會成功，但一調用就回：

```json
{"error":{"code":400,"message":"User location is not supported for the API use.","status":"FAILED_PRECONDITION"}}
```

先查你部機嘅出口：

```bash
curl -s https://ipinfo.io/json | jq '{ip, country, city, org}'
```

`country` 唔係支援地區就要加代理。呢個 repo 提供一個由 vmess 訂閱生成 sing-box socks5 出口嘅腳本：

```bash
# 由訂閱連結生成設定（預設取頭 15 個節點，urltest 自動選最快）
python3 scripts/03-build-egress.py --sub "https://your-subscription-url" --out /tmp/gemini-egress.json

# 裝做 systemd 服務，socks5 聽 127.0.0.1:1081
sudo cp /tmp/gemini-egress.json /etc/gemini-egress/config.json
sudo cp examples/gemini-egress.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now gemini-egress

# 驗證出口變咗
curl -s --proxy socks5h://127.0.0.1:1081 https://ipinfo.io/json | jq '{ip, country}'
```

然後喺 CLIProxyAPI `config.yaml` 填：

```yaml
proxy-url: "socks5://127.0.0.1:1081"
```

> 用其他方式（WireGuard、機房本身就喺合規地區、現成 socks5）一樣得，呢個腳本只係其中一條路。
>
> **`ALL_PROXY` 環境變數靠唔住** —— Go 嘅 `http.ProxyFromEnvironment` 只讀 `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`。一定要用 `proxy-url`。

---

## 步驟 3：Antigravity OAuth 登入

```bash
./scripts/02-antigravity-login.sh
```

腳本會印出授權 URL 同 callback port。要留意三件事：

**a) callback 一定係 `http://localhost:<port>`**
Google 對呢類 installed-app client 只接受 loopback，唔可以改成公網 IP 或域名。所以無論你喺邊登入，最後都係跳去「登入嗰部機自己嘅 port」。Server 冇圖形界面就要開隧道：

```bash
# 喺有瀏覽器嗰部機行（port 每次唔同，睇腳本輸出）
ssh -f -N -L <port>:127.0.0.1:<port> user@your-server
```

**b) 只有 5 分鐘**
登入程序 300 秒之後就 timeout 退出，callback 會撞到 `ERR_CONNECTION_RESET`，個 code 亦作廢。慢咗就重行一次（port 會變）。

**c) Google 會擋自動化瀏覽器**
用 Playwright / Puppeteer / CDP driven Chrome 去登入，一輸完 email 就會俾 Google 攔（「這個瀏覽器或應用程式可能有安全疑慮」/ "This browser or app may not be secure"），連密碼都未去到。用真人手動撳，或者用沿用真實 user profile 嘅瀏覽器。

成功之後 token 會寫入：

```
~/.cli-proxy-api/antigravity-<你嘅email>.json
```

CLIProxyAPI **會自動熱載入**呢個檔案，唔使重啟。

---

## 步驟 4：驗證

```bash
./scripts/healthcheck.sh --host 127.0.0.1 --port 8081 --key YOUR_API_KEY
```

或者手動：

```bash
curl -s -H "Authorization: Bearer YOUR_API_KEY" http://127.0.0.1:8081/v1/models \
  | jq '[.data[] | select(.owned_by=="antigravity") | .id]'

curl -s -X POST http://127.0.0.1:8081/v1/chat/completions \
  -H "Authorization: Bearer YOUR_API_KEY" -H "Content-Type: application/json" \
  -d '{"model":"gemini-3.1-pro-low","messages":[{"role":"user","content":"say OK"}]}' | jq -r '.choices[0].message.content'
```

見到 `owned_by: antigravity` 嘅模型 + 真實回覆 = 成功。

---

## 步驟 5：接 LiteLLM（可選）

想要人類睇得明嘅別名、多帳號負載平衡、統一計數，就喺 LiteLLM 前面再包一層。抄 `examples/litellm-models.example.yaml` 入你嘅 `litellm_config.yaml` 嘅 `model_list:` 下面：

```yaml
- model_name: gemini-pro
  litellm_params:
    model: openai/gemini-3.1-pro-low
    api_base: http://YOUR_SERVER:8081/v1
    api_key: YOUR_API_KEY
```

重點：模型名要加 `openai/` 前綴，LiteLLM 先會當佢係 OpenAI 相容端點。

```bash
sudo systemctl restart litellm
curl -s -X POST http://YOUR_SERVER:4002/v1/chat/completions \
  -H "Authorization: Bearer YOUR_LITELLM_MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"model":"gemini-pro","messages":[{"role":"user","content":"say OK"}]}' | jq -r '.choices[0].message.content'
```

---

## 步驟 6：接 Hermes（可選）

```bash
./scripts/04-hermes-provider.sh --base-url http://YOUR_SERVER:8081/v1 --api-key YOUR_API_KEY
```

⚠️ **唔好將 provider 改名做 `gemini`** —— 撞 Hermes 內建嘅 Google 原生 provider，會報 `No usable credentials found for provider 'gemini'. Set GOOGLE_API_KEY, GEMINI_API_KEY.`。用 `antigravity` 或者其他名。

改完預設模型要重啟 gateway 先生效：

```bash
hermes gateway restart
```

---

## 其他 client

| Client | 點設定 |
|---|---|
| OpenCode | `OPENAI_BASE_URL=http://YOUR_SERVER:8081/v1`、`OPENAI_API_KEY=YOUR_API_KEY` |
| Claude Code | 指去 `/v1/messages`（CLIProxyAPI 有 Claude 相容端點） |
| OpenAI SDK | `OpenAI(base_url="http://YOUR_SERVER:8081/v1", api_key="YOUR_API_KEY")` |

---

## 出街訪問

CLIProxyAPI 綁 `0.0.0.0` 只係代表內網通。要喺出面用：

- **Cloudflare Tunnel**（推薦，唔使開端口）
- 路由器端口轉發 + 一個夠長嘅 `api-keys`
- Tailscale / WireGuard

千祈唔好裸奔開去公網 —— 個端點等同你 Google 帳號嘅額度。

---

## 疑難排解

全部踩過嘅坑同解法喺 [`docs/troubleshooting.md`](docs/troubleshooting.md)。

---

## 授權

MIT，見 [LICENSE](LICENSE)。呢個 repo 只係文檔同膠水腳本，同 CLIProxyAPI、sing-box、LiteLLM 無隸屬關係。
