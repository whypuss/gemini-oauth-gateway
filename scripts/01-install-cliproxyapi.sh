#!/usr/bin/env bash
# 安裝 CLIProxyAPI 並註冊做 systemd 服務。
# 用法: ./01-install-cliproxyapi.sh [--dir ~/CLIProxyAPI] [--port 8081] [--user $USER]
set -euo pipefail

INSTALL_DIR="${HOME}/CLIProxyAPI"
PORT=8081
RUN_USER="${USER}"
REPO="router-for-me/CLIProxyAPI"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)  INSTALL_DIR="$2"; shift 2 ;;
    --port) PORT="$2";        shift 2 ;;
    --user) RUN_USER="$2";    shift 2 ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    *) echo "未知參數: $1" >&2; exit 1 ;;
  esac
done

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "唔支援嘅架構: $(uname -m)" >&2; exit 1 ;;
esac

echo "==> 查最新版本"
TAG=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)
[[ -n "$TAG" ]] || { echo "攞唔到版本號" >&2; exit 1; }
VER="${TAG#v}"
echo "    ${TAG} (linux_${ARCH})"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
URL="https://github.com/${REPO}/releases/download/${TAG}/CLIProxyAPI_${VER}_linux_${ARCH}.tar.gz"

echo "==> 下載"
curl -fSL "$URL" -o "$TMP/cpa.tar.gz"
tar -xzf "$TMP/cpa.tar.gz" -C "$TMP"

mkdir -p "$INSTALL_DIR"
BIN=$(find "$TMP" -type f -name 'cli-proxy-api' | head -1)
[[ -n "$BIN" ]] || { echo "壓縮檔入面搵唔到 binary" >&2; exit 1; }
# 用 mv 而唔係 cp，避免覆寫行緊嘅 binary 時中 ETXTBSY
mv -f "$BIN" "$INSTALL_DIR/cli-proxy-api"
chmod +x "$INSTALL_DIR/cli-proxy-api"
find "$TMP" -name 'config.example.yaml' -exec cp {} "$INSTALL_DIR/" \; 2>/dev/null || true

echo "==> 已裝落 $INSTALL_DIR"
"$INSTALL_DIR/cli-proxy-api" --help 2>&1 | head -1 || true

if [[ ! -f "$INSTALL_DIR/config.yaml" ]]; then
  cat > "$INSTALL_DIR/config.yaml" <<YAML
host: ''
port: ${PORT}
proxy-url: ""
tls:
  enable: false
auth-dir: ~/.cli-proxy-api
api-keys:
  - CHANGE_ME_TO_A_LONG_RANDOM_STRING
debug: true
YAML
  echo "==> 已生成 $INSTALL_DIR/config.yaml —— 記住改 api-keys！"
fi

UNIT=/etc/systemd/system/cliproxyapi.service
if [[ ! -f "$UNIT" ]]; then
  echo "==> 註冊 systemd 服務（要 sudo）"
  sudo tee "$UNIT" >/dev/null <<UNITEOF
[Unit]
Description=CLIProxyAPI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/cli-proxy-api -config config.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITEOF
  sudo systemctl daemon-reload
  echo "==> 改完 config.yaml 之後行: sudo systemctl enable --now cliproxyapi"
else
  echo "==> $UNIT 已存在，冇改動。更新 binary 之後行: sudo systemctl restart cliproxyapi"
fi

cat <<TIP

下一步:
  1. 改 ${INSTALL_DIR}/config.yaml 嘅 api-keys
  2. 如果出口地區唔支援 Gemini，先做 scripts/03-build-egress.py 再填 proxy-url
  3. sudo systemctl enable --now cliproxyapi
  4. ./scripts/02-antigravity-login.sh
TIP
