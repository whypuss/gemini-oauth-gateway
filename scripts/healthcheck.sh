#!/usr/bin/env bash
# 由頭到尾查一次成條鏈：服務 → token → 出口 → 模型 → 真調用。
#
# 用法: ./healthcheck.sh --key YOUR_API_KEY [--host 127.0.0.1] [--port 8081]
#                        [--socks 127.0.0.1:1081] [--model gemini-3.1-pro-low]
set -uo pipefail

HOST=127.0.0.1
PORT=8081
KEY=""
SOCKS="127.0.0.1:1081"
MODEL="gemini-3.1-pro-low"
AUTH_DIR="${HOME}/.cli-proxy-api"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)  HOST="$2";  shift 2 ;;
    --port)  PORT="$2";  shift 2 ;;
    --key)   KEY="$2";   shift 2 ;;
    --socks) SOCKS="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --auth-dir) AUTH_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "未知參數: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$KEY" ]] || { echo "要 --key" >&2; exit 1; }
BASE="http://${HOST}:${PORT}/v1"
FAIL=0
ok()   { echo "  ✓ $1"; }
bad()  { echo "  ✗ $1"; FAIL=1; }
warn() { echo "  ! $1"; }

echo "[1/5] systemd 服務"
if command -v systemctl >/dev/null; then
  for svc in cliproxyapi gemini-egress; do
    state=$(systemctl is-active "$svc" 2>/dev/null || echo "n/a")
    [[ "$state" == "active" ]] && ok "$svc: active" || warn "$svc: $state"
  done
else
  warn "冇 systemctl，跳過"
fi

echo "[2/5] OAuth token"
shopt -s nullglob
tokens=("$AUTH_DIR"/*.json)
if (( ${#tokens[@]} )); then
  for t in "${tokens[@]}"; do ok "$(basename "$t")"; done
else
  bad "$AUTH_DIR 冇任何 token —— 行 02-antigravity-login.sh"
fi

echo "[3/5] 出口地區"
egress=$(curl -s -m 15 --proxy "socks5h://${SOCKS}" https://ipinfo.io/json 2>/dev/null \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("ip",""), d.get("country",""))' 2>/dev/null)
if [[ -n "$egress" ]]; then
  ok "經代理: $egress"
  [[ "$egress" == *" MO"* || "$egress" == *" CN"* || "$egress" == *" HK"* ]] && \
    warn "呢個地區 Gemini 好可能唔支援"
else
  warn "socks5://${SOCKS} 連唔通（如果本身就喺支援地區可以無視）"
  direct=$(curl -s -m 15 https://ipinfo.io/json 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("ip",""), d.get("country",""))' 2>/dev/null)
  [[ -n "$direct" ]] && warn "直連出口: $direct"
fi

echo "[4/5] 模型清單"
models=$(curl -s -m 20 -H "Authorization: Bearer ${KEY}" "${BASE}/models" 2>/dev/null)
if [[ -z "$models" ]]; then
  bad "${BASE}/models 冇回應"
else
  summary=$(python3 -c '
import json, sys
try:
    data = json.load(sys.stdin).get("data", [])
except Exception:
    print("PARSE_ERROR"); sys.exit()
ag = [m["id"] for m in data if m.get("owned_by") == "antigravity"]
print(f"{len(data)} total / {len(ag)} antigravity")
' <<<"$models")
  if [[ "$summary" == "PARSE_ERROR" ]]; then
    bad "回應唔係合法 JSON（api-key 錯？）"
  elif [[ "$summary" == *"/ 0 antigravity"* ]]; then
    bad "一個 antigravity 模型都冇 —— OAuth 未做或者 token 過期"
  else
    ok "$summary"
  fi
fi

echo "[5/5] 真調用 ($MODEL)"
resp=$(curl -s -m 90 -X POST "${BASE}/chat/completions" \
  -H "Authorization: Bearer ${KEY}" -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"reply with exactly: OK\"}]}" 2>/dev/null)
content=$(python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("PARSE_ERROR"); sys.exit()
if "choices" in d:
    print("OK:" + (d["choices"][0]["message"].get("content") or "").strip()[:60])
else:
    print("ERR:" + json.dumps(d.get("error", d))[:200])
' <<<"$resp")
case "$content" in
  OK:*)          ok "回覆: ${content#OK:}" ;;
  *"location is not supported"*) bad "地區封鎖 —— 出口 IP 唔喺支援地區，見 docs/troubleshooting.md #2" ;;
  ERR:*)         bad "${content#ERR:}" ;;
  *)             bad "解唔到回應" ;;
esac

echo
[[ "$FAIL" == "0" ]] && echo "✓ 全部通過" || { echo "✗ 有檢查失敗，見 docs/troubleshooting.md"; exit 1; }
