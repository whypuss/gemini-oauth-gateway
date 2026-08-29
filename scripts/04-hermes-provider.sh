#!/usr/bin/env bash
# 將 CLIProxyAPI 註冊做 Hermes 嘅一個 provider。
#
# 用法:
#   ./04-hermes-provider.sh --base-url http://192.168.1.10:8081/v1 --api-key YOUR_KEY
#   ./04-hermes-provider.sh --base-url ... --api-key ... --name antigravity --set-default
#
# ⚠️ provider 名唔可以叫 `gemini` —— 撞 Hermes 內建嘅 Google 原生 provider，
#    會報 "No usable credentials found for provider 'gemini'"。
set -euo pipefail

NAME="antigravity"
BASE_URL=""
API_KEY=""
DEFAULT_MODEL="gemini-3.1-pro-low"
CONTEXT_LENGTH="1000000"
SET_DEFAULT=0
HERMES="${HERMES_BIN:-hermes}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)           NAME="$2";           shift 2 ;;
    --base-url)       BASE_URL="$2";       shift 2 ;;
    --api-key)        API_KEY="$2";        shift 2 ;;
    --default-model)  DEFAULT_MODEL="$2";  shift 2 ;;
    --context-length) CONTEXT_LENGTH="$2"; shift 2 ;;
    --set-default)    SET_DEFAULT=1;       shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "未知參數: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$BASE_URL" && -n "$API_KEY" ]] || { echo "要 --base-url 同 --api-key" >&2; exit 1; }
command -v "$HERMES" >/dev/null || { echo "搵唔到 hermes（可設 HERMES_BIN）" >&2; exit 1; }

if [[ "$NAME" == "gemini" ]]; then
  echo "✗ provider 名唔可以係 'gemini'，會撞 Hermes 內建嘅 Google provider。" >&2
  echo "  試下 --name antigravity" >&2
  exit 1
fi

echo "==> 由 $BASE_URL 讀模型清單"
MODELS_JSON=$(curl -fsS -m 20 -H "Authorization: Bearer ${API_KEY}" "${BASE_URL}/models" \
  | python3 -c '
import json, sys
data = json.load(sys.stdin).get("data", [])
ids = [m["id"] for m in data if m.get("owned_by") == "antigravity"]
if not ids:
    ids = [m["id"] for m in data if "gemini" in m["id"].lower()]
print(json.dumps([{"name": i} for i in ids]))
')

COUNT=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$MODELS_JSON")
if [[ "$COUNT" == "0" ]]; then
  echo "✗ 一個 antigravity 模型都搵唔到 —— OAuth 未做好？先跑 02-antigravity-login.sh" >&2
  exit 1
fi
echo "    搵到 ${COUNT} 個模型"

echo "==> 寫入 Hermes 設定 (providers.${NAME})"
"$HERMES" config set "providers.${NAME}.base_url"       "$BASE_URL"       >/dev/null
"$HERMES" config set "providers.${NAME}.api_key"        "$API_KEY"        >/dev/null
"$HERMES" config set "providers.${NAME}.api_mode"       "openai"          >/dev/null
"$HERMES" config set "providers.${NAME}.default_model"  "$DEFAULT_MODEL"  >/dev/null
"$HERMES" config set "providers.${NAME}.context_length" "$CONTEXT_LENGTH" >/dev/null
"$HERMES" config set "providers.${NAME}.models"         "$MODELS_JSON"    >/dev/null

if [[ "$SET_DEFAULT" == "1" ]]; then
  echo "==> 設做預設模型"
  "$HERMES" config set model.provider "$NAME"          >/dev/null
  "$HERMES" config set model.default  "$DEFAULT_MODEL" >/dev/null
  echo "    ⚠️ gateway 要重啟先生效: hermes gateway restart"
fi

cat <<TIP

✓ 搞掂。試下:

    hermes -z "say OK" --provider ${NAME} -m ${DEFAULT_MODEL}

TIP
