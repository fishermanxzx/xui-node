#!/usr/bin/env bash
# xui-node:把一台 Debian / Ubuntu VPS 装成 3x-ui 的 VLESS + Reality 节点(443「偷自己」)。
# https://github.com/fishermanxzx/xui-node
#
# 用法(root):
#   xui-node                    管理菜单
#   xui-node install [选项]      安装 / 重新配置(在终端里一步一步问;加 -y 不问,用参数和默认值)
#   xui-node info               面板地址、登录账号、API token(会显示密码)
#   xui-node status             运行状态
#   xui-node fw [show|apply]    防火墙规则
#   xui-node xray-pin           检查 Xray 内核版本,不对就换回(定时器每 10 分钟跑一次)
#   xui-node update             更新本脚本
#   xui-node help               帮助

set -Eeuo pipefail
umask 022

XUI_NODE_VERSION=1.0.0
REPO=fishermanxzx/xui-node
RAW_URL="https://raw.githubusercontent.com/${REPO}/${XUI_NODE_REF:-main}"

BIN=/usr/local/bin/xui-node
STATE_DIR=/etc/xui-node
RESULT=$STATE_DIR/result.env
FW_CONF=$STATE_DIR/firewall.conf
FW_RULES=$STATE_DIR/firewall.nft
FW_TABLE=xui_node_fw
FW_UNIT=xui-node-fw.service
PIN_UNIT=xui-node-xray-pin
XUI_BIN=/usr/local/x-ui/x-ui
SITE_ROOT=/var/www/xui-node-site
ACME_ROOT=/var/www/acme
NGINX_CONF=/etc/nginx/conf.d/xui-node-site.conf
RENEW_HOOK=/etc/letsencrypt/renewal-hooks/deploy/xui-node.sh
# Nginx 真站点只听 127.0.0.1 的这个端口,给 Reality 当伪装目标
SITE_PORT=8443
TOKEN_NAME=xui-node
DEFAULT_PANEL_PORT=2096
DEFAULT_REALITY_PORT=443
DEFAULT_SOCKS_PORT=10001
DEFAULT_XRAY=v26.6.27

# ---------------- 输出 ----------------
if [[ -t 1 ]]; then
  C_B=$'\033[1;34m' C_G=$'\033[1;32m' C_Y=$'\033[1;33m' C_R=$'\033[1;31m' C_D=$'\033[2m' C_0=$'\033[0m'
else
  C_B='' C_G='' C_Y='' C_R='' C_D='' C_0=''
fi
step() { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_0"; }
info() { printf '    %s\n' "$*"; }
hint() { printf '    %s%s%s\n' "$C_D" "$*" "$C_0"; }
ok() { printf '    %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '    %s[注意]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die() { printf '%s[失败]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

# ---------------- 小工具 ----------------
need_root() { [[ $EUID -eq 0 ]] || die "请用 root 运行(先 sudo -i)"; }
is_ipv4() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
is_domain() { [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; }
# 逗号 / 空格分隔的数字 → 去重排序后用空格连起来
words() { sed 's/,/ /g' <<<"$1" | tr -s '[:space:]' '\n' | sed '/^$/d' | sort -nu | xargs; }
port_owner() { ss -Hltnp "sport = :$1" 2>/dev/null || true; }
rand_hex() { openssl rand -hex "$1"; }
ver_ge() { [[ $(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1) == "$2" ]]; }
trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}
unit_state() {
  case "$(systemctl is-active "$1" 2>/dev/null || true)" in
    active) echo "运行中" ;;
    inactive) echo "没运行" ;;
    failed) echo "失败" ;;
    *) echo "未知" ;;
  esac
}

random_free_port() {
  local p
  for _ in $(seq 1 200); do
    p=$(shuf -i 20000-59999 -n 1)
    [[ -n $(port_owner "$p") ]] || { echo "$p"; return 0; }
  done
  return 1
}

# 结果文件:KEY=VALUE(%q 转义,可 source),只有 root 可读
result_set() {
  local key=$1 value=$2 tmp
  install -d -m 700 "$STATE_DIR"
  touch "$RESULT"
  chmod 600 "$RESULT"
  tmp=$(mktemp "$STATE_DIR/.result.XXXXXX")
  grep -v "^${key}=" "$RESULT" >"$tmp" || true
  printf '%s=%q\n' "$key" "$value" >>"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$RESULT"
}
result_get() {
  [[ -f $RESULT ]] || return 0
  # shellcheck disable=SC1090
  (set +u; . "$RESULT"; printf '%s' "${!1:-}")
}
load_result() {
  [[ -f $RESULT ]] || die "还没装过(没有 $RESULT),先执行 xui-node install"
  # shellcheck disable=SC1090
  . "$RESULT"
}

# ---------------- 3x-ui 接口 ----------------
# 走本机:--resolve 把域名指到 127.0.0.1,证书照常校验(面板用的就是这个域名的证书)
WORK=""
API_PORT=""
WBP=""
HDR=""
work_dir() {
  if [[ -z $WORK ]]; then
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT
  fi
}
api_auth() {
  work_dir
  HDR=$WORK/hdr
  (umask 077; printf 'Authorization: Bearer %s\n' "$1" >"$HDR")
}
# api METHOD PATH [JSON]:输出 obj;success=false 或网络错误时返回非 0(错误写 stderr,不含密钥)
api() {
  local method=$1 path=$2 body=${3-} out
  local args=(-sS --max-time 180 --resolve "${DOMAIN}:${API_PORT}:127.0.0.1" -H @"$HDR" -H 'Accept: application/json' -X "$method")
  [[ -z $body ]] || args+=(-H 'Content-Type: application/json' --data-binary "$body")
  out=$(curl "${args[@]}" "https://${DOMAIN}:${API_PORT}/${WBP}/panel/api${path}") || { echo "请求 $path 失败" >&2; return 1; }
  if ! jq -e 'type == "object" and .success == true' >/dev/null 2>&1 <<<"$out"; then
    echo "接口 $path 返回失败:$(jq -r '.msg? // empty' 2>/dev/null <<<"$out" | head -c 300)" >&2
    return 1
  fi
  jq -c '.obj' <<<"$out"
}
wait_api() {
  for _ in $(seq 1 30); do
    if api GET /server/status >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  api GET /server/status >/dev/null || die "面板接口连不上(本机 ${API_PORT} 端口)"
}
# 用结果文件里的信息连面板
api_from_result() {
  API_PORT=$PANEL_PORT
  WBP=$WEB_BASE_PATH
  api_auth "$PANEL_TOKEN"
}
xray_state() { api GET /server/status | jq -r '"\(.xray.version // "")|\(.xray.state // "")"'; }

# ---------------- 安装:参数 ----------------
usage_install() {
  cat <<EOF
用法: xui-node install [选项]

在终端里运行时会一步一步问,方括号里是默认值;选项填过的就作为默认值。
加 -y(或者不在终端里运行,比如通过 ssh 执行)就不问,直接用选项和默认值,这时 --domain 必填。

  --domain FQDN            本机域名(要先解析到本机 IP;Cloudflare 用灰云)
  --panel-port N           面板端口(默认 ${DEFAULT_PANEL_PORT})
  --reality-port N         Reality 入站端口(默认 ${DEFAULT_REALITY_PORT})
  --socks-port N           防火墙给 SOCKS 预留的端口,0 = 不预留(默认 ${DEFAULT_SOCKS_PORT};只放行,不建入站)
  --xray-version vX.Y.Z    锁定的 Xray 内核版本(默认 ${DEFAULT_XRAY});keep = 用 3x-ui 自带的、不锁定
  --xui-version vX.Y.Z     3x-ui 版本(默认最新 release)
  --no-firewall            不启用本脚本的防火墙
  --ssh-port N[,N]         防火墙放行的 SSH 端口(默认按 sshd 配置和当前连接)
  --remark NAME            Reality 入站备注(默认域名第一段)
  --ip IP                  本机公网 IPv4(默认自动探测)
  --acme-email EMAIL       Let's Encrypt 账号邮箱(可不填)
  --skip-dns-check         不检查域名是否已解析到本机
  -y, --yes                不问,直接装
EOF
}

need_arg() { [[ $# -ge 2 && -n $2 ]] || die "$1 后面要跟一个值"; }

# ---------------- 安装:检查 ----------------
OS_ID="" OS_LIKE="" OS_VER="" OS_NAME=""
preflight() {
  [[ -r /etc/os-release ]] || die "认不出系统(没有 /etc/os-release)"
  eval "$(. /etc/os-release; printf 'OS_ID=%q OS_LIKE=%q OS_VER=%q OS_NAME=%q\n' "${ID:-}" "${ID_LIKE:-}" "${VERSION_ID:-}" "${PRETTY_NAME:-}")"
  case "$OS_ID" in
    debian) ver_ge "${OS_VER:-99}" 11 || die "Debian 版本太旧(要 11 以上,当前 $OS_NAME)" ;;
    ubuntu) ver_ge "${OS_VER:-99}" 22.04 || die "Ubuntu 版本太旧(要 22.04 以上,当前 $OS_NAME)" ;;
    *) [[ " $OS_LIKE " == *" debian "* ]] || die "只支持 Debian / Ubuntu(当前 ${OS_NAME:-未知})" ;;
  esac
  case "$(uname -m)" in x86_64 | amd64 | aarch64 | arm64) ;; *) die "不支持的架构 $(uname -m)" ;; esac
  command -v systemctl >/dev/null || die "需要 systemd"
  if ! command -v curl >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates >/dev/null
  fi
}

detect_ip() {
  [[ -n $PUBLIC_IP ]] || PUBLIC_IP=$(curl -4 -fsS --max-time 10 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '$1=="ip"{print $2}' || true)
  [[ -n $PUBLIC_IP ]] || PUBLIC_IP=$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)
  is_ipv4 "$PUBLIC_IP" || die "探测不到本机公网 IPv4,用 --ip 指定"
}

detect_ssh_ports() {
  local p
  p=$( (sshd -T 2>/dev/null || true) | awk '$1=="port"{print $2}' | xargs)
  # 当前这条 SSH 连接用的端口也放行,免得把自己关在外面
  [[ -z ${SSH_CONNECTION:-} ]] || p="$p $(awk '{print $4}' <<<"$SSH_CONNECTION")"
  words "${p:-22}"
}

# 通过 Cloudflare DoH 查 A 记录(不用本机 DNS 缓存)
RESOLVED=""
dns_points_here() {
  RESOLVED=$(curl -fsS --max-time 10 -H 'accept: application/dns-json' "https://1.1.1.1/dns-query?name=${DOMAIN}&type=A" 2>/dev/null |
    grep -oE '"data":"[0-9]{1,3}(\.[0-9]{1,3}){3}"' | cut -d'"' -f4 | xargs || true)
  [[ " $RESOLVED " == *" $PUBLIC_IP "* ]]
}

declare -A PORT_LABEL=([PANEL_PORT]="面板端口" [REALITY_PORT]="Reality 端口" [SOCKS_PORT]="SOCKS 端口")
# check_port 变量名 值:不合适就说明原因并返回 1
check_port() {
  local self=$1 v=$2 p name s w o
  if [[ $self == SOCKS_PORT && $v == 0 ]]; then return 0; fi
  is_port "$v" || { warn "端口要是 1-65535 的数字"; return 1; }
  p=$((10#$v))
  if [[ $p == 80 ]]; then warn "80 留给签证书用"; return 1; fi
  if [[ $p == "$SITE_PORT" ]]; then warn "$SITE_PORT 是本机 Nginx 站点的端口(Reality 的伪装目标)"; return 1; fi
  for s in $SSH_PORTS; do
    if [[ $p == "$s" ]]; then warn "和 SSH 端口重了"; return 1; fi
  done
  for name in PANEL_PORT REALITY_PORT SOCKS_PORT; do
    [[ $name != "$self" ]] || continue
    o=${!name:-}
    is_port "$o" || continue
    if [[ $((10#$o)) == "$p" ]]; then warn "和「${PORT_LABEL[$name]}」重了"; return 1; fi
  done
  # SOCKS 端口只是预留,以后由上层在 3x-ui 里建入站;另外两个要现在就能用
  if [[ $self != SOCKS_PORT ]]; then
    w=$(port_owner "$p")
    if [[ -n $w && ! $w =~ \"(xray-linux[^\"]*|x-ui)\" ]]; then warn "端口 $p 被别的程序占用:${w%%$'\n'*}"; return 1; fi
  fi
}
v_domain() { is_domain "$1" || { warn "不是有效的域名,例如 us1.example.com"; return 1; }; }
v_panel_port() { check_port PANEL_PORT "$1"; }
v_reality_port() { check_port REALITY_PORT "$1"; }
v_socks_port() { check_port SOCKS_PORT "$1"; }
v_xray() { [[ $1 == keep || $1 =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || { warn "写成 v26.6.27 这样,或者 keep"; return 1; }; }
v_email() { [[ $1 =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { warn "邮箱格式不对"; return 1; }; }
v_ssh_ports() {
  local p name o
  [[ -n $(words "$1") ]] || { warn "至少要有一个 SSH 端口"; return 1; }
  for p in $(words "$1"); do
    is_port "$p" || { warn "不是端口: $p"; return 1; }
    for name in PANEL_PORT REALITY_PORT SOCKS_PORT; do
      o=${!name:-}
      is_port "$o" || continue
      if [[ $((10#$o)) == "$((10#$p))" ]]; then warn "SSH 端口 $p 和「${PORT_LABEL[$name]}」重了"; return 1; fi
    done
  done
}

validate_all() {
  local w
  is_domain "$DOMAIN" || die "域名不对: ${DOMAIN:-没填}(用 --domain 指定)"
  DOMAIN=${DOMAIN,,}
  v_ssh_ports "$SSH_PORTS" || die "SSH 端口不对: $SSH_PORTS"
  v_panel_port "$PANEL_PORT" || die "面板端口 $PANEL_PORT 不能用"
  v_reality_port "$REALITY_PORT" || die "Reality 端口 $REALITY_PORT 不能用"
  v_socks_port "$SOCKS_PORT" || die "SOCKS 端口 $SOCKS_PORT 不能用"
  v_xray "$XRAY_VERSION" || die "Xray 版本 $XRAY_VERSION 不对"
  [[ $XRAY_VERSION == keep || $XRAY_VERSION == v* ]] || XRAY_VERSION=v$XRAY_VERSION
  [[ $XUI_VERSION == latest || $XUI_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--xui-version 要写成 latest 或 v3.11.0 这样"
  [[ -z $ACME_EMAIL ]] || v_email "$ACME_EMAIL" || die "邮箱不对: $ACME_EMAIL"
  PANEL_PORT=$((10#$PANEL_PORT))
  REALITY_PORT=$((10#$REALITY_PORT))
  SOCKS_PORT=$((10#$SOCKS_PORT))
  SSH_PORTS=$(words "$SSH_PORTS")
  w=$(port_owner 80)
  [[ -z $w || $w =~ \"nginx\" ]] || die "80 端口被别的程序占用(签证书要用):${w%%$'\n'*}"
  if [[ $SKIP_DNS_CHECK -eq 0 ]] && ! dns_points_here; then
    die "$DOMAIN 现在解析到「${RESOLVED:-没有 A 记录}」,不是本机 $PUBLIC_IP。先把 A 记录指向本机(Cloudflare 用灰云)再装"
  fi
}

# ---------------- 安装:向导 ----------------
# ask 变量名 提示 默认值 [校验函数]
ask() {
  local __name=$1 __prompt=$2 __def=$3 __check=${4:-} __ans
  while :; do
    if [[ -n $__def ]]; then
      read -rp "    $__prompt [$__def]: " __ans || die "输入中断"
    else
      read -rp "    $__prompt: " __ans || die "输入中断"
    fi
    __ans=$(trim "${__ans:-$__def}")
    if [[ -z $__ans ]]; then warn "不能为空"; continue; fi
    if [[ -z $__check ]] || "$__check" "$__ans"; then
      printf -v "$__name" '%s' "$__ans"
      return 0
    fi
  done
}
# ask_yn 提示 默认(y|n):是返回 0
ask_yn() {
  local a h=y/N
  [[ $2 != y ]] || h=Y/n
  while :; do
    read -rp "    $1 [$h]: " a || die "输入中断"
    a=$(trim "${a:-$2}")
    case "${a,,}" in
      y | yes) return 0 ;;
      n | no) return 1 ;;
      *) warn "请输入 y 或 n" ;;
    esac
  done
}
ask_title() { printf '\n%s[%s/6] %s%s\n' "$C_B" "$1" "$2" "$C_0"; }

wizard() {
  local a
  printf '\n%sxui-node %s 安装向导%s\n' "$C_B" "$XUI_NODE_VERSION" "$C_0"
  info "系统 $OS_NAME,公网 IP $PUBLIC_IP"
  hint "每一步直接回车就用方括号里的默认值。"

  ask_title 1 "域名"
  hint "要一个已经解析到本机 $PUBLIC_IP 的域名:签真证书,也给 Reality 当伪装站点。"
  hint "用 Cloudflare 的话要灰云(仅 DNS),不能开代理(小黄云)。"
  ask DOMAIN "域名" "$DOMAIN" v_domain
  DOMAIN=${DOMAIN,,}
  if [[ $SKIP_DNS_CHECK -eq 0 ]]; then
    until dns_points_here; do
      warn "$DOMAIN 现在解析到「${RESOLVED:-没有 A 记录}」,不是本机 $PUBLIC_IP"
      hint "刚改的记录可能要等一两分钟。"
      read -rp "    回车重新检查 / 输入 c 换个域名 / 输入 s 跳过检查: " a || die "输入中断"
      case "$(trim "${a,,}")" in
        s) SKIP_DNS_CHECK=1; warn "跳过检查;解析不对的话后面签证书会失败"; break ;;
        c) ask DOMAIN "域名" "" v_domain; DOMAIN=${DOMAIN,,} ;;
        *) ;;
      esac
    done
    [[ $SKIP_DNS_CHECK -eq 1 ]] || ok "$DOMAIN 已解析到本机"
  fi
  read -rp "    证书提醒邮箱(可留空,直接回车): " a || die "输入中断"
  a=$(trim "$a")
  while [[ -n $a ]] && ! v_email "$a"; do
    read -rp "    证书提醒邮箱(可留空,直接回车): " a || die "输入中断"
    a=$(trim "$a")
  done
  ACME_EMAIL=${a:-$ACME_EMAIL}

  ask_title 2 "面板端口"
  hint "3x-ui 面板走 HTTPS,用同一张证书。3x-ui 自带的订阅服务会关掉(它默认也占 2096)。"
  ask PANEL_PORT "面板端口" "$PANEL_PORT" v_panel_port

  ask_title 3 "Reality 端口"
  hint "VLESS + Reality 入站,所有用户共用这一个端口。没通过 Reality 认证的访问看到的是本机的真站点。"
  ask REALITY_PORT "Reality 端口" "$REALITY_PORT" v_reality_port

  ask_title 4 "SOCKS 预留端口"
  hint "只在防火墙放行,不建入站;留给管理程序以后在 3x-ui 里建 SOCKS 用。填 0 不预留。"
  ask SOCKS_PORT "SOCKS 端口" "$SOCKS_PORT" v_socks_port

  ask_title 5 "Xray 内核版本"
  hint "通过 3x-ui 接口切换,之后每 10 分钟检查一次,被面板或 3x-ui 升级换掉了就自动换回。"
  hint "填 keep 就用 3x-ui 自带的版本,不锁定。"
  ask XRAY_VERSION "Xray 版本" "$XRAY_VERSION" v_xray

  ask_title 6 "防火墙"
  hint "nftables:只放行 SSH、80 和上面几个端口(对所有 IP),其余入站连接全部丢弃。"
  if ask_yn "启用防火墙" "$([[ $FIREWALL == 1 ]] && echo y || echo n)"; then
    FIREWALL=1
    ask SSH_PORTS "SSH 端口(多个用逗号隔开)" "$(words "$SSH_PORTS" | tr ' ' ',')" v_ssh_ports
  else
    FIREWALL=0
  fi
}

fw_open_ports() {
  local p="80 $REALITY_PORT $PANEL_PORT"
  [[ $SOCKS_PORT == 0 ]] || p="$p $SOCKS_PORT"
  words "$p"
}

show_plan() {
  printf '\n'
  info "域名          $DOMAIN"
  info "公网 IP       $PUBLIC_IP"
  info "面板端口      $PANEL_PORT(HTTPS)"
  info "Reality 端口  $REALITY_PORT(伪装目标 127.0.0.1:$SITE_PORT 上的本机站点,SNI $DOMAIN)"
  if [[ $SOCKS_PORT == 0 ]]; then info "SOCKS 预留    不预留"; else info "SOCKS 预留    $SOCKS_PORT(只放行,不建入站)"; fi
  if [[ $XRAY_VERSION == keep ]]; then info "Xray 内核     3x-ui 自带的版本,不锁定"; else info "Xray 内核     $XRAY_VERSION(锁定)"; fi
  if [[ $FIREWALL == 1 ]]; then
    info "防火墙        放行 TCP $(words "$SSH_PORTS $(fw_open_ports)" | sed 's/ /, /g'),其余丢弃"
  else
    info "防火墙        不启用"
  fi
}

# ---------------- 安装:各步骤 ----------------
setup_deps() {
  local out
  step "安装依赖(curl jq nginx certbot nftables …)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates jq nginx certbot nftables openssl iproute2 >/dev/null
  # 甲骨文云等镜像自带 iptables 规则,会和本脚本的规则叠加,把 80/443 挡掉
  out=$(iptables -S INPUT 2>/dev/null || true)
  if grep -qE -- '-P INPUT DROP|-j (REJECT|DROP)' <<<"$out"; then
    warn "系统里还有 iptables 规则在拦入站连接(甲骨文云等镜像常见),可能挡掉 80 / 443,请先清理:iptables -S INPUT"
  fi
}

setup_firewall() {
  step "防火墙(nftables)"
  if [[ $FIREWALL != 1 ]]; then
    systemctl disable "$FW_UNIT" >/dev/null 2>&1 || true
    if nft list table inet "$FW_TABLE" >/dev/null 2>&1; then
      nft delete table inet "$FW_TABLE"
      info "已撤掉之前装的防火墙规则"
    else
      info "不启用"
    fi
    return 0
  fi
  install -d -m 700 "$STATE_DIR"
  printf 'SSH_PORTS=%q\nOPEN_PORTS=%q\n' "$SSH_PORTS" "$(fw_open_ports)" >"$FW_CONF"
  cat >"/etc/systemd/system/$FW_UNIT" <<EOF
[Unit]
Description=xui-node firewall (nftables table inet ${FW_TABLE})
Wants=network-pre.target
Before=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f ${FW_RULES}
ExecStop=/usr/sbin/nft delete table inet ${FW_TABLE}

[Install]
WantedBy=multi-user.target
EOF
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
    warn "ufw 开着,会和本脚本的规则叠加,已关闭 ufw"
    ufw --force disable >/dev/null
  fi
  fw_apply
  systemctl daemon-reload
  systemctl enable "$FW_UNIT" >/dev/null 2>&1
  info "开机自动加载;查看:xui-node fw"
  hint "服务商如果还有安全组 / 云防火墙,也要放行这些端口。"
}

fw_render() {
  cat <<EOF
table inet ${FW_TABLE}
delete table inet ${FW_TABLE}
table inet ${FW_TABLE} {
  chain input {
    type filter hook input priority filter; policy drop;
    ct state established,related accept
    ct state invalid drop
    iif "lo" accept
    meta l4proto icmp accept
    meta l4proto ipv6-icmp accept
    udp dport { 68, 546 } accept
    tcp dport { $(words "$SSH_PORTS $OPEN_PORTS" | sed 's/ /, /g') } accept
  }
}
EOF
}
fw_apply() {
  local tmp
  [[ -f $FW_CONF ]] || die "没有 $FW_CONF(防火墙没启用)"
  # shellcheck disable=SC1090
  . "$FW_CONF"
  [[ -n $(words "${SSH_PORTS:-}") ]] || die "$FW_CONF 里没有 SSH 端口,不应用(免得把自己关在外面)"
  tmp=$(mktemp "$STATE_DIR/.fw.XXXXXX")
  fw_render >"$tmp"
  nft -c -f "$tmp" || { rm -f "$tmp"; die "规则检查没通过"; }
  mv "$tmp" "$FW_RULES"
  chmod 600 "$FW_RULES"
  nft -f "$FW_RULES"
  ok "防火墙已生效:放行 TCP $(words "$SSH_PORTS $OPEN_PORTS" | sed 's/ /, /g')"
}

setup_site() {
  local title nginx_ver listen_tls listen_v6 acct
  step "Nginx 站点 + Let's Encrypt 证书"
  install -d -m 755 "$SITE_ROOT" "$ACME_ROOT"
  if [[ ! -f $SITE_ROOT/index.html ]]; then
    title=${DOMAIN%%.*}
    cat >"$SITE_ROOT/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title} · notes</title>
<style>
  body { max-width: 680px; margin: 48px auto; padding: 0 20px; font: 16px/1.7 -apple-system, "Segoe UI", Roboto, sans-serif; color: #222; background: #fcfcfa; }
  h1 { font-size: 26px; margin-bottom: 4px; } .sub { color: #777; margin-top: 0; }
  article { border-top: 1px solid #e6e6e0; padding: 18px 0; } time { color: #999; font-size: 14px; }
  a { color: #2a5db0; }
</style>
</head>
<body>
<h1>${title}</h1>
<p class="sub">Small notes on home networking, self-hosting and photography.</p>
<article><time>2026-10-02</time><h2>Keeping a home server quiet</h2>
<p>Swapping the stock fans for slower ones and moving the drives onto rubber mounts brought the box down to a hum you only notice at night. The bigger win was letting the disks spin down outside backup hours.</p></article>
<article><time>2026-08-19</time><h2>Film scans, finally organised</h2>
<p>Every roll now lives in a folder named by date and stock, with a plain text file for notes. Boring, but it is the first scheme that has survived more than a month.</p></article>
<article><time>2026-06-07</time><h2>Notes on backups</h2>
<p>Two copies at home, one elsewhere, and a restore test every quarter. The restore test is the part everyone skips and the part that matters.</p></article>
<p><a href="/about.html">About</a></p>
</body>
</html>
EOF
    cat >"$SITE_ROOT/about.html" <<EOF
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>About · ${title}</title></head>
<body style="max-width:680px;margin:48px auto;padding:0 20px;font:16px/1.7 sans-serif;color:#222">
<h1>About</h1><p>A personal site. Nothing here is for sale.</p><p><a href="/">Home</a></p></body></html>
EOF
    printf 'User-agent: *\nAllow: /\n' >"$SITE_ROOT/robots.txt"
  fi

  # 系统自带的 default 站点也占 80 default_server,会冲突
  rm -f /etc/nginx/sites-enabled/default
  nginx_ver=$(nginx -v 2>&1 | sed -n 's#.*nginx/\([0-9.]*\).*#\1#p')
  if ver_ge "$nginx_ver" 1.25.1; then
    listen_tls="listen 127.0.0.1:${SITE_PORT} ssl;
    http2 on;"
  else
    listen_tls="listen 127.0.0.1:${SITE_PORT} ssl http2;"
  fi
  CERT_DIR=/etc/letsencrypt/live/$DOMAIN
  # 内核关了 IPv6 时 Nginx 听 [::]:80 会起不来
  listen_v6=""
  [[ ! -s /proc/net/if_inet6 ]] || listen_v6="listen [::]:80 default_server;"
  write_nginx() {
    {
      cat <<EOF
# 由 xui-node 生成。80:签证书 + 跳转;127.0.0.1:${SITE_PORT}:真站点,给 Reality 当伪装目标
server {
    listen 80 default_server;
    ${listen_v6}
    server_name _;
    location ^~ /.well-known/acme-challenge/ { root ${ACME_ROOT}; default_type text/plain; }
    location / { return 301 https://${DOMAIN}\$request_uri; }
}
EOF
      if [[ -f $CERT_DIR/fullchain.pem ]]; then
        cat <<EOF
server {
    ${listen_tls}
    server_name ${DOMAIN};
    ssl_certificate ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:XUINODE:10m;
    ssl_session_timeout 1d;
    add_header Strict-Transport-Security "max-age=63072000" always;
    root ${SITE_ROOT};
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
      fi
    } >"$NGINX_CONF"
    nginx -t -q
    systemctl enable nginx >/dev/null 2>&1
    systemctl reload nginx 2>/dev/null || systemctl restart nginx
  }
  write_nginx

  if [[ ! -f $CERT_DIR/fullchain.pem ]]; then
    acct=(--register-unsafely-without-email)
    [[ -z $ACME_EMAIL ]] || acct=(-m "$ACME_EMAIL")
    certbot certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" --non-interactive --agree-tos "${acct[@]}" \
      --key-type ecdsa --deploy-hook "systemctl reload nginx" -q ||
      die "签证书失败:确认 $DOMAIN 已解析到本机($PUBLIC_IP)、是灰云,且 80 端口没被服务商的安全组挡住"
  fi
  # 续期后:Nginx 重载;给面板发 HUP 只重启面板网页(不重启 Xray),换上新证书
  install -d -m 755 "$(dirname "$RENEW_HOOK")"
  cat >"$RENEW_HOOK" <<'EOF'
#!/bin/sh
systemctl reload nginx || true
systemctl kill -s HUP --kill-who=main x-ui 2>/dev/null || true
EOF
  chmod 755 "$RENEW_HOOK"
  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
  write_nginx
  curl -fsS --max-time 10 --resolve "$DOMAIN:${SITE_PORT}:127.0.0.1" "https://$DOMAIN:${SITE_PORT}/" -o /dev/null ||
    die "Nginx 127.0.0.1:${SITE_PORT} 没起来"
  ok "证书已签好,站点在 127.0.0.1:${SITE_PORT}(自动续期)"
}

setup_xui() {
  local tmp_port xu xp token tokens settings who
  step "安装 3x-ui"
  work_dir
  if [[ -x $XUI_BIN ]] && systemctl is-active -q x-ui; then
    info "已安装,跳过($($XUI_BIN -v 2>/dev/null | head -1))"
  else
    if [[ $XUI_VERSION == latest ]]; then
      XUI_VERSION=$(curl -fsSL --max-time 20 https://api.github.com/repos/MHSanaei/3x-ui/releases/latest | jq -r .tag_name)
      [[ $XUI_VERSION =~ ^v[0-9] ]] || die "取不到 3x-ui 最新版本号"
    fi
    info "版本 $XUI_VERSION"
    curl -fsSL --max-time 60 "https://raw.githubusercontent.com/MHSanaei/3x-ui/${XUI_VERSION}/install.sh" -o "$WORK/install.sh"
    # 先用临时端口装:3x-ui 自带的订阅服务默认占着 2096,关掉它之后再把面板换到 $PANEL_PORT
    tmp_port=$(random_free_port) || die "挑不到空闲端口"
    # 安装器会把面板账号、密码、token 打印出来:滤掉这些行,只留进度
    if ! XUI_NONINTERACTIVE=1 XUI_PANEL_PORT="$tmp_port" XUI_SSL_MODE=none XUI_DB_TYPE=sqlite XUI_ENABLE_FAIL2BAN=false \
      XUI_SERVER_IP="$PUBLIC_IP" bash "$WORK/install.sh" "$XUI_VERSION" </dev/null \
      > >(grep --line-buffered -Eiv 'password|username|token|webbasepath|access url|dsn|credential|secret' | sed -u 's/^/    | /') 2>&1; then
      wait $! 2>/dev/null || true
      die "3x-ui 安装器失败(上面是它的输出,账号密码那几行已滤掉)"
    fi
    wait $! 2>/dev/null || true
    [[ -x $XUI_BIN ]] || die "3x-ui 没装上"
  fi

  # 面板登录信息:安装器写在 /etc/x-ui/install-result.env,挪进结果文件后删掉
  if [[ -f /etc/x-ui/install-result.env ]]; then
    xu=$(set +u; . /etc/x-ui/install-result.env; printf '%s' "${XUI_USERNAME:-}")
    xp=$(set +u; . /etc/x-ui/install-result.env; printf '%s' "${XUI_PASSWORD:-}")
    [[ -z $xu ]] || result_set PANEL_USERNAME "$xu"
    [[ -z $xp ]] || result_set PANEL_PASSWORD "$xp"
    unset xu xp
    rm -f /etc/x-ui/install-result.env
  fi
  WBP=$($XUI_BIN setting -show 2>/dev/null | sed -n 's/^webBasePath: *//p' | tr -d '/[:space:]')
  [[ -n $WBP ]] || die "读不到面板的 webBasePath"
  result_set WEB_BASE_PATH "$WBP"
  # 不带结尾的 /,管理程序直接拼 /panel/api/...;浏览器打开时加上 /
  result_set PANEL_URL "https://${DOMAIN}:${PANEL_PORT}/${WBP}"
  result_set PANEL_URL_IP "https://${PUBLIC_IP}:${PANEL_PORT}/${WBP}"
  # 面板现在实际在用的端口(刚装好时是临时端口)
  API_PORT=$($XUI_BIN setting -show 2>/dev/null | sed -n 's/^port: *//p' | tr -d '[:space:]')
  is_port "$API_PORT" || die "读不到面板端口"

  # 面板证书:和 Nginx 同一张域名证书
  $XUI_BIN setting -webCert "$CERT_DIR/fullchain.pem" -webCertKey "$CERT_DIR/privkey.pem" >/dev/null

  # API token:每次安装都重新生成名为 xui-node 的 token(旧的作废),只写进结果文件
  token=$($XUI_BIN setting -getApiToken -tokenName "$TOKEN_NAME" -tokenScope admin 2>/dev/null | sed -n 's/^apiToken: *//p' | tail -1)
  [[ -n $token ]] || die "生成 API token 失败"
  result_set PANEL_TOKEN "$token"
  api_auth "$token"
  unset token
  systemctl restart x-ui
  wait_api

  # 安装器自己留的 install token 删掉,只留 xui-node 这一个
  if tokens=$(api GET /setting/apiTokens 2>/dev/null); then
    for id in $(jq -r '.[]? | select(.name == "install") | .id' <<<"$tokens"); do
      api POST "/setting/apiTokens/delete/$id" >/dev/null 2>&1 ||
        warn "删安装器留下的 token 失败(不影响使用,可在面板设置 → API Tokens 里删)"
    done
  fi

  # 订阅备注模板 {{INBOUND}};关掉 3x-ui 自带的订阅服务(它默认占 2096)
  settings=$(api POST /setting/all)
  if [[ $(jq -r '"\(.remarkTemplate // "")|\(.subEnable)"' <<<"$settings") != '{{INBOUND}}|false' ]]; then
    api POST /setting/update "$(jq -c '.remarkTemplate = "{{INBOUND}}" | .subEnable = false' <<<"$settings")" >/dev/null ||
      die "改面板设置失败"
  fi
  [[ $(api POST /setting/all | jq -r '"\(.remarkTemplate)|\(.subEnable)"') == '{{INBOUND}}|false' ]] || die "面板设置没改成"
  unset settings
  info "订阅备注模板 {{INBOUND}},自带订阅服务已关"

  if [[ $API_PORT != "$PANEL_PORT" ]]; then
    $XUI_BIN setting -port "$PANEL_PORT" >/dev/null
    systemctl restart x-ui
    API_PORT=$PANEL_PORT
    wait_api
  fi
  who=$(port_owner "$PANEL_PORT")
  [[ $who =~ \"x-ui\" ]] || die "面板没在 $PANEL_PORT 端口监听(${who:-没有程序在听})"
  ok "面板在 $PANEL_PORT 端口(HTTPS,证书 $DOMAIN)"
}

WANT=""
setup_xray() {
  local cur st=""
  if [[ $XRAY_VERSION == keep ]]; then
    step "Xray 内核:用 3x-ui 自带的版本"
    systemctl disable --now "$PIN_UNIT.timer" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$PIN_UNIT.timer" "/etc/systemd/system/$PIN_UNIT.service"
    systemctl daemon-reload
    info "不锁定版本"
    return 0
  fi
  step "Xray 内核换成 $XRAY_VERSION(通过 3x-ui 接口)"
  WANT=${XRAY_VERSION#v}
  cur=$(xray_state | cut -d'|' -f1)
  if [[ $cur != "$WANT" ]]; then
    info "当前 ${cur:-未知},切换中(要下载,可能要一两分钟)"
    api POST "/server/installXray/${XRAY_VERSION}" >/dev/null ||
      die "3x-ui 接口切换 Xray 失败(版本不在它从 GitHub 取到的列表里?)"
  fi
  for _ in $(seq 1 30); do
    st=$(xray_state 2>/dev/null || true)
    [[ $st != "$WANT|running" ]] || break
    sleep 2
  done
  [[ $st == "$WANT|"* ]] || die "Xray 版本没换过来(现在 ${st:-读不到})"

  # 守护:每 10 分钟查一次,不是这个版本就再通过接口换回来
  cat >"/etc/systemd/system/$PIN_UNIT.service" <<EOF
[Unit]
Description=xui-node: keep 3x-ui Xray core on the pinned version
After=x-ui.service

[Service]
Type=oneshot
ExecStart=${BIN} xray-pin
EOF
  cat >"/etc/systemd/system/$PIN_UNIT.timer" <<'EOF'
[Unit]
Description=xui-node: check Xray core version every 10 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$PIN_UNIT.timer" >/dev/null 2>&1
  ok "Xray $WANT,版本锁定已开(每 10 分钟检查)"
}

setup_inbound() {
  local inbounds existing sni keys sids stream body
  step "VLESS + Reality 入站(端口 $REALITY_PORT,伪装目标 127.0.0.1:$SITE_PORT,SNI $DOMAIN)"
  inbounds=$(api GET /inbounds/list)
  existing=$(jq -c --argjson p "$REALITY_PORT" '[.[]? | select(.port == $p and .protocol == "vless")][0] // empty' <<<"$inbounds")
  if [[ -n $existing ]]; then
    sni=$(jq -r '(.streamSettings | if type == "string" then (fromjson? // {}) else . end) | .realitySettings.serverNames // [] | join(",")' <<<"$existing")
    if [[ $sni == "$DOMAIN" ]]; then
      info "已有,跳过"
    else
      warn "端口 $REALITY_PORT 已有 vless 入站,但 SNI 是「${sni:-空}」不是 $DOMAIN:到面板里把它的 Reality 设置改成 target 127.0.0.1:$SITE_PORT、SNI $DOMAIN"
    fi
    return 0
  fi
  keys=$(api GET /server/getNewX25519Cert)
  sids=$(jq -nc --arg a "$(rand_hex 1)" --arg b "$(rand_hex 2)" --arg c "$(rand_hex 3)" --arg d "$(rand_hex 4)" \
    --arg e "$(rand_hex 5)" --arg f "$(rand_hex 6)" --arg g "$(rand_hex 7)" --arg h "$(rand_hex 8)" '[$a,$b,$c,$d,$e,$f,$g,$h]')
  stream=$(jq -nc --arg d "$DOMAIN" --arg t "127.0.0.1:$SITE_PORT" --argjson k "$keys" --argjson s "$sids" '{
    network: "tcp", security: "reality", externalProxy: [],
    tcpSettings: { acceptProxyProtocol: false, header: { type: "none" } },
    realitySettings: {
      show: false, xver: 0, target: $t, serverNames: [$d],
      privateKey: $k.privateKey, minClientVer: "", maxClientVer: "", maxTimediff: 0, shortIds: $s, mldsa65Seed: "",
      settings: { publicKey: $k.publicKey, fingerprint: "chrome", serverName: "", spiderX: "/", mldsa65Verify: "" }
    }
  }')
  body=$(jq -nc --arg remark "$REMARK" --argjson port "$REALITY_PORT" --arg stream "$stream" '{
    up: 0, down: 0, total: 0, remark: $remark, enable: true, expiryTime: 0, listen: "", port: $port, protocol: "vless",
    settings: ({ clients: [], decryption: "none", encryption: "none", fallbacks: [] } | tojson),
    streamSettings: $stream,
    sniffing: ({ enabled: false, destOverride: ["http", "tls", "quic", "fakedns"], metadataOnly: false, routeOnly: false } | tojson)
  }')
  api POST /inbounds/add "$body" >/dev/null || die "新建入站失败"
  unset keys stream body sids
  ok "已新建(备注 $REMARK,还没有用户)"
}

final_check() {
  local st="" page
  step "重启 Xray 并核对"
  api POST /server/restartXrayService >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    st=$(xray_state 2>/dev/null || true)
    if [[ -n $WANT && $st == "$WANT|running" ]] || [[ -z $WANT && $st == *"|running" ]]; then break; fi
    sleep 2
  done
  [[ $st == *"|running" ]] || die "Xray 没在运行(${st:-读不到状态}),看面板日志"
  [[ -z $WANT || $st == "$WANT|running" ]] || die "Xray 版本不对(${st%%|*})"
  for _ in $(seq 1 10); do
    [[ -z $(port_owner "$REALITY_PORT") ]] || break
    sleep 1
  done
  [[ -n $(port_owner "$REALITY_PORT") ]] || die "端口 $REALITY_PORT 没在监听"
  # 不带 Reality 认证去连,应该被转给 Nginx,看到真站点和真证书
  page=$(curl -fsS --max-time 10 --resolve "$DOMAIN:${REALITY_PORT}:127.0.0.1" "https://$DOMAIN:${REALITY_PORT}/" 2>/dev/null || true)
  [[ $page == *'<title>'* ]] || die "从 $REALITY_PORT 端口访问 https://$DOMAIN 没看到站点(Reality 伪装目标不通?)"
  ok "Xray ${st%%|*} 在运行;$REALITY_PORT 端口没认证的访问看到的是 $DOMAIN 的站点"
}

cmd_install() {
  local yes=0 interactive=0
  DOMAIN="" PANEL_PORT="" REALITY_PORT="" SOCKS_PORT="" XRAY_VERSION="" XUI_VERSION=latest
  SSH_PORTS="" FIREWALL="" REMARK="" PUBLIC_IP="" ACME_EMAIL="" SKIP_DNS_CHECK=0 CERT_DIR=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) need_arg "$@"; DOMAIN=$2; shift 2 ;;
      --panel-port) need_arg "$@"; PANEL_PORT=$2; shift 2 ;;
      --reality-port) need_arg "$@"; REALITY_PORT=$2; shift 2 ;;
      --socks-port) need_arg "$@"; SOCKS_PORT=$2; shift 2 ;;
      --xray-version) need_arg "$@"; XRAY_VERSION=$2; shift 2 ;;
      --xui-version) need_arg "$@"; XUI_VERSION=$2; shift 2 ;;
      --ssh-port) need_arg "$@"; SSH_PORTS=$2; shift 2 ;;
      --no-firewall) FIREWALL=0; shift ;;
      --remark) need_arg "$@"; REMARK=$2; shift 2 ;;
      --ip) need_arg "$@"; PUBLIC_IP=$2; shift 2 ;;
      --acme-email) need_arg "$@"; ACME_EMAIL=$2; shift 2 ;;
      --skip-dns-check) SKIP_DNS_CHECK=1; shift ;;
      -y | --yes) yes=1; shift ;;
      -h | --help) usage_install; return 0 ;;
      *) die "未知参数: $1(xui-node install --help 看参数)" ;;
    esac
  done
  trap 'die "第 $LINENO 行出错(命令: $BASH_COMMAND)"' ERR
  need_root
  if [[ -t 0 && $yes -eq 0 ]]; then interactive=1; fi
  preflight
  ensure_bin
  detect_ip

  # 默认值:选项 > 上次安装 > 内置默认
  [[ -n $DOMAIN ]] || DOMAIN=$(result_get DOMAIN)
  [[ -n $PANEL_PORT ]] || PANEL_PORT=$(result_get PANEL_PORT)
  [[ -n $REALITY_PORT ]] || REALITY_PORT=$(result_get REALITY_PORT)
  [[ -n $SOCKS_PORT ]] || SOCKS_PORT=$(result_get SOCKS_PORT)
  [[ -n $XRAY_VERSION ]] || XRAY_VERSION=$(result_get XRAY_VERSION)
  [[ -n $FIREWALL ]] || FIREWALL=$(result_get FIREWALL)
  PANEL_PORT=${PANEL_PORT:-$DEFAULT_PANEL_PORT}
  REALITY_PORT=${REALITY_PORT:-$DEFAULT_REALITY_PORT}
  SOCKS_PORT=${SOCKS_PORT:-$DEFAULT_SOCKS_PORT}
  XRAY_VERSION=${XRAY_VERSION:-$DEFAULT_XRAY}
  FIREWALL=${FIREWALL:-1}
  [[ -n $SSH_PORTS ]] || SSH_PORTS=$(detect_ssh_ports)

  if [[ $interactive -eq 1 ]]; then
    wizard
    validate_all
    show_plan
    printf '\n'
    ask_yn "开始安装" y || { info "已取消"; exit 0; }
  else
    validate_all
    show_plan
  fi
  REMARK=${REMARK:-${DOMAIN%%.*}}

  setup_deps
  # 依赖装好后(ss 一定有了)再核对一遍端口
  validate_all
  result_set XUI_NODE_VERSION "$XUI_NODE_VERSION"
  result_set DOMAIN "$DOMAIN"
  result_set PUBLIC_IP "$PUBLIC_IP"
  result_set PANEL_PORT "$PANEL_PORT"
  result_set REALITY_PORT "$REALITY_PORT"
  result_set SOCKS_PORT "$SOCKS_PORT"
  result_set XRAY_VERSION "$XRAY_VERSION"
  result_set FIREWALL "$FIREWALL"
  result_set SSH_PORTS "$SSH_PORTS"

  setup_firewall
  setup_site
  setup_xui
  setup_xray
  setup_inbound
  final_check

  step "完成"
  show_plan
  printf '\n'
  info "面板地址、登录账号和 API token 保存在 $RESULT(只有 root 可读,安装过程中没有打印)。"
  info "查看:xui-node info        管理菜单:xui-node"
  info "下一步:登录面板,在 $REALITY_PORT 端口的入站里添加用户;或者把面板地址和 token 交给管理程序。"
}

# 装好管理命令 /usr/local/bin/xui-node(从文件运行就复制自己,否则从 GitHub 下载)
ensure_bin() {
  local src=${BASH_SOURCE[0]:-} tmp
  if [[ -n $src && -f $src ]]; then
    [[ $src -ef $BIN ]] || install -m 755 "$src" "$BIN"
  elif [[ ! -x $BIN ]]; then
    tmp=$(mktemp)
    curl -fsSL --max-time 60 "$RAW_URL/xui-node.sh" -o "$tmp" || { rm -f "$tmp"; die "下载 xui-node 失败"; }
    install -m 755 "$tmp" "$BIN"
    rm -f "$tmp"
  fi
}

# ---------------- 其他命令 ----------------
cmd_info() {
  need_root
  load_result
  printf '\n'
  info "面板地址        ${PANEL_URL:-?}/"
  info "面板地址(IP)    ${PANEL_URL_IP:-?}/"
  info "用户名          ${PANEL_USERNAME:-(不知道,用 x-ui 菜单重置)}"
  info "密码            ${PANEL_PASSWORD:-(不知道,用 x-ui 菜单重置)}"
  info "API token       ${PANEL_TOKEN:-?}"
  printf '\n'
  hint "账号密码是安装时生成的;在面板里改过就以面板为准。"
  hint "管理程序登记这台面板:地址用不带结尾 / 的 PANEL_URL,token 用 PANEL_TOKEN(都在 $RESULT)。"
}

cmd_status() {
  local st="" end="" pin
  need_root
  load_result
  printf '\n'
  info "域名:$DOMAIN    公网 IP:${PUBLIC_IP:-?}"
  info "3x-ui 面板:$(unit_state x-ui)(端口 $PANEL_PORT$([[ -n $(port_owner "$PANEL_PORT") ]] || echo ',没在监听'))"
  if [[ -n ${PANEL_TOKEN:-} ]]; then
    api_from_result
    st=$(api GET /server/status 2>/dev/null | jq -r '"\(.xray.version // "?"),\(.xray.state // "?")"' || true)
  fi
  info "Xray:${st:-读不到}(Reality 端口 $REALITY_PORT$([[ -n $(port_owner "$REALITY_PORT") ]] || echo ',没在监听'))"
  if [[ ${XRAY_VERSION:-keep} == keep ]]; then pin="不锁定"; else pin="$XRAY_VERSION,定时检查$(unit_state "$PIN_UNIT.timer")"; fi
  info "版本锁定:$pin"
  info "Nginx 站点:$(unit_state nginx)"
  if [[ -f /etc/letsencrypt/live/$DOMAIN/cert.pem ]]; then
    end=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$DOMAIN/cert.pem" 2>/dev/null | cut -d= -f2 || true)
  fi
  if [[ -n $end ]]; then info "证书:到期 $end"; else info "证书:没找到"; fi
  if nft list table inet "$FW_TABLE" >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    . "$FW_CONF"
    info "防火墙:开,放行 TCP $(words "$SSH_PORTS $OPEN_PORTS" | sed 's/ /, /g')"
  else
    info "防火墙:没开"
  fi
}

cmd_fw() {
  need_root
  case "${1:-show}" in
    show)
      if nft list table inet "$FW_TABLE" 2>/dev/null; then
        hint "改端口:编辑 $FW_CONF,再执行 xui-node fw apply"
      else
        info "防火墙没开(xui-node install 时可以开)"
      fi
      ;;
    apply) fw_apply ;;
    *) die "用法: xui-node fw show|apply" ;;
  esac
}

cmd_xray_pin() {
  local want cur
  need_root
  [[ -f $RESULT ]] || return 0
  load_result
  [[ ${XRAY_VERSION:-keep} != keep && -n ${PANEL_TOKEN:-} ]] || return 0
  api_from_result
  want=${XRAY_VERSION#v}
  cur=$(api GET /server/status | jq -r '.xray.version // empty') || return 1
  if [[ -z $cur || $cur == "$want" ]]; then
    [[ ! -t 1 ]] || info "Xray ${cur:-?},和锁定的版本一致"
    return 0
  fi
  echo "Xray 内核是 $cur,换回 $XRAY_VERSION"
  api POST "/server/installXray/$XRAY_VERSION" >/dev/null
  echo "已换回 $XRAY_VERSION"
}

cmd_update() {
  local tmp new
  need_root
  tmp=$(mktemp)
  curl -fsSL --max-time 60 "$RAW_URL/xui-node.sh" -o "$tmp" || { rm -f "$tmp"; die "下载失败"; }
  bash -n "$tmp" || { rm -f "$tmp"; die "下载的脚本不完整"; }
  new=$(sed -n 's/^XUI_NODE_VERSION=//p' "$tmp" | head -1)
  install -m 755 "$tmp" "$BIN"
  rm -f "$tmp"
  ok "xui-node 已更新:$XUI_NODE_VERSION → ${new:-?}"
}

cmd_menu() {
  local c
  need_root
  while :; do
    printf '\n%sxui-node %s%s  3x-ui Reality 节点\n' "$C_B" "$XUI_NODE_VERSION" "$C_0"
    if [[ -f $RESULT ]]; then
      hint "$(result_get DOMAIN) · Reality $(result_get REALITY_PORT) · 面板 $(result_get PANEL_PORT)"
    else
      hint "还没安装"
    fi
    cat <<'EOF'

  1. 安装 / 重新配置
  2. 面板地址、账号和 API token(会显示密码)
  3. 运行状态
  4. 防火墙规则
  5. 立即检查 Xray 版本锁定
  6. 更新 xui-node
  7. 打开 3x-ui 自带菜单(x-ui)
  0. 退出

EOF
    read -rp "请选择 [0-7]: " c || { echo; return 0; }
    case "$(trim "$c")" in
      1) (cmd_install) || true ;;
      2) (cmd_info) || true ;;
      3) (cmd_status) || true ;;
      4) (cmd_fw show) || true ;;
      5) (cmd_xray_pin) || true ;;
      6) if (cmd_update); then exec "$BIN"; fi ;;
      7) if command -v x-ui >/dev/null; then x-ui || true; else warn "还没装 3x-ui"; fi ;;
      0 | q) return 0 ;;
      *) warn "请输入 0-7"; continue ;;
    esac
    read -rp "回车返回菜单..." c || return 0
  done
}

usage() {
  cat <<'EOF'
xui-node:把 Debian / Ubuntu VPS 装成 3x-ui 的 VLESS + Reality 节点

  xui-node                    管理菜单
  xui-node install [选项]      安装 / 重新配置(xui-node install --help 看选项)
  xui-node info               面板地址、登录账号、API token(会显示密码)
  xui-node status             运行状态
  xui-node fw [show|apply]    防火墙规则
  xui-node xray-pin           检查 Xray 内核版本,不对就换回
  xui-node update             更新本脚本
  xui-node version            版本号
EOF
}

main() {
  case "${1:-}" in
    "" | menu) cmd_menu ;;
    install) shift; cmd_install "$@" ;;
    info) cmd_info ;;
    status) cmd_status ;;
    fw | firewall) cmd_fw "${2:-show}" ;;
    xray-pin) cmd_xray_pin ;;
    update) cmd_update ;;
    version | -v | --version) echo "xui-node $XUI_NODE_VERSION" ;;
    help | -h | --help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

# 测试时 source 进来只要函数,不执行
if [[ ${XUI_NODE_SOURCED:-0} != 1 ]]; then main "$@"; fi
