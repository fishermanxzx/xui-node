#!/usr/bin/env bash
# xui-node 安装入口:
#   bash <(curl -fsSL https://raw.githubusercontent.com/fishermanxzx/xui-node/main/install.sh)
# 装好管理命令 /usr/local/bin/xui-node,然后进入安装向导。参数会原样交给 xui-node install,
# 比如 ... install.sh) --domain us1.example.com -y
set -euo pipefail
REF=${XUI_NODE_REF:-main}
URL="https://raw.githubusercontent.com/fishermanxzx/xui-node/${REF}/xui-node.sh"
BIN=/usr/local/bin/xui-node

[[ $EUID -eq 0 ]] || { echo "请用 root 运行(先 sudo -i)" >&2; exit 1; }
if ! command -v curl >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null
fi
tmp=$(mktemp)
if ! curl -fsSL --max-time 60 "$URL" -o "$tmp" || ! bash -n "$tmp"; then
  rm -f "$tmp"
  echo "下载 xui-node 失败:$URL" >&2
  exit 1
fi
install -m 755 "$tmp" "$BIN"
rm -f "$tmp"
export XUI_NODE_REF=$REF
exec "$BIN" install "$@"
