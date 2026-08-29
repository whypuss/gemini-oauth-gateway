#!/usr/bin/env python3
"""由 vmess 訂閱生成 sing-box socks5 出口設定。

Gemini / Antigravity 按地區封鎖，出口 IP 唔喺支援地區就一定調用失敗。
呢個腳本由訂閱抽節點，砌成一個 urltest（自動選最快）嘅 socks5 出口。

用法:
    python3 03-build-egress.py --sub "https://your-sub-url" --out /tmp/gemini-egress.json
    python3 03-build-egress.py --file nodes.txt --count 20 --port 1081

輸出設定刻意**冇 dns 段** —— sing-box 1.13 會 fatal 喺舊式 dns.servers 格式，
而純出口代理根本唔需要自己嗰套 DNS。
"""
from __future__ import annotations

import argparse
import base64
import json
import sys
import urllib.request


def fetch(src: str, is_file: bool) -> str:
    if is_file:
        return open(src, encoding="utf-8", errors="replace").read()
    req = urllib.request.Request(src, headers={"User-Agent": "curl/8"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read().decode("utf-8", errors="replace")


def maybe_b64_decode(text: str) -> str:
    """訂閱成份可能係 base64 包住一堆 vmess:// 行。"""
    if "://" in text:
        return text
    padded = text.strip() + "=" * (-len(text.strip()) % 4)
    try:
        return base64.b64decode(padded).decode("utf-8", errors="replace")
    except Exception:
        return text


def parse_vmess(lines: list[str]) -> list[dict]:
    nodes = []
    for line in lines:
        line = line.strip()
        if not line.startswith("vmess://"):
            continue
        raw = line[len("vmess://"):]
        raw += "=" * (-len(raw) % 4)
        try:
            nodes.append(json.loads(base64.b64decode(raw)))
        except Exception:
            continue
    return nodes


def to_outbound(node: dict, tag: str) -> dict:
    host = node.get("host") or node.get("add")
    out = {
        "type": "vmess",
        "tag": tag,
        "server": node["add"],
        "server_port": int(node["port"]),
        "uuid": node["id"],
        "security": node.get("scy") or "auto",
        "alter_id": int(node.get("aid") or 0),
    }
    net = node.get("net", "tcp")
    if net == "ws":
        out["transport"] = {
            "type": "ws",
            "path": node.get("path") or "/",
            "headers": {"Host": host},
        }
    elif net in ("grpc", "h2"):
        out["transport"] = {"type": net, "service_name": node.get("path") or ""}
    if str(node.get("tls", "")).lower() in ("tls", "1", "true"):
        out["tls"] = {
            "enabled": True,
            "server_name": node.get("sni") or host,
            "insecure": str(node.get("insecure", "0")) == "1",
        }
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--sub", help="訂閱 URL")
    src.add_argument("--file", help="本地檔案，一行一個 vmess://")
    ap.add_argument("--out", default="/tmp/gemini-egress.json", help="輸出路徑")
    ap.add_argument("--count", type=int, default=15, help="用幾多個節點（預設 15）")
    ap.add_argument("--port", type=int, default=1081, help="socks5 監聽 port（預設 1081）")
    ap.add_argument("--listen", default="127.0.0.1", help="socks5 監聽地址（預設只綁 loopback）")
    ap.add_argument("--filter", default="", help="只要 ps 名含呢個字串嘅節點，例如 'us'")
    args = ap.parse_args()

    text = maybe_b64_decode(fetch(args.sub or args.file, is_file=bool(args.file)))
    nodes = parse_vmess(text.splitlines())
    if args.filter:
        nodes = [n for n in nodes if args.filter.lower() in str(n.get("ps", "")).lower()]
    if not nodes:
        print("解唔到任何 vmess 節點（暫時只支援 vmess://）", file=sys.stderr)
        return 1

    chosen = nodes[: args.count]
    tags = [f"node{i:02d}" for i in range(len(chosen))]
    outbounds = [to_outbound(n, t) for n, t in zip(chosen, tags)]

    config = {
        "log": {"level": "warn", "timestamp": True},
        "inbounds": [{
            "type": "socks",
            "tag": "socks-in",
            "listen": args.listen,
            "listen_port": args.port,
        }],
        "outbounds": [
            {
                "type": "urltest",
                "tag": "auto",
                "outbounds": tags,
                "url": "https://www.gstatic.com/generate_204",
                "interval": "5m",
                "tolerance": 60,
            },
            *outbounds,
            {"type": "direct", "tag": "direct"},
        ],
        "route": {"final": "auto"},
    }

    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(config, fh, indent=2)

    print(f"✓ 由 {len(nodes)} 個節點揀咗 {len(chosen)} 個 -> {args.out}")
    print(f"  socks5 會聽 {args.listen}:{args.port}")
    print()
    print("下一步:")
    print(f"  sudo mkdir -p /etc/gemini-egress && sudo cp {args.out} /etc/gemini-egress/config.json")
    print("  sudo cp examples/gemini-egress.service /etc/systemd/system/")
    print("  sudo systemctl daemon-reload && sudo systemctl enable --now gemini-egress")
    print(f"  curl -s --proxy socks5h://127.0.0.1:{args.port} https://ipinfo.io/json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
