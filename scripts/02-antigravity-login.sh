#!/usr/bin/env bash
# 行 Antigravity OAuth 登入，抽出授權 URL 同 callback port，順手印埋 SSH 隧道指令。
#
# 用法: ./02-antigravity-login.sh [--dir ~/CLIProxyAPI] [--config config.yaml]
#
# ⚠️ 登入程序只等 callback 300 秒。開完隧道要即刻撳完 OAuth。
set -euo pipefail

INSTALL_DIR="${HOME}/CLIProxyAPI"
CONFIG="config.yaml"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)    INSTALL_DIR="$2"; shift 2 ;;
    --config) CONFIG="$2";      shift 2 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "未知參數: $1" >&2; exit 1 ;;
  esac
done

cd "$INSTALL_DIR"
[[ -x ./cli-proxy-api ]] || { echo "喺 $INSTALL_DIR 搵唔到 cli-proxy-api" >&2; exit 1; }

LOG=$(mktemp /tmp/ag-login.XXXXXX.log)
echo "==> 開始 Antigravity 登入（log: $LOG）"

# 用 setsid 脫離，令 script 行完之後個等待程序仲喺度
setsid ./cli-proxy-api -config "$CONFIG" -antigravity-login -no-browser \
  > "$LOG" 2>&1 < /dev/null &

for _ in $(seq 1 20); do
  sleep 1
  grep -q 'accounts.google.com/o/oauth2' "$LOG" && break
done

URL=$(grep -o 'https://accounts.google.com/o/oauth2[^ ]*' "$LOG" | tail -1 || true)
if [[ -z "$URL" ]]; then
  echo "攞唔到授權 URL。完整 log:" >&2
  cat "$LOG" >&2
  exit 1
fi

# callback port 由 redirect_uri 抽出來，每次登入都唔同
PORT=$(sed -n 's/.*localhost%3A\([0-9]*\)%2Foauth-callback.*/\1/p' <<<"$URL" | head -1)
[[ -n "$PORT" ]] || PORT=$(grep -o 'localhost:[0-9]*' "$LOG" | head -1 | cut -d: -f2)

REMOTE_USER="${USER}"
REMOTE_HOST=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -n "$REMOTE_HOST" ]] || REMOTE_HOST="your-server"

cat <<EOF

════════════════════════════════════════════════════════════════
 Callback port: ${PORT}   ⏱  只有 300 秒

 1) 喺【有瀏覽器嗰部機】開隧道（如果就係呢部機就跳過）:

      ssh -f -N -L ${PORT}:127.0.0.1:${PORT} ${REMOTE_USER}@${REMOTE_HOST}

 2) 喺瀏覽器開呢條 URL 完成授權:

${URL}

 3) 見到 "Login successful" 就搞掂。
════════════════════════════════════════════════════════════════

等緊 callback…
EOF

for _ in $(seq 1 62); do
  sleep 5
  if grep -qi 'authentication successful' "$LOG"; then
    echo "✓ 登入成功"
    grep -i 'Authenticated as\|Authentication saved' "$LOG" || true
    exit 0
  fi
  if grep -qi 'timed out\|authentication failed' "$LOG"; then
    echo "✗ 登入失敗 / 超時 —— 重行呢個 script（port 會變）" >&2
    tail -3 "$LOG" >&2
    exit 1
  fi
done

echo "✗ 等超時。log: $LOG" >&2
exit 1
