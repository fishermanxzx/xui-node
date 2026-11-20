#!/usr/bin/env bash
# xui-node:把一台 Debian / Ubuntu VPS 装成 3x-ui 节点:VLESS + Reality(TCP 443「偷自己」)或 Hysteria2(UDP 443),二选一。
# https://github.com/fishermanxzx/xui-node
#
# 用法(root):
#   xui-node                    管理菜单
#   xui-node install [选项]      安装 / 重新配置(在终端里一步一步问;加 -y 不问,用参数和默认值)
#   xui-node info               面板地址、登录账号、API token(会显示密码)
#   xui-node status             运行状态
#   xui-node fw [show|apply]    防火墙规则
#   xui-node socks [--rotate]   SOCKS5 入站:建好(或沿用已有的),地址写进结果文件;--rotate 换密码
#   xui-node xray-pin           检查 Xray 内核版本,不对就换回(定时器每 10 分钟跑一次)
#   xui-node update             更新本脚本
#   xui-node help               帮助

set -Eeuo pipefail
umask 022

XUI_NODE_VERSION=1.4.1
REPO=fishermanxzx/xui-node
RAW_URL="https://raw.githubusercontent.com/${REPO}/${XUI_NODE_REF:-main}"

BIN=/usr/local/bin/xui-node
STATE_DIR=/etc/xui-node
RESULT=$STATE_DIR/result.env
FW_CONF=$STATE_DIR/firewall.conf
FW_RULES=$STATE_DIR/firewall.nft
FW_TABLE=xui_node_fw
FW_UNIT=xui-node-fw.service
FW_REVERT=xui-node-fw-revert
PIN_UNIT=xui-node-xray-pin
XUI_DIR=/usr/local/x-ui
XUI_BIN=$XUI_DIR/x-ui
XUI_ETC=/etc/x-ui
XUI_RESULT=$XUI_ETC/install-result.env
XUI_UNIT=/etc/systemd/system/x-ui.service
XUI_ENV=/etc/default/x-ui
# 重装已有的 3x-ui 前,旧数据备份到这里
BACKUP_DIR=$STATE_DIR/backup
BBR_SYSCTL=/etc/sysctl.d/99-xui-node-bbr.conf
BBR_MODULES=/etc/modules-load.d/xui-node-bbr.conf
SITE_ROOT=/var/www/xui-node-site
ACME_ROOT=/var/www/acme
NGINX_CONF=/etc/nginx/conf.d/xui-node-site.conf
RENEW_HOOK=/etc/letsencrypt/renewal-hooks/deploy/xui-node.sh
# Nginx 真站点只听 127.0.0.1 的这个端口,给 Reality 当伪装目标
SITE_PORT=8443
TOKEN_NAME=xui-node
SOCKS_REMARK=socks
DEFAULT_PANEL_PORT=2096
DEFAULT_REALITY_PORT=443
# 节点协议二选一:vless = VLESS + Reality(TCP),hy2 = Hysteria2(UDP,salamander 混淆)
DEFAULT_PROTOCOL=vless
DEFAULT_HY2_PORT=443
# 老版本的结果文件里没有这两项:按 VLESS 节点算
PROTOCOL=$DEFAULT_PROTOCOL
HY2_PORT=$DEFAULT_HY2_PORT
DEFAULT_SOCKS_PORT=10001
# keep = 用 3x-ui 自带的 Xray,不锁定
DEFAULT_XRAY=keep
# 开防火墙后等你确认 SSH 还能登录的秒数,超时自动撤销
FW_CONFIRM_SECONDS=120
APT=(apt-get -o DPkg::Lock::Timeout=600)

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
# 本脚本自己的路径(从文件运行时),否则是装好的管理命令
self_path() {
  local s=${BASH_SOURCE[0]:-}
  if [[ -n $s && -f $s ]]; then echo "$s"; else echo "$BIN"; fi
}

random_free_port() {
  local p
  for _ in $(seq 1 200); do
    p=$(shuf -i 20000-59999 -n 1)
    [[ -n $(port_owner "$p") ]] || { echo "$p"; return 0; }
  done
  return 1
}

# KEY=VALUE 文件(%q 转义,可 source),只有 root 可读;改已有的行时保持原来的位置
env_set() {
  local file=$1 key=$2 tmp
  touch "$file"
  chmod 600 "$file"
  tmp=$(mktemp "$(dirname "$file")/.env.XXXXXX")
  # 值经环境变量传给 awk(-v 会把反斜杠当转义)
  ENV_KEY=$key ENV_LINE="$key=$(printf '%q' "$3")" awk '
    index($0, ENVIRON["ENV_KEY"] "=") == 1 { if (!done) print ENVIRON["ENV_LINE"]; done = 1; next }
    { print }
    END { if (!done) print ENVIRON["ENV_LINE"] }' "$file" >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$file"
}
# 结果文件
result_set() {
  install -d -m 700 "$STATE_DIR"
  env_set "$RESULT" "$1" "$2"
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

# apt:先等 cloud-init 和系统自动更新放开锁(新开的机器常见)
apt_install() {
  local i
  export DEBIAN_FRONTEND=noninteractive
  # 只装新包,不让 needrestart 在 apt 结束时去重启服务(它重启服务时,紧接着的 systemctl 偶尔会失败)
  export NEEDRESTART_SUSPEND=1
  if command -v cloud-init >/dev/null; then timeout 600 cloud-init status --wait >/dev/null 2>&1 || true; fi
  for i in $(seq 1 20); do
    if "${APT[@]}" update -qq; then break; fi
    [[ $i -lt 20 ]] || die "apt-get update 一直失败"
    warn "apt 被占用(系统可能在自动更新),15 秒后重试"
    sleep 15
  done
  "${APT[@]}" install -y -qq "$@" >/dev/null
}

# systemctl enable 偶尔会失败一次(刚装完软件、systemd 还在忙),重试几次;最后还不行就显示它的报错
sd_enable() {
  local i out
  for i in 1 2 3 4 5; do
    out=$(systemctl enable "$@" 2>&1) && return 0
    sleep 2
  done
  die "systemctl enable $* 失败:$(printf '%s' "$out" | tail -n 3)"
}

# ---------------- 3x-ui 接口 ----------------
# 走本机:--resolve 把面板域名指到 127.0.0.1,证书照常校验(面板用的就是这个域名的证书)
WORK=""
API_HOST=""
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
# api METHOD PATH [JSON]:输出 obj;success=false 或网络错误时返回非 0(错误写 stderr,不含密钥)。
# token 走文件、请求体走标准输入,都不出现在命令行里(ps 看不到)
api() {
  local method=$1 path=$2 body=${3-} out url
  local args=(-sS --max-time 180 --resolve "${API_HOST}:${API_PORT}:127.0.0.1" -H @"$HDR" -H 'Accept: application/json' -X "$method")
  url="https://${API_HOST}:${API_PORT}/${WBP}/panel/api${path}"
  if [[ -n $body ]]; then
    out=$(printf '%s' "$body" | curl "${args[@]}" -H 'Content-Type: application/json' --data-binary @- "$url") || { echo "请求 $path 失败" >&2; return 1; }
  else
    out=$(curl "${args[@]}" "$url") || { echo "请求 $path 失败" >&2; return 1; }
  fi
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
# 用结果文件里的信息连面板(先 load_result)
api_from_result() {
  API_HOST=$DOMAIN
  API_PORT=$PANEL_PORT
  WBP=$WEB_BASE_PATH
  api_auth "$PANEL_TOKEN"
}
xray_state() { api GET /server/status | jq -r '"\(.xray.version // "")|\(.xray.state // "")"'; }

# ---------------- 安装:参数 ----------------
usage_install() {
  cat <<EOF
用法: xui-node install [选项]

在终端里运行时会一步一步问,方括号里是默认值(选项给过的、上次装时选的会作为默认值)。
加 -y(或者不在终端里运行,比如通过 ssh 执行)就不问,直接用选项和默认值;第一次装时 --domain 必填。

  --domain FQDN            本机域名(要先解析到本机 IP;Cloudflare 用灰云)
  --panel-port N           面板端口(默认 ${DEFAULT_PANEL_PORT})
  --protocol vless|hy2     节点协议,二选一:vless = VLESS + Reality(TCP),hy2 = Hysteria2(UDP,salamander 混淆)
                           (默认 ${DEFAULT_PROTOCOL};装好后不能直接换,要先在面板里删掉原来的入站)
  --reality-port N         Reality 入站端口,TCP(默认 ${DEFAULT_REALITY_PORT})
  --hy2-port N             Hysteria2 入站端口,UDP(默认 ${DEFAULT_HY2_PORT})
  --socks-port N           SOCKS5 端口,防火墙放行;0 = 不预留(默认 ${DEFAULT_SOCKS_PORT})
  --socks-inbound          在 SOCKS5 端口建好入站(账号密码认证,支持 UDP);不加就只预留端口,以后可以执行 xui-node socks
  --xray-version vX.Y.Z    锁定 Xray 内核版本(通过 3x-ui 接口切换,每 10 分钟检查);默认 keep = 用 3x-ui 自带的、不锁定
  --xui-version vX.Y.Z     3x-ui 版本(默认最新 release)
  --no-firewall            不启用本脚本的防火墙
  --ssh-port N[,N]         防火墙放行的 SSH 端口(默认自动识别:sshd 配置、实际监听、ssh.socket、当前连接,再加上次的)
  --remark NAME            节点入站备注(默认域名第一段;只在新建入站时用)
  --ip IP                  本机公网 IPv4(默认自动探测)
  --acme-email EMAIL       Let's Encrypt 账号邮箱(可不填;只在第一次签证书时用)
  --skip-dns-check         不检查域名是否已解析到本机
  --reinstall-xui          机器上已经有 3x-ui(不是 xui-node 装的)时:旧数据备份到 ${BACKUP_DIR}/ 后卸载,全新安装
  --keep-xui               机器上已经有 3x-ui(不是 xui-node 装的)时:沿用它继续装,入站和用户不动
                           (这两个都不加时,在终端里会问;不在终端里就停下)
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
  command -v curl >/dev/null || apt_install curl ca-certificates
}

detect_ip() {
  [[ -n $PUBLIC_IP ]] || PUBLIC_IP=$(curl -4 -fsS --max-time 10 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '$1=="ip"{print $2}' || true)
  [[ -n $PUBLIC_IP ]] || PUBLIC_IP=$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)
  is_ipv4 "$PUBLIC_IP" || die "探测不到本机公网 IPv4,用 --ip 指定"
}

# 当前这条 SSH 连接连的是本机哪个端口(不是通过 SSH 运行时为空)
current_ssh_port() {
  if [[ -n ${SSH_CONNECTION:-} ]]; then awk '{print $4}' <<<"$SSH_CONNECTION"; fi
}
# SSH 端口:sshd 配置(Port、ListenAddress 里带的端口)+ sshd 实际在听的 + ssh.socket(Ubuntu 22.10 起常由它监听)+ 当前连接
detect_ssh_ports() {
  local p=""
  p+=" $( (sshd -T 2>/dev/null || true) | awk '$1=="port"{print $2} $1=="listenaddress"{n=split($2,a,":"); if (n>1) print a[n]}' || true)"
  p+=" $(ss -Hltnp 2>/dev/null | awk '/"sshd"/{n=split($4,a,":"); print a[n]}' || true)"
  if systemctl is-active -q ssh.socket 2>/dev/null; then
    p+=" $(systemctl show -p Listen ssh.socket 2>/dev/null | grep -oE '[0-9]+ \(Stream\)' | cut -d' ' -f1 || true)"
  fi
  p+=" $(current_ssh_port)"
  words "$p"
}
fw_conf_get() {
  [[ -f $FW_CONF ]] || return 0
  # shellcheck disable=SC1090
  (set +u; . "$FW_CONF"; printf '%s' "${!1:-}")
}

# 通过 Cloudflare DoH 查 A 记录(不用本机 DNS 缓存)
RESOLVED=""
DNS_OK=0
dns_points_here() {
  RESOLVED=$(curl -fsS --max-time 10 -H 'accept: application/dns-json' "https://1.1.1.1/dns-query?name=${DOMAIN}&type=A" 2>/dev/null |
    grep -oE '"data":"[0-9]{1,3}(\.[0-9]{1,3}){3}"' | cut -d'"' -f4 | xargs || true)
  [[ " $RESOLVED " == *" $PUBLIC_IP "* ]]
}

declare -A PORT_LABEL=([PANEL_PORT]="面板端口" [REALITY_PORT]="Reality 端口" [SOCKS_PORT]="SOCKS 端口" [HY2_PORT]="Hysteria2 端口")
# 本脚本占用的 TCP 端口(Hysteria2 走 UDP,不和它们冲突)
tcp_port_names() {
  if [[ ${PROTOCOL:-vless} == hy2 ]]; then echo "PANEL_PORT SOCKS_PORT"; else echo "PANEL_PORT REALITY_PORT SOCKS_PORT"; fi
}
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
  for name in $(tcp_port_names); do
    [[ $name != "$self" ]] || continue
    o=${!name:-}
    is_port "$o" || continue
    if [[ $((10#$o)) == "$p" ]]; then warn "和「${PORT_LABEL[$name]}」重了"; return 1; fi
  done
  # SOCKS 端口只预留(不建入站)时不查占用;要建入站或是另外两个端口,现在就得能用
  if [[ $self != SOCKS_PORT || ${SOCKS_INBOUND:-0} == 1 ]]; then
    w=$(port_owner "$p")
    if [[ -n $w && ! $w =~ \"(xray-linux[^\"]*|x-ui)\" ]]; then warn "端口 $p 被别的程序占用:${w%%$'\n'*}"; return 1; fi
    # 沿用别人装的 3x-ui:Reality / 面板端口上的 Xray 是旧入站,脚本不改它
    if [[ ${EXISTING_XUI:-} == keep && $self != SOCKS_PORT && $w =~ \"xray ]]; then
      warn "端口 $p 上已经有旧入站在用(沿用旧 3x-ui 时脚本不改已有入站):换个端口,或者先在面板里删掉 / 挪开它"
      return 1
    fi
  fi
}
v_domain() { is_domain "$1" || { warn "不是有效的域名,例如 us1.example.com"; return 1; }; }
v_panel_port() { check_port PANEL_PORT "$1"; }
v_reality_port() { check_port REALITY_PORT "$1"; }
port_owner_udp() { ss -Hlunp "sport = :$1" 2>/dev/null || true; }
# Hysteria2 的 UDP 端口:只看 UDP 上有没有别的程序
v_hy2_port() {
  local p w
  is_port "$1" || { warn "端口要是 1-65535 的数字"; return 1; }
  p=$((10#$1))
  w=$(port_owner_udp "$p")
  if [[ -n $w && ! $w =~ \"(xray-linux[^\"]*|x-ui)\" ]]; then warn "UDP 端口 $p 被别的程序占用:${w%%$'\n'*}"; return 1; fi
  if [[ ${EXISTING_XUI:-} == keep && $w =~ \"xray ]]; then
    warn "UDP 端口 $p 上已经有旧入站在用(沿用旧 3x-ui 时脚本不改已有入站):换个端口,或者先在面板里删掉 / 挪开它"
    return 1
  fi
}
v_protocol() { [[ $1 == vless || $1 == hy2 ]] || { warn "协议只能是 vless 或 hy2"; return 1; }; }
v_socks_port() { check_port SOCKS_PORT "$1"; }
v_xray() { [[ $1 == keep || $1 =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || { warn "写成 v26.11.9 这样,或者 keep"; return 1; }; }
v_email() { [[ $1 =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { warn "邮箱格式不对"; return 1; }; }
v_ssh_ports() {
  local p name o
  [[ -n $(words "$1") ]] || { warn "至少要有一个 SSH 端口"; return 1; }
  for p in $(words "$1"); do
    is_port "$p" || { warn "不是端口: $p"; return 1; }
    for name in $(tcp_port_names); do
      o=${!name:-}
      is_port "$o" || continue
      if [[ $((10#$o)) == "$((10#$p))" ]]; then warn "SSH 端口 $p 和「${PORT_LABEL[$name]}」重了"; return 1; fi
    done
  done
}

# 参数的格式、端口冲突、域名解析(向导里已经查过解析的不再查)
validate_inputs() {
  local cur
  is_domain "$DOMAIN" || die "域名不对: ${DOMAIN:-没填}(用 --domain 指定)"
  DOMAIN=${DOMAIN,,}
  # 当前这条 SSH 连接的端口一定放行:不然断开后就连不回来了
  cur=$(current_ssh_port)
  if [[ $FIREWALL == 1 && -n $cur && " $(words "$SSH_PORTS") " != *" $cur "* ]]; then
    SSH_PORTS="$SSH_PORTS $cur"
    warn "当前 SSH 连接用的 $cur 端口也会放行(免得断开后连不回来)"
  fi
  v_ssh_ports "$SSH_PORTS" || die "SSH 端口不对: $SSH_PORTS"
  v_protocol "$PROTOCOL" || die "--protocol 只能是 vless 或 hy2"
  v_panel_port "$PANEL_PORT" || die "面板端口 $PANEL_PORT 不能用"
  if [[ $PROTOCOL == hy2 ]]; then
    v_hy2_port "$HY2_PORT" || die "Hysteria2 端口 $HY2_PORT 不能用"
  else
    v_reality_port "$REALITY_PORT" || die "Reality 端口 $REALITY_PORT 不能用"
  fi
  v_socks_port "$SOCKS_PORT" || die "SOCKS 端口 $SOCKS_PORT 不能用"
  [[ $SOCKS_INBOUND == 0 || $((10#$SOCKS_PORT)) != 0 ]] || die "要建 SOCKS5 入站(--socks-inbound),SOCKS 端口就不能是 0"
  v_xray "$XRAY_VERSION" || die "Xray 版本 $XRAY_VERSION 不对"
  [[ $XRAY_VERSION == keep || $XRAY_VERSION == v* ]] || XRAY_VERSION=v$XRAY_VERSION
  [[ $XUI_VERSION == latest || $XUI_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--xui-version 要写成 latest 或 v3.11.0 这样"
  [[ -z $ACME_EMAIL ]] || v_email "$ACME_EMAIL" || die "邮箱不对: $ACME_EMAIL"
  PANEL_PORT=$((10#$PANEL_PORT))
  REALITY_PORT=$((10#$REALITY_PORT))
  HY2_PORT=$((10#$HY2_PORT))
  SOCKS_PORT=$((10#$SOCKS_PORT))
  SSH_PORTS=$(words "$SSH_PORTS")
  if [[ $SKIP_DNS_CHECK -eq 0 && $DNS_OK -eq 0 ]]; then
    dns_points_here || die "$DOMAIN 现在解析到「${RESOLVED:-没有 A 记录}」,不是本机 $PUBLIC_IP。先把 A 记录指向本机(Cloudflare 用灰云)再装"
    DNS_OK=1
  fi
}

# 装完依赖后(ss 一定有了)再核对一遍端口有没有被别的程序占着
recheck_ports() {
  local w
  w=$(port_owner 80)
  [[ -z $w || $w =~ \"nginx\" ]] || die "80 端口被别的程序占用(签证书要用):${w%%$'\n'*}"
  v_panel_port "$PANEL_PORT" || die "面板端口 $PANEL_PORT 不能用"
  if [[ $PROTOCOL == hy2 ]]; then
    v_hy2_port "$HY2_PORT" || die "Hysteria2 端口 $HY2_PORT 不能用"
  else
    v_reality_port "$REALITY_PORT" || die "Reality 端口 $REALITY_PORT 不能用"
  fi
  if [[ $SOCKS_INBOUND == 1 ]]; then v_socks_port "$SOCKS_PORT" || die "SOCKS 端口 $SOCKS_PORT 不能用"; fi
}

# 本机上本脚本建的 Reality 入站(target 指向本机站点的 vless)要和这次的端口、域名对得上;对不上就停下,什么都不改。
# 对得上 REALITY_EXISTS=1;还没有 REALITY_EXISTS=0
REALITY_EXISTS=0
# 本脚本建的入站:Reality 的伪装目标是本机站点;Hysteria2 用的是 Let's Encrypt 的域名证书
JQ_STREAM='(.streamSettings | if type == "string" then (fromjson? // {}) else . end)'
managed_reality() {
  jq -c --arg t "127.0.0.1:$SITE_PORT" "[.[]? | select(.protocol == \"vless\") | select(($JQ_STREAM.realitySettings.target // \"\") == \$t)]" <<<"$1"
}
managed_hy2() {
  jq -c "[.[]? | select(.protocol == \"hysteria\")
    | select(any($JQ_STREAM.tlsSettings.certificates[]?; (.certificateFile // \"\") | startswith(\"/etc/letsencrypt/live/\")))]" <<<"$1"
}
# 核对面板上已有的入站:一台只能是 VLESS + Reality 或 Hysteria2 其中一种
check_main_inbound() {
  local inbounds=$1 other
  if [[ $PROTOCOL == hy2 ]]; then
    other=$(managed_reality "$inbounds" | jq -r '[.[] | .port | tostring] | join("、")')
    [[ -z $other ]] ||
      die "这台已经是 VLESS + Reality 节点(TCP $other 端口)。一台只能二选一:要换成 Hysteria2,先在面板里删掉 Reality 入站再执行;不换就重新执行时选 VLESS + Reality"
    check_hy2 "$inbounds"
  else
    other=$(managed_hy2 "$inbounds" | jq -r '[.[] | .port | tostring] | join("、")')
    [[ -z $other ]] ||
      die "这台已经是 Hysteria2 节点(UDP $other 端口)。一台只能二选一:要换成 VLESS + Reality,先在面板里删掉 Hysteria2 入站再执行;不换就重新执行时选 Hysteria2"
    check_reality "$inbounds"
  fi
}
check_hy2() {
  local inbounds=$1 managed ib other names
  managed=$(managed_hy2 "$inbounds")
  ib=$(jq -c --argjson p "$HY2_PORT" '[.[] | select(.port == $p)][0] // empty' <<<"$managed")
  if [[ -z $ib ]]; then
    other=$(jq -r '[.[] | .port | tostring] | join("、")' <<<"$managed")
    [[ -z $other ]] ||
      die "本机的 Hysteria2 入站在 UDP $other 端口,这次填的是 $HY2_PORT。脚本不改已有入站的端口(用户的链接都要跟着变):要换就先在面板里改好再重跑,不换就重跑时填 $other"
    # 同一个端口上已经有走 UDP 的入站(TCP 的不冲突)
    other=$(jq -r --argjson p "$HY2_PORT" '[.[]? | select(.port == $p) | select(.protocol == "hysteria" or .protocol == "wireguard" or .protocol == "amneziawg" or .protocol == "tuic")][0]
      | if . == null then "" else (.remark // "") + "(" + (.protocol // "") + ")" end' <<<"$inbounds")
    [[ -z $other ]] || die "面板上 UDP $HY2_PORT 端口已经有入站 $other,换个 Hysteria2 端口,或者先在面板里删掉它"
    HY2_EXISTS=0
    return 0
  fi
  names=$(jq -r "$JQ_STREAM.tlsSettings.serverName // \"\"" <<<"$ib")
  [[ $names == "$DOMAIN" ]] ||
    die "本机 UDP $HY2_PORT 端口 Hysteria2 入站的 SNI 是「${names:-空}」,不是 $DOMAIN。脚本不改已有入站:要换域名就先在面板里把 SNI 和证书改好再重跑,不换就重跑时填原来的域名"
  HY2_EXISTS=1
}
check_reality() {
  local inbounds=$1 managed ib other names
  managed=$(managed_reality "$inbounds")
  ib=$(jq -c --argjson p "$REALITY_PORT" '[.[] | select(.port == $p)][0] // empty' <<<"$managed")
  if [[ -z $ib ]]; then
    other=$(jq -r '[.[] | .port | tostring] | join("、")' <<<"$managed")
    [[ -z $other ]] ||
      die "本机的 Reality 入站在 $other 端口,这次填的是 $REALITY_PORT。脚本不改已有入站的端口(用户的链接都要跟着变):要换就先在面板里改好入站端口再重跑,不换就重跑时填 $other"
    # 走 UDP 的入站(Hysteria2 等)和 TCP 端口不冲突
    other=$(jq -r --argjson p "$REALITY_PORT" '[.[]? | select(.port == $p) | select(.protocol | IN("hysteria", "wireguard", "amneziawg", "tuic") | not)][0]
      | if . == null then "" else (.remark // "") + "(" + (.protocol // "") + ")" end' <<<"$inbounds")
    [[ -z $other ]] || die "面板上 $REALITY_PORT 端口已经有入站 $other,换个 Reality 端口,或者先在面板里删掉它"
    REALITY_EXISTS=0
    return 0
  fi
  names=$(jq -r '(.streamSettings | if type == "string" then (fromjson? // {}) else . end).realitySettings.serverNames // [] | join(" ")' <<<"$ib")
  [[ " $names " == *" $DOMAIN "* ]] ||
    die "本机 $REALITY_PORT 端口 Reality 入站的 SNI 是「${names:-空}」,不含 $DOMAIN。脚本不改已有入站的 SNI:要换域名就先在面板里把 SNI 改成 $DOMAIN 再重跑,不换就重跑时填原来的域名"
  REALITY_EXISTS=1
}

# SOCKS 端口上已有的入站(JSON;没有就输出空)
socks_inbound_on() { jq -c --argjson p "$SOCKS_PORT" '[.[]? | select(.port == $p)][0] // empty' <<<"$1"; }
# SOCKS 端口上已经有别的协议的入站就停下
socks_check_conflict() {
  local ib proto
  ib=$(socks_inbound_on "$1")
  [[ -n $ib ]] || return 0
  proto=$(jq -r '.protocol // ""' <<<"$ib")
  [[ $proto == mixed || $proto == socks ]] ||
    die "面板上 $SOCKS_PORT 端口已经有入站 $(jq -r '.remark // ""' <<<"$ib")($proto),不是 SOCKS。换个 SOCKS 端口(xui-node install --socks-port N),或者先在面板里删掉它"
}

# 重新安装前:用上次的面板信息读已有入站,端口 / 域名对不上就在改任何东西之前停下
precheck_existing() {
  local token domain port wbp inbounds
  token=$(result_get PANEL_TOKEN)
  domain=$(result_get DOMAIN)
  port=$(result_get PANEL_PORT)
  wbp=$(result_get WEB_BASE_PATH)
  [[ -n $token && -n $domain && -n $port && -n $wbp ]] || return 0
  systemctl is-active -q x-ui || return 0
  API_HOST=$domain API_PORT=$port WBP=$wbp
  api_auth "$token"
  if ! inbounds=$(api GET /inbounds/list 2>/dev/null); then
    warn "用上次的信息连不上面板,先不核对已有入站"
    return 0
  fi
  check_main_inbound "$inbounds"
  if [[ $SOCKS_INBOUND == 1 ]]; then socks_check_conflict "$inbounds"; fi
}

# ---------------- 机器上原来就有的 3x-ui ----------------
# EXISTING_XUI:reinstall = 旧数据备份后清空重装;keep = 沿用旧 3x-ui 继续装;空 = 不是这种情况
EXISTING_XUI=""
OLD_XUI_DESC=""
OLD_XRAY_PORTS=""
xui_present() { [[ -e $XUI_BIN || -d $XUI_ETC || -f $XUI_UNIT ]]; }
# 不是本脚本装的:结果文件里没有 xui-node 装过 / 沿用过的记号,也没有本脚本生成的 token
xui_foreign() { xui_present && [[ -z $(result_get XUI_BY) && -z $(result_get PANEL_TOKEN) ]]; }
xui_desc() {
  local v s=没在运行
  v=$("$XUI_BIN" -v 2>/dev/null | head -1 | tr -d '[:space:]' || true)
  ! systemctl is-active -q x-ui || s=运行中
  printf '版本 %s,%s' "${v:-未知}" "$s"
}
# 旧 Xray 对外监听的端口(只听本机的不算),例如 "443/tcp 8443/udp"
xray_public_ports() {
  ss -Hltunp 2>/dev/null | awk '/"xray/ {
      a = $5; p = a; sub(/.*:/, "", p); h = a; sub(/:[^:]*$/, "", h)
      if (h ~ /^(127\.|\[::1\]|::1$|\[::ffff:127\.)/) next
      print p "/" $1 }' | sort -t/ -k1,1n -k2,2 -u | xargs
}
# in_ports 端口 "列表":列表里可以有 起-止
in_ports() {
  local x
  for x in $2; do
    if [[ $x == *-* ]]; then ((10#$1 >= 10#${x%-*} && 10#$1 <= 10#${x#*-})) && return 0; else [[ $((10#$x)) == $((10#$1)) ]] && return 0; fi
  done
  return 1
}
# 沿用旧 3x-ui 时,防火墙会挡住的旧入站端口
old_ports_blocked() {
  local x p proto tcp udp out=""
  [[ $FIREWALL == 1 ]] || return 0
  tcp="$SSH_PORTS $(fw_open_ports) $(fw_conf_get EXTRA_PORTS)"
  udp=$(fw_open_udp)
  for x in $OLD_XRAY_PORTS; do
    p=${x%/*} proto=${x#*/}
    if [[ $proto == tcp ]]; then in_ports "$p" "$tcp" && continue; else in_ports "$p" "$udp" && continue; fi
    out+=" $x"
  done
  echo "${out# }"
}
# 安装前问一次:已有的 3x-ui 是重装还是沿用。不在终端里运行时必须用参数指定
choose_existing_xui() {
  local a
  if ! xui_foreign; then
    [[ -z $EXISTING_XUI ]] || info "3x-ui 是 xui-node 装的(或以前选过沿用),--${EXISTING_XUI}-xui 不生效"
    EXISTING_XUI=""
    return 0
  fi
  OLD_XUI_DESC=$(xui_desc)
  OLD_XRAY_PORTS=$(xray_public_ports)
  if [[ -z $EXISTING_XUI ]]; then
    [[ $INTERACTIVE -eq 1 ]] ||
      die "这台机器上已经装了 3x-ui($OLD_XUI_DESC),不是 xui-node 装的。加 --reinstall-xui(旧数据备份后清空重装)或 --keep-xui(沿用旧 3x-ui 继续装)再执行"
    printf '\n%s已有 3x-ui%s\n' "$C_B" "$C_0"
    info "这台机器上已经装了 3x-ui($OLD_XUI_DESC),不是 xui-node 装的。"
    [[ -z $OLD_XRAY_PORTS ]] || info "旧入站在用的端口:$OLD_XRAY_PORTS"
    info "1) 重装:旧数据(入站、用户、面板账号)先备份到 $BACKUP_DIR/,再卸载旧 3x-ui、全新安装。旧入站上的用户会断开。"
    info "2) 保留:沿用旧 3x-ui 继续装,入站和用户不动;面板换到新端口、关掉自带的订阅服务、新建节点入站。"
    hint "   保留时:节点端口和面板端口上不能已经有旧入站;开了防火墙的话,其它端口上的旧入站会被挡住。"
    while :; do
      read -rp "    选 1 或 2: " a || die "输入中断"
      case "$(trim "$a")" in
        1) EXISTING_XUI=reinstall; break ;;
        2) EXISTING_XUI=keep; break ;;
        *) warn "请输入 1 或 2" ;;
      esac
    done
  fi
  if [[ $EXISTING_XUI == reinstall ]]; then
    if [[ -r $XUI_ENV ]] && grep -q '^XUI_DB_TYPE=postgres' "$XUI_ENV"; then
      die "旧 3x-ui 用的是 PostgreSQL 数据库,脚本不会自动备份它:请先自己备份,卸载旧 3x-ui(x-ui uninstall)后再执行"
    fi
  else
    [[ -x $XUI_BIN ]] || die "旧 3x-ui 不完整(没有 $XUI_BIN),沿用不了:重新执行选「重装」"
    # 本脚本用 x-ui setting -getApiToken -tokenName -tokenScope 生成 token,v3.9.0 起才有 -tokenScope
    a=$("$XUI_BIN" setting -h 2>&1 || true)
    [[ $a == *-getApiToken* && $a == *-tokenScope* ]] ||
      die "旧 3x-ui 版本太老(要 v3.9.0 以上),沿用不了:重新执行选「重装」,或者先升级 3x-ui(x-ui update)"
  fi
}
# 重装:停掉旧 3x-ui,数据和配置整个备份,确认备份好了再卸载
xui_backup_remove() {
  local dir
  info "先备份旧 3x-ui 的数据和配置,再卸载"
  install -d -m 700 "$BACKUP_DIR"
  # 每次一个新目录(mktemp 建的是 700),不会和以前的备份混在一起
  dir=$(mktemp -d "$BACKUP_DIR/x-ui-$(date +%Y%m%d-%H%M%S)-XXXX")
  systemctl stop x-ui 2>/dev/null || true
  [[ ! -d $XUI_ETC ]] || cp -a "$XUI_ETC" "$dir/etc-x-ui"
  [[ ! -f $XUI_DIR/bin/config.json ]] || cp -a "$XUI_DIR/bin/config.json" "$dir/xray-config.json"
  [[ ! -f $XUI_ENV ]] || cp -a "$XUI_ENV" "$dir/default-x-ui"
  [[ ! -f $XUI_UNIT ]] || cp -a "$XUI_UNIT" "$dir/x-ui.service"
  if [[ -f $XUI_ETC/x-ui.db ]]; then
    cmp -s "$XUI_ETC/x-ui.db" "$dir/etc-x-ui/x-ui.db" || die "备份旧数据库失败,没有卸载(旧 3x-ui 已停,systemctl start x-ui 可以恢复)"
  fi
  result_set XUI_BACKUP "$dir"
  systemctl disable x-ui >/dev/null 2>&1 || true
  rm -f "$XUI_UNIT"
  rm -rf "${XUI_UNIT}.d"
  systemctl daemon-reload
  systemctl reset-failed x-ui >/dev/null 2>&1 || true
  rm -rf "$XUI_ETC" "$XUI_DIR"
  rm -f "$XUI_ENV" /usr/bin/x-ui
  ok "旧 3x-ui 已卸载,数据和配置备份在 $dir(只有 root 可读)"
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
  local a b
  printf '\n%sxui-node %s 安装向导%s\n' "$C_B" "$XUI_NODE_VERSION" "$C_0"
  info "系统 $OS_NAME,公网 IP $PUBLIC_IP"
  hint "每一步直接回车就用方括号里的默认值。"

  ask_title 1 "域名"
  hint "要一个已经解析到本机 $PUBLIC_IP 的域名:签真证书(Reality 的伪装站点、Hysteria2 的 TLS 都用它)。"
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
    if [[ $SKIP_DNS_CHECK -eq 0 ]]; then
      DNS_OK=1
      ok "$DOMAIN 已解析到本机"
    fi
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

  ask_title 3 "协议"
  hint "一台节点只用一种协议,所有用户共用一个入站:"
  hint "  1 = VLESS + Reality(TCP):没通过 Reality 认证的访问看到的是本机的真站点和真证书。"
  hint "  2 = Hysteria2(UDP):TLS 用本机域名的证书,开 salamander 混淆(客户端要填混淆密码,分享链接里自带)。"
  a=1
  [[ $PROTOCOL != hy2 ]] || a=2
  while :; do
    read -rp "    协议(1 / 2) [$a]: " b || die "输入中断"
    b=$(trim "${b:-$a}")
    case "${b,,}" in
      1 | vless) PROTOCOL=vless; break ;;
      2 | hy2 | hysteria2) PROTOCOL=hy2; break ;;
      *) warn "请输入 1 或 2" ;;
    esac
  done
  if [[ $PROTOCOL == hy2 ]]; then
    ask HY2_PORT "Hysteria2 端口(UDP)" "$HY2_PORT" v_hy2_port
  else
    ask REALITY_PORT "Reality 端口(TCP)" "$REALITY_PORT" v_reality_port
  fi

  ask_title 4 "SOCKS5"
  hint "给 SOCKS5 预留一个端口(防火墙放行)。可以现在就在这个端口建好 SOCKS5 入站(账号密码认证,支持 UDP),"
  hint "任何支持 SOCKS5 的程序都能用它当代理;也可以先只预留,以后执行 xui-node socks 再建。填 0 不预留。"
  ask SOCKS_PORT "SOCKS 端口" "$SOCKS_PORT" v_socks_port
  if [[ $((10#$SOCKS_PORT)) == 0 ]]; then
    SOCKS_INBOUND=0
  elif ask_yn "现在建 SOCKS5 入站" "$([[ $SOCKS_INBOUND == 1 ]] && echo y || echo n)"; then
    SOCKS_INBOUND=1
    until v_socks_port "$SOCKS_PORT"; do ask SOCKS_PORT "SOCKS 端口" "" v_socks_port; done
    if [[ $((10#$SOCKS_PORT)) == 0 ]]; then SOCKS_INBOUND=0; fi
  else
    SOCKS_INBOUND=0
  fi

  ask_title 5 "Xray 内核版本"
  hint "默认 keep:用 3x-ui 自带的版本,不锁定,3x-ui 升级时跟着升。"
  hint "要锁定就填版本号(例如 v26.11.9):通过 3x-ui 接口切换,之后每 10 分钟检查一次,被换掉了就自动换回。"
  ask XRAY_VERSION "Xray 版本" "$XRAY_VERSION" v_xray

  ask_title 6 "防火墙"
  hint "nftables:只放行 SSH、80 和上面几个端口(对所有 IP),其余入站连接全部丢弃。"
  hint "SSH 端口已自动识别;装到最后才生效,生效后会请你新开一个 SSH 确认能登录,${FW_CONFIRM_SECONDS} 秒内不确认就自动撤销。"
  if ask_yn "启用防火墙" "$([[ $FIREWALL == 1 ]] && echo y || echo n)"; then
    FIREWALL=1
    ask SSH_PORTS "SSH 端口(多个用逗号隔开)" "$(words "$SSH_PORTS" | tr ' ' ',')" v_ssh_ports
  else
    FIREWALL=0
  fi
}

fw_open_ports() {
  local p="80 $PANEL_PORT"
  [[ ${PROTOCOL:-vless} == hy2 ]] || p="$p $REALITY_PORT"
  [[ $SOCKS_PORT == 0 ]] || p="$p $SOCKS_PORT"
  words "$p"
}

# 系统临时端口段(ip_local_port_range),输出 起-止
ephemeral_range() {
  local lo="" hi=""
  if [[ -r /proc/sys/net/ipv4/ip_local_port_range ]]; then read -r lo hi </proc/sys/net/ipv4/ip_local_port_range || true; fi
  if is_port "$lo" && is_port "$hi" && ((lo <= hi)); then echo "$lo-$hi"; else echo "32768-60999"; fi
}
# 要放行的 UDP:
# - Hysteria2 节点:它的 UDP 端口
# - 建了 SOCKS5 入站:新版 Xray 每次 UDP ASSOCIATE 都另开一个系统临时端口收发 UDP,
#   不走 SOCKS 端口本身(老版本走),所以两样都放行。Xray 只收发起认证的那个 IP 发来的包。
# 按起点排序输出,落在端口段里的单个端口不再单列
fw_open_udp() {
  local items=() r="" x p
  [[ ${PROTOCOL:-vless} != hy2 ]] || items+=("$((10#${HY2_PORT:-0}))")
  p=$((10#${SOCKS_PORT:-0}))
  if [[ $p != 0 && ${SOCKS_INBOUND:-0} == 1 ]]; then
    r=$(ephemeral_range)
    items+=("$p" "$r")
  fi
  for x in "${items[@]}"; do
    [[ $x != 0 ]] || continue
    if [[ $x != *-* && -n $r ]] && ((x >= 10#${r%-*} && x <= 10#${r#*-})); then continue; fi
    echo "$x"
  done | sort -t- -k1,1n -u | xargs
}
# 防火墙放行端口的说明:fw_desc TCP端口 [UDP端口]
fw_desc() {
  printf 'TCP %s' "$(sed 's/ /, /g' <<<"$1")"
  [[ -z ${2:-} ]] || printf ';UDP %s' "$(sed 's/ /, /g' <<<"$2")"
  [[ ${2:-} != *-* ]] || printf '(端口段是 SOCKS5 的 UDP 用的系统临时端口)'
}

show_plan() {
  local extra
  printf '\n'
  info "域名          $DOMAIN"
  info "公网 IP       $PUBLIC_IP"
  case $EXISTING_XUI in
    reinstall) info "3x-ui         已有($OLD_XUI_DESC,不是 xui-node 装的):旧数据备份到 $BACKUP_DIR/ 后卸载,全新安装" ;;
    keep) info "3x-ui         已有($OLD_XUI_DESC,不是 xui-node 装的):沿用,入站和用户不动,自带订阅服务关掉" ;;
  esac
  info "面板端口      $PANEL_PORT(HTTPS)"
  if [[ $PROTOCOL == hy2 ]]; then
    info "Hysteria2     UDP $HY2_PORT(TLS 用 $DOMAIN 的证书,salamander 混淆)"
  else
    info "Reality 端口  $REALITY_PORT(伪装目标 127.0.0.1:$SITE_PORT 上的本机站点,SNI $DOMAIN)"
  fi
  if [[ $SOCKS_PORT == 0 ]]; then
    info "SOCKS5        不预留端口"
  elif [[ $SOCKS_INBOUND == 1 ]]; then
    info "SOCKS5        $SOCKS_PORT 端口,建入站(账号密码认证,支持 UDP)"
  else
    info "SOCKS5        预留 $SOCKS_PORT 端口(只放行,不建入站;以后可以执行 xui-node socks)"
  fi
  if [[ $XRAY_VERSION == keep ]]; then info "Xray 内核     3x-ui 自带的版本,不锁定"; else info "Xray 内核     $XRAY_VERSION(锁定)"; fi
  info "BBR           $BBR_NOTE"
  if [[ $FIREWALL == 1 ]]; then
    extra=$(fw_conf_get EXTRA_PORTS)
    info "防火墙        放行 $(fw_desc "$(words "$SSH_PORTS $(fw_open_ports) $extra")" "$(fw_open_udp)"),其余丢弃(SSH:$(words "$SSH_PORTS" | sed 's/ /, /g'))"
  else
    info "防火墙        不启用"
  fi
  if [[ $EXISTING_XUI == keep ]]; then
    extra=$(old_ports_blocked)
    [[ -z $extra ]] || warn "防火墙会挡住旧入站的端口 $extra,用这些端口的旧用户会连不上"
  fi
}

# ---------------- 安装:各步骤 ----------------
setup_deps() {
  local out
  step "安装依赖(curl jq nginx certbot nftables …)"
  apt_install curl ca-certificates jq nginx certbot nftables openssl iproute2 procps kmod
  # 甲骨文云等镜像自带 iptables 规则,会和本脚本的规则叠加,把 80/443 挡掉
  out=$(iptables -S INPUT 2>/dev/null || true)
  if grep -qE -- '-P INPUT DROP|-j (REJECT|DROP)' <<<"$out"; then
    warn "系统里还有 iptables 规则在拦入站连接(甲骨文云等镜像常见),可能挡掉 80 / 443,请先清理:iptables -S INPUT"
  fi
  # ufw 开着会挡签证书用的 80:要用本脚本的防火墙就关掉它,不用就提醒
  out=$(ufw status 2>/dev/null || true)
  if [[ $out == *"Status: active"* ]]; then
    if [[ $FIREWALL == 1 ]]; then
      ufw --force disable >/dev/null
      warn "ufw 开着,会和本脚本的规则叠加,已关闭 ufw"
    else
      warn "ufw 开着:要在 ufw 里放行 $(fw_desc "$(fw_open_ports)" "$(fw_open_udp)"),否则签证书和连接会失败"
    fi
  fi
}

BBR_NOTE="开启"
bbr_state() {
  printf '%s,队列 %s' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')" "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
}

# BBR:写进 sysctl.d(开机生效)并立即生效;内核不支持(OpenVZ / LXC 等容器)就提醒并跳过,不影响安装
setup_bbr() {
  local cc qd
  step "开启 BBR"
  modprobe tcp_bbr 2>/dev/null || true
  if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    warn "这台机器的内核不支持 BBR(OpenVZ / LXC 这类容器常见),跳过"
    BBR_NOTE="内核不支持,没开"
    return 0
  fi
  printf '%s\n' "# xui-node:开启 BBR" "net.core.default_qdisc = fq" "net.ipv4.tcp_congestion_control = bbr" >"$BBR_SYSCTL"
  printf '%s\n' "tcp_bbr" >"$BBR_MODULES"
  sysctl -q -p "$BBR_SYSCTL" >/dev/null 2>&1 || true
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
  qd=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
  if [[ $cc != bbr ]]; then
    warn "BBR 没开成(现在是 ${cc:-未知}),不影响其它步骤"
    BBR_NOTE="没开成(现在是 ${cc:-未知})"
    return 0
  fi
  [[ $qd == fq ]] || hint "队列算法没改成 fq(现在是 ${qd:-未知}),BBR 照样能用"
  BBR_NOTE="已开启"
  ok "BBR 已开启(重启后保持,配置在 $BBR_SYSCTL)"
}

# 申请证书前先自查:在验证目录放一个测试文件,本机用域名访问 80 端口读回来,读不回来就不去找 Let's Encrypt
# (同一域名一小时内验证失败 5 次会被暂时拒绝)。本机访问不经过外网,查不出服务商安全组挡 80 或开了橙云。
# systemctl reload nginx 只发信号就返回,新配置要过一会儿才生效(刚装的 Nginx 还在用系统自带的 default 站点),
# 所以多试几次
acme_selfcheck() {
  local dir=$ACME_ROOT/.well-known/acme-challenge name body got="" i
  install -d -m 755 "$dir"
  name="xui-node-check-$(rand_hex 8)"
  body=$(rand_hex 16)
  printf '%s' "$body" >"$dir/$name"
  chmod 644 "$dir/$name"
  for ((i = 0; i < 15; i++)); do
    got=$(curl -fsS --noproxy '*' --max-time 5 --resolve "$DOMAIN:80:127.0.0.1" "http://$DOMAIN/.well-known/acme-challenge/$name" 2>/dev/null || true)
    [[ $got != "$body" ]] || break
    sleep 1
  done
  rm -f "$dir/$name"
  [[ $got == "$body" ]] ||
    die "本机自查没通过:http://$DOMAIN/.well-known/acme-challenge/ 读不到测试文件(Nginx 80 端口没起来或配置不对),没去申请证书。排查:nginx -t; systemctl status nginx"
  ok "本机自查通过:验证地址能访问"
}

setup_site() {
  local title nginx_ver listen_tls listen_v6 acct site_url site_80
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
  # 内核关了 IPv6 时 Nginx 听 [::]:80 会起不来(procfs 的文件大小总是 0,要看内容)
  listen_v6=""
  [[ -z $(cat /proc/net/if_inet6 2>/dev/null || true) ]] || listen_v6="listen [::]:80 default_server;"
  # 80 端口:VLESS 节点跳到真站点(对外只有 Reality 端口能看到它);Hysteria2 节点没有 TCP 的 HTTPS,80 直接给站点
  site_url="https://${DOMAIN}"
  [[ $REALITY_PORT == 443 ]] || site_url+=":${REALITY_PORT}"
  if [[ $PROTOCOL == hy2 ]]; then
    site_80="location / { root ${SITE_ROOT}; index index.html; try_files \$uri \$uri/ =404; }"
  else
    site_80="location / { return 301 ${site_url}\$request_uri; }"
  fi
  write_nginx() {
    {
      cat <<EOF
# 由 xui-node 生成。80:签证书 + 跳转;127.0.0.1:${SITE_PORT}:真站点,给 Reality 当伪装目标
server {
    listen 80 default_server;
    ${listen_v6}
    server_name _;
    location ^~ /.well-known/acme-challenge/ { root ${ACME_ROOT}; default_type text/plain; }
    ${site_80}
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
    sd_enable nginx
    systemctl reload nginx 2>/dev/null || systemctl restart nginx
  }
  write_nginx

  if [[ ! -f $CERT_DIR/fullchain.pem ]]; then
    acme_selfcheck
    acct=(--register-unsafely-without-email)
    [[ -z $ACME_EMAIL ]] || acct=(-m "$ACME_EMAIL")
    certbot certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" --non-interactive --agree-tos "${acct[@]}" \
      --key-type ecdsa --deploy-hook "systemctl reload nginx" -q ||
      die "签证书失败:确认 $DOMAIN 已解析到本机($PUBLIC_IP)、是灰云,且 80 端口没被服务商的安全组挡住"
  fi
  # 续期后:Nginx 马上重载。面板要重启才换上新证书,而 x-ui 重启会连 Xray 一起重启(在线用户断几秒),
  # 所以放到下一个凌晨 4 点(本机时区);排不上定时就马上重启
  install -d -m 755 "$(dirname "$RENEW_HOOK")"
  cat >"$RENEW_HOOK" <<'EOF'
#!/bin/sh
# 由 xui-node 生成:证书续期后执行
systemctl reload nginx || true
systemctl is-active -q xui-node-panel-cert.timer && exit 0
now=$(date +%s)
at=$(date -d '04:00' +%s)
[ "$at" -gt "$now" ] || at=$(date -d 'tomorrow 04:00' +%s)
systemd-run --quiet --unit=xui-node-panel-cert --on-active=$((at - now)) "$(command -v systemctl)" kill -s HUP --kill-who=main x-ui ||
  systemctl kill -s HUP --kill-who=main x-ui || true
EOF
  chmod 755 "$RENEW_HOOK"
  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
  write_nginx
  curl -fsS --max-time 10 --resolve "$DOMAIN:${SITE_PORT}:127.0.0.1" "https://$DOMAIN:${SITE_PORT}/" -o /dev/null ||
    die "Nginx 127.0.0.1:${SITE_PORT} 没起来"
  ok "证书已签好,站点在 127.0.0.1:${SITE_PORT}(自动续期)"
}

setup_xui() {
  local tmp_port xu xp token settings sub_port who fresh=0
  step "安装 3x-ui"
  work_dir
  # 沿用别人装的 3x-ui:没在运行就先启动,并记下来(以后重新执行不再问)
  if [[ $EXISTING_XUI == keep ]]; then
    systemctl is-active -q x-ui || systemctl start x-ui >/dev/null 2>&1 || true
    systemctl is-active -q x-ui || die "旧 3x-ui 没在运行,也启动不了(看原因:systemctl status x-ui);可以重新执行选「重装」"
    result_set XUI_BY existing
  fi
  if [[ $EXISTING_XUI != reinstall && -x $XUI_BIN ]] && systemctl is-active -q x-ui; then
    info "已安装,跳过($($XUI_BIN -v 2>/dev/null | head -1))"
  else
    if [[ $XUI_VERSION == latest ]]; then
      XUI_VERSION=$(curl -fsSL --max-time 20 https://api.github.com/repos/MHSanaei/3x-ui/releases/latest | jq -r .tag_name)
      [[ $XUI_VERSION =~ ^v[0-9] ]] || die "取不到 3x-ui 最新版本号"
    fi
    info "版本 $XUI_VERSION"
    curl -fsSL --max-time 60 "https://raw.githubusercontent.com/MHSanaei/3x-ui/${XUI_VERSION}/install.sh" -o "$WORK/install.sh" ||
      die "下载 3x-ui 安装器失败(${XUI_VERSION})"
    # 重装:安装器下载好了再卸载旧的(下载失败时旧 3x-ui 原样不动)
    if [[ $EXISTING_XUI == reinstall ]]; then xui_backup_remove; fi
    # 先用临时端口装:3x-ui 自带的订阅服务默认占着 2096,把它挪开之后再把面板换到 $PANEL_PORT
    tmp_port=$(random_free_port) || die "挑不到空闲端口"
    # 安装器会把面板账号、密码、token 打印出来:滤掉这些行,只留进度。
    # 用管道而不是 > >(...):管道会等过滤完的输出全部打印完再往下走;安装器的退出码记在文件里
    rm -f "$WORK/xui-install.rc"
    result_set XUI_BY xui-node
    {
      XUI_NONINTERACTIVE=1 XUI_PANEL_PORT="$tmp_port" XUI_SSL_MODE=none XUI_DB_TYPE=sqlite XUI_ENABLE_FAIL2BAN=false \
        XUI_SERVER_IP="$PUBLIC_IP" bash "$WORK/install.sh" "$XUI_VERSION" </dev/null 2>&1 ||
        echo "$?" >"$WORK/xui-install.rc"
    } | grep --line-buffered -Eiv 'password|username|token|webbasepath|access url|dsn|credential|secret' |
      sed -u 's/^/    | /' || true
    [[ ! -s $WORK/xui-install.rc ]] ||
      die "3x-ui 安装器失败(退出码 $(cat "$WORK/xui-install.rc");上面是它的输出,账号密码那几行已滤掉)"
    [[ -x $XUI_BIN ]] || die "3x-ui 没装上"
    fresh=1
  fi

  # 面板登录信息:安装器写在 $XUI_RESULT(保留不删),抄一份进结果文件。
  # 只在刚装完、或结果文件里还没有时抄:以后在面板里改了密码,重新执行不会用旧值盖掉
  if [[ -f $XUI_RESULT ]] && [[ $fresh == 1 || -z $(result_get PANEL_PASSWORD) ]]; then
    # shellcheck disable=SC1090
    xu=$(set +u; . "$XUI_RESULT"; printf '%s' "${XUI_USERNAME:-}")
    # shellcheck disable=SC1090
    xp=$(set +u; . "$XUI_RESULT"; printf '%s' "${XUI_PASSWORD:-}")
    [[ -z $xu ]] || result_set PANEL_USERNAME "$xu"
    [[ -z $xp ]] || result_set PANEL_PASSWORD "$xp"
    unset xu xp
  fi
  WBP=$($XUI_BIN setting -show 2>/dev/null | sed -n 's/^webBasePath: *//p' | tr -d '/[:space:]')
  [[ -n $WBP ]] || die "读不到面板的 webBasePath"
  result_set WEB_BASE_PATH "$WBP"
  # 不带结尾的 /,管理程序直接拼 /panel/api/...;浏览器打开时加上 /
  result_set PANEL_URL "https://${DOMAIN}:${PANEL_PORT}/${WBP}"
  result_set PANEL_URL_IP "https://${PUBLIC_IP}:${PANEL_PORT}/${WBP}"
  # 面板现在实际在用的端口(刚装好时是临时端口)
  API_HOST=$DOMAIN
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

  # 安装器自己生成的 install token 保留($XUI_RESULT 里记的就是它)

  # 订阅备注模板 {{INBOUND}};关掉 3x-ui 自带的订阅服务,并把它的端口挪开
  # (它默认占 2096;面板不允许订阅端口和面板端口相同,关着也不行,否则以后在面板里保存设置会失败)
  settings=$(api POST /setting/all)
  sub_port=$(jq -r '.subPort // 0' <<<"$settings")
  if [[ $sub_port == "$PANEL_PORT" || $sub_port == "$REALITY_PORT" || $sub_port == "$SOCKS_PORT" ]] || ! is_port "$sub_port"; then
    sub_port=$(random_free_port) || die "挑不到空闲端口"
  fi
  if [[ $(jq -r '"\(.remarkTemplate // "")|\(.subEnable)|\(.subPort)"' <<<"$settings") != "{{INBOUND}}|false|$sub_port" ]]; then
    api POST /setting/update "$(jq -c --argjson sp "$sub_port" '.remarkTemplate = "{{INBOUND}}" | .subEnable = false | .subPort = $sp' <<<"$settings")" >/dev/null ||
      die "改面板设置失败"
  fi
  [[ $(api POST /setting/all | jq -r '"\(.remarkTemplate)|\(.subEnable)|\(.subPort)"') == "{{INBOUND}}|false|$sub_port" ]] || die "面板设置没改成"
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

  # 安装器的结果文件保留,但里面的端口和地址(临时端口、http、IP)变了:改成现在的值,照着它也能连上。
  # token 不动(install token 没删,照样能用)
  if [[ -f $XUI_RESULT ]]; then
    env_set "$XUI_RESULT" XUI_PANEL_PORT "$PANEL_PORT"
    env_set "$XUI_RESULT" XUI_ACCESS_URL "https://${DOMAIN}:${PANEL_PORT}/${WBP}"
  fi
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
  sd_enable --now "$PIN_UNIT.timer"
  ok "Xray $WANT,版本锁定已开(每 10 分钟检查)"
}

setup_inbound() {
  if [[ $PROTOCOL == hy2 ]]; then setup_hy2; else setup_reality; fi
}
# Hysteria2:TLS 用本机域名的证书(和 Nginx、面板同一张;不是一次性加载时 Xray 每小时重新读一次证书文件,
# 续期后不用重启。ocspStapling 留 0:Let's Encrypt 已经不提供 OCSP,填了只会每小时报一次警告),
# salamander 混淆密码随机生成。入站里先不放用户
setup_hy2() {
  local inbounds stream body
  step "Hysteria2 入站(UDP $HY2_PORT,SNI $DOMAIN,salamander 混淆)"
  inbounds=$(api GET /inbounds/list) || die "读不到面板上的入站"
  check_main_inbound "$inbounds"
  if [[ $HY2_EXISTS == 1 ]]; then
    info "已有,跳过"
    return 0
  fi
  # 混淆密码只经过标准输入,不出现在命令行里
  stream=$(rand_hex 16 | jq -Rc --arg d "$DOMAIN" --arg c "$CERT_DIR/fullchain.pem" --arg k "$CERT_DIR/privkey.pem" '{
    network: "hysteria", security: "tls", externalProxy: [],
    tlsSettings: {
      serverName: $d, minVersion: "1.2", maxVersion: "1.3", cipherSuites: "", rejectUnknownSni: false,
      disableSystemRoot: false, enableSessionResumption: false,
      certificates: [{ certificateFile: $c, keyFile: $k, ocspStapling: 0, oneTimeLoading: false, usage: "encipherment", buildChain: false }],
      alpn: ["h3"], echServerKeys: "",
      settings: { fingerprint: "", echConfigList: "", pinnedPeerCertSha256: [], verifyPeerCertByName: "" }
    },
    hysteriaSettings: { version: 2, auth: "", udpIdleTimeout: 60 },
    finalmask: { udp: [{ type: "salamander", settings: { password: . } }] }
  }')
  body=$(jq -c --arg remark "$REMARK" --argjson port "$HY2_PORT" '{
    up: 0, down: 0, total: 0, remark: $remark, enable: true, expiryTime: 0, listen: "", port: $port, protocol: "hysteria",
    settings: ({ version: 2, clients: [] } | tojson),
    streamSettings: tojson,
    sniffing: ({ enabled: false, destOverride: ["http", "tls", "quic", "fakedns"], metadataOnly: false, routeOnly: false } | tojson)
  }' <<<"$stream")
  api POST /inbounds/add "$body" >/dev/null || die "新建入站失败"
  unset stream body
  ok "已新建(备注 $REMARK,还没有用户)"
}
setup_reality() {
  local keys stream body
  step "VLESS + Reality 入站(端口 $REALITY_PORT,伪装目标 127.0.0.1:$SITE_PORT,SNI $DOMAIN)"
  check_main_inbound "$(api GET /inbounds/list)"
  if [[ $REALITY_EXISTS == 1 ]]; then
    info "已有,跳过"
    return 0
  fi
  # 私钥只经过标准输入,不出现在命令行里
  keys=$(api GET /server/getNewX25519Cert)
  stream=$(printf '%s\n' "$keys" "$(jq -nc --arg a "$(rand_hex 1)" --arg b "$(rand_hex 2)" --arg c "$(rand_hex 3)" --arg d "$(rand_hex 4)" \
    --arg e "$(rand_hex 5)" --arg f "$(rand_hex 6)" --arg g "$(rand_hex 7)" --arg h "$(rand_hex 8)" '[$a,$b,$c,$d,$e,$f,$g,$h]')" |
    jq -cs --arg d "$DOMAIN" --arg t "127.0.0.1:$SITE_PORT" '.[0] as $k | .[1] as $s | {
      network: "tcp", security: "reality", externalProxy: [],
      tcpSettings: { acceptProxyProtocol: false, header: { type: "none" } },
      realitySettings: {
        show: false, xver: 0, target: $t, serverNames: [$d],
        privateKey: $k.privateKey, minClientVer: "", maxClientVer: "", maxTimediff: 0, shortIds: $s, mldsa65Seed: "",
        settings: { publicKey: $k.publicKey, fingerprint: "chrome", serverName: "", spiderX: "/", mldsa65Verify: "" }
      }
    }')
  body=$(jq -c --arg remark "$REMARK" --argjson port "$REALITY_PORT" '{
    up: 0, down: 0, total: 0, remark: $remark, enable: true, expiryTime: 0, listen: "", port: $port, protocol: "vless",
    settings: ({ clients: [], decryption: "none", encryption: "none", fallbacks: [] } | tojson),
    streamSettings: tojson,
    sniffing: ({ enabled: false, destOverride: ["http", "tls", "quic", "fakedns"], metadataOnly: false, routeOnly: false } | tojson)
  }' <<<"$stream")
  api POST /inbounds/add "$body" >/dev/null || die "新建入站失败"
  unset keys stream body
  ok "已新建(备注 $REMARK,还没有用户)"
}

# ---------------- SOCKS5 入站 ----------------
# 确保 SOCKS_PORT 上有一个带账号密码的 SOCKS5(mixed)入站,地址写进结果文件的 SOCKS_URL。
# 已有就沿用,账号密码不变(只把 UDP 设置补对、停用的启用);rotate=1 时换密码。
# 账号密码只经过环境变量(只有 root 能看)和标准输入,不出现在命令行里,也不打印。
SOCKS_ROTATED=0
socks_ensure() {
  local rotate=$1 list ib proto id settings listen w body user pass fixes=()
  list=$(api GET /inbounds/list) || die "读不到面板上的入站"
  ib=$(socks_inbound_on "$list")
  unset list
  if [[ -z $ib ]]; then
    w=$(port_owner "$SOCKS_PORT")
    [[ -z $w || $w =~ \"(xray-linux[^\"]*|x-ui)\" ]] || die "端口 $SOCKS_PORT 被别的程序占用:${w%%$'\n'*}"
    user=$(rand_hex 4)
    pass=$(rand_hex 16)
    # ip 填 0.0.0.0:Xray 在所有地址上开临时 UDP 端口,UDP ASSOCIATE 的回复里地址是 0.0.0.0,
    # 客户端按惯例改用它连过来的地址发 UDP(Xray 的 SOCKS 出站就是这样),NAT 后的机器也能用。
    # 填公网 IP 在 NAT 后的机器上会绑不上;填 127.0.0.1 外面的客户端发不过来
    body=$(S_USER=$user S_PASS=$pass jq -nc --arg remark "$SOCKS_REMARK" --argjson port "$SOCKS_PORT" '{
      up: 0, down: 0, total: 0, remark: $remark, enable: true, expiryTime: 0, listen: "", port: $port, protocol: "mixed",
      settings: ({ auth: "password", accounts: [{ user: env.S_USER, pass: env.S_PASS }], udp: true, ip: "0.0.0.0" } | tojson),
      streamSettings: ({ network: "tcp", security: "none", tcpSettings: { acceptProxyProtocol: false, header: { type: "none" } } } | tojson),
      sniffing: ({ enabled: false, destOverride: ["http", "tls", "quic", "fakedns"], metadataOnly: false, routeOnly: false } | tojson)
    }')
    api POST /inbounds/add "$body" >/dev/null || die "新建 SOCKS5 入站失败"
    ok "已新建 SOCKS5 入站(端口 $SOCKS_PORT,备注 $SOCKS_REMARK,账号密码随机生成)"
  else
    proto=$(jq -r '.protocol // ""' <<<"$ib")
    [[ $proto == mixed || $proto == socks ]] ||
      die "面板上 $SOCKS_PORT 端口已经有入站 $(jq -r '.remark // ""' <<<"$ib")($proto),不是 SOCKS。换个 SOCKS 端口(xui-node install --socks-port N),或者先在面板里删掉它"
    id=$(jq -r '.id' <<<"$ib")
    settings=$(jq -c '.settings | if type == "string" then (fromjson? // {}) elif type == "object" then . else {} end' <<<"$ib")
    user=$(jq -r '.accounts[0].user // ""' <<<"$settings")
    pass=$(jq -r '.accounts[0].pass // ""' <<<"$settings")
    if [[ $(jq -r '.auth // ""' <<<"$settings") != password || -z $user || -z $pass ]]; then
      [[ $rotate == 1 ]] ||
        die "面板上 $SOCKS_PORT 端口的 SOCKS 入站没设账号密码(谁都能用)。执行 xui-node socks --rotate 给它设上(原来不用密码连它的程序要跟着改),或者先在面板里删掉它"
      [[ -n $user ]] || user=$(rand_hex 4)
      fixes+=("原来没设账号密码,已设上")
    elif [[ $rotate == 1 ]]; then
      fixes+=("换了密码")
    fi
    if [[ $rotate == 1 ]]; then
      pass=$(rand_hex 16)
      SOCKS_ROTATED=1
    fi
    if [[ $(jq -r '"\(.udp)|\(.ip // "")"' <<<"$settings") != "true|0.0.0.0" ]]; then fixes+=("UDP 设置改成 udp 开、ip 0.0.0.0"); fi
    if ((${#fixes[@]})); then
      # update 接口不改启用状态(用 setEnable),也不碰 settings.clients;tag 原样带上,面板自己决定要不要重新生成
      body=$(S_USER=$user S_PASS=$pass S_ROTATE=$rotate jq -c '{ remark, listen, port, protocol, expiryTime, total, tag, streamSettings, sniffing }
        + { settings: ((.settings | if type == "string" then (fromjson? // {}) elif type == "object" then . else {} end)
          | .udp = true | .ip = "0.0.0.0"
          | if env.S_ROTATE == "1" then .auth = "password" | .accounts = ([{ user: env.S_USER, pass: env.S_PASS }] + ((.accounts // [])[1:])) else . end
          | tojson) }' <<<"$ib")
      api POST "/inbounds/update/$id" "$body" >/dev/null || die "修改 SOCKS5 入站失败"
    fi
    if [[ $(jq -r '.enable' <<<"$ib") != true ]]; then
      api POST "/inbounds/setEnable/$id" '{"enable":true}' >/dev/null || die "启用 SOCKS5 入站失败"
      fixes+=("原来是停用的,已启用")
    fi
    listen=$(jq -r '.listen // ""' <<<"$ib")
    if [[ -n $listen && $listen != 0.0.0.0 && $listen != :: ]]; then
      warn "这个入站只监听 $listen,别的机器连不上;要对外用就在面板里把它的监听地址清空"
    fi
    if ((${#fixes[@]})); then
      ok "沿用 $SOCKS_PORT 端口已有的 SOCKS 入站:$(printf '%s;' "${fixes[@]}" | sed 's/;$//')"
    else
      ok "沿用 $SOCKS_PORT 端口已有的 SOCKS 入站,账号密码不变"
    fi
  fi
  result_set SOCKS_URL "$(S_USER=$user S_PASS=$pass jq -rn --arg h "$DOMAIN" --arg p "$SOCKS_PORT" '"socks5://\(env.S_USER | @uri):\(env.S_PASS | @uri)@\($h):\($p)"')"
  unset ib settings body user pass
}

# 本机经 SOCKS5 访问一次外网(账号密码经标准输入交给 curl,不出现在命令行里)
socks_selftest() {
  local url
  url=$(result_get SOCKS_URL)
  url=${url%@*}@127.0.0.1:$SOCKS_PORT
  printf 'proxy = "%s"\n' "${url/#socks5:/socks5h:}" |
    curl -K - -fsS --max-time 15 -o /dev/null https://1.1.1.1/cdn-cgi/trace 2>/dev/null
}
# 等 SOCKS5 入站生效(面板一般直接热加载,不行会自己排一次重启)并自查;一直不通就重启一次 Xray 再试
socks_verify() {
  local round
  for round in 1 2; do
    for _ in $(seq 1 15); do
      if [[ -n $(port_owner "$SOCKS_PORT") ]] && socks_selftest; then
        ok "SOCKS5 自查通过:本机用这个账号密码经 $SOCKS_PORT 端口访问外网正常"
        return 0
      fi
      sleep 2
    done
    [[ $round == 1 ]] || break
    info "还没生效,重启一次 Xray 再试"
    api POST /server/restartXrayService >/dev/null 2>&1 || true
  done
  if [[ -z $(port_owner "$SOCKS_PORT") ]]; then
    warn "$SOCKS_PORT 端口没在监听,看看面板里这个入站和 Xray 日志"
  else
    warn "本机经 SOCKS5 访问外网没通过(端口在监听),看看面板里这个入站和 Xray 日志"
  fi
  return 1
}

# 安装时:要建就建(或沿用)。没要建,但端口上已经有带账号密码的 SOCKS 入站,也照样沿用(脚本不删入站)
setup_socks() {
  local list ib old
  old=$(result_get SOCKS_URL)
  if [[ $SOCKS_PORT == 0 ]]; then
    if [[ -n $old ]]; then
      warn "原来的 SOCKS5 入站还在面板里(${old##*:} 端口),SOCKS 端口设成 0 后防火墙不再放行它;不用了就在面板里删掉"
      result_set SOCKS_URL ""
    fi
    return 0
  fi
  list=$(api GET /inbounds/list) || die "读不到面板上的入站"
  ib=$(socks_inbound_on "$list")
  unset list
  if [[ $SOCKS_INBOUND != 1 ]]; then
    if [[ -z $ib ]] || ! jq -e '(.protocol == "mixed" or .protocol == "socks")
      and ((.settings | if type == "string" then (fromjson? // {}) elif type == "object" then . else {} end)
        | .auth == "password" and ((.accounts // [])[0].pass // "") != "")' >/dev/null <<<"$ib"; then
      [[ -z $old ]] || result_set SOCKS_URL ""
      return 0
    fi
    SOCKS_INBOUND=1
  fi
  step "SOCKS5 入站(端口 $SOCKS_PORT)"
  if [[ -n $old && ${old##*:} != "$SOCKS_PORT" ]]; then
    warn "原来的 SOCKS5 入站在 ${old##*:} 端口,还在面板里,防火墙不再放行它;不用了就在面板里删掉"
  fi
  unset ib
  socks_ensure 0
  info "地址(socks5://用户:密码@${DOMAIN}:${SOCKS_PORT})写在 $RESULT 的 SOCKS_URL,用 xui-node info 查看"
  socks_hint_sg
}
socks_hint_sg() {
  hint "服务商如果有安全组 / 云防火墙,要放行 TCP $SOCKS_PORT 和 UDP $(fw_open_udp | sed 's/ /, /g')(UDP 走系统临时端口)。"
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
  if [[ $PROTOCOL == hy2 ]]; then
    for _ in $(seq 1 10); do
      [[ ! $(port_owner_udp "$HY2_PORT") =~ \"xray ]] || break
      sleep 1
    done
    [[ $(port_owner_udp "$HY2_PORT") =~ \"xray ]] || die "Xray 没在 UDP $HY2_PORT 端口监听(Hysteria2 入站没起来?看面板日志)"
    ok "Xray ${st%%|*} 在运行;Hysteria2 在 UDP $HY2_PORT 端口监听"
    if [[ $SOCKS_INBOUND == 1 ]]; then socks_verify || true; fi
    return 0
  fi
  for _ in $(seq 1 10); do
    [[ -z $(port_owner "$REALITY_PORT") ]] || break
    sleep 1
  done
  [[ -n $(port_owner "$REALITY_PORT") ]] || die "端口 $REALITY_PORT 没在监听"
  # 不带 Reality 认证去连,应该被转给 Nginx,看到真站点和真证书
  page=$(curl -fsS --max-time 10 --resolve "$DOMAIN:${REALITY_PORT}:127.0.0.1" "https://$DOMAIN:${REALITY_PORT}/" 2>/dev/null || true)
  [[ $page == *'<title>'* ]] || die "从 $REALITY_PORT 端口访问 https://$DOMAIN 没看到站点(Reality 伪装目标不通?)"
  ok "Xray ${st%%|*} 在运行;$REALITY_PORT 端口没认证的访问看到的是 $DOMAIN 的站点"
  if [[ $SOCKS_INBOUND == 1 ]]; then socks_verify || true; fi
}

# ---------------- 防火墙 ----------------
fw_write_conf() { # fw_write_conf SSH端口 本脚本管的端口 额外端口 本脚本管的UDP端口
  cat >"$FW_CONF" <<EOF
# xui-node 防火墙配置,改完执行 xui-node fw apply
# SSH_PORTS:SSH 端口(每次 apply 都会把自动识别到的并进来,不会少)
# OPEN_PORTS:本脚本管的 TCP 端口(重新安装时按设置重写)
# OPEN_UDP:本脚本管的 UDP 端口(建了 SOCKS5 入站才有:SOCKS 端口 + 系统临时端口段)
# EXTRA_PORTS:你自己要额外放行的 TCP 端口(重新安装时保留)
SSH_PORTS=$(printf '%q' "$1")
OPEN_PORTS=$(printf '%q' "$2")
OPEN_UDP=$(printf '%q' "${4:-}")
EXTRA_PORTS=$(printf '%q' "$3")
EOF
  chmod 600 "$FW_CONF"
}

fw_render() { # fw_render 放行的TCP端口 [放行的UDP端口(可以是 起-止)]
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
    tcp dport { $(words "$1" | sed 's/ /, /g') } accept
EOF
  [[ -z ${2:-} ]] || printf '    udp dport { %s } accept\n' "$(sed 's/ /, /g' <<<"$2")"
  printf '  }\n}\n'
}

fw_revert() {
  nft delete table inet "$FW_TABLE" 2>/dev/null || true
  systemctl disable "$FW_UNIT" >/dev/null 2>&1 || true
  result_set FIREWALL 0
}

# 按配置生成规则并生效。confirm=1:生效后请人新开 SSH 确认,超时自动撤销(人不在了也由定时器撤销)
fw_apply() {
  local confirm=${1:-0} ssh open extra udp tmp ports
  [[ -f $FW_CONF ]] || die "没有 $FW_CONF(防火墙没启用,用 xui-node install 开)"
  ssh=$(words "$(fw_conf_get SSH_PORTS) $(detect_ssh_ports)")
  open=$(fw_conf_get OPEN_PORTS)
  extra=$(fw_conf_get EXTRA_PORTS)
  udp=$(fw_conf_get OPEN_UDP | xargs)
  [[ -n $ssh ]] || die "识别不到 SSH 端口,$FW_CONF 里也没有:不应用(免得把自己关在外面)"
  fw_write_conf "$ssh" "$open" "$extra" "$udp"
  ports=$(words "$ssh $open $extra")
  tmp=$(mktemp "$STATE_DIR/.fw.XXXXXX")
  fw_render "$ports" "$udp" >"$tmp"
  nft -c -f "$tmp" || { rm -f "$tmp"; die "规则检查没通过"; }
  # 开机自动加载(没确认被撤销时会再关掉)
  systemctl daemon-reload
  sd_enable "$FW_UNIT"
  if nft list table inet "$FW_TABLE" >/dev/null 2>&1 && cmp -s "$tmp" "$FW_RULES"; then
    rm -f "$tmp"
    ok "防火墙规则没变:放行 $(fw_desc "$ports" "$udp")"
    return 0
  fi
  mv "$tmp" "$FW_RULES"
  chmod 600 "$FW_RULES"
  if [[ $confirm == 1 ]]; then
    systemctl stop "$FW_REVERT.timer" >/dev/null 2>&1 || true
    systemd-run --quiet --unit="$FW_REVERT" --on-active="$((FW_CONFIRM_SECONDS + 30))" /bin/sh -c \
      "nft delete table inet $FW_TABLE; systemctl disable $FW_UNIT" >/dev/null 2>&1 ||
      warn "排不上自动撤销的定时器,确认时请别断开当前连接"
  fi
  nft -f "$FW_RULES"
  ok "防火墙已生效:放行 $(fw_desc "$ports" "$udp")(SSH:$(sed 's/ /, /g' <<<"$ssh"))"
  [[ $confirm == 1 ]] || return 0
  printf '\n'
  info "现在新开一个终端,用 SSH 登录这台机器试试(当前这个连接不受影响)。"
  if read -r -t "$FW_CONFIRM_SECONDS" -p "    能登录就回车确认(${FW_CONFIRM_SECONDS} 秒内不确认会自动撤销防火墙): " _; then
    systemctl stop "$FW_REVERT.timer" >/dev/null 2>&1 || true
    result_set FIREWALL 1
    ok "已确认"
  else
    printf '\n'
    systemctl stop "$FW_REVERT.timer" >/dev/null 2>&1 || true
    fw_revert
    warn "没有确认,防火墙已撤销。确认 SSH 端口后(编辑 $FW_CONF)执行 xui-node fw apply 再开"
  fi
}

setup_firewall() {
  local extra
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
  extra=$(fw_conf_get EXTRA_PORTS)
  fw_write_conf "$SSH_PORTS" "$(fw_open_ports)" "$extra" "$(fw_open_udp)"
  # 不用默认依赖:跟 Debian 自带的 nftables.service 一样,免得开机时和 cloud-init / 网络服务排成环
  cat >"/etc/systemd/system/$FW_UNIT" <<EOF
[Unit]
Description=xui-node firewall (nftables table inet ${FW_TABLE})
DefaultDependencies=no
Wants=network-pre.target
Before=network-pre.target shutdown.target
After=local-fs.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f ${FW_RULES}
ExecStop=/usr/sbin/nft delete table inet ${FW_TABLE}

[Install]
WantedBy=sysinit.target
EOF
  # 旧版本装在 multi-user.target 下,先撤掉再按新的装
  systemctl disable "$FW_UNIT" >/dev/null 2>&1 || true
  fw_apply "$INTERACTIVE"
  hint "开机自动加载;查看:xui-node fw。服务商如果还有安全组 / 云防火墙,也要放行这些端口。"
}

# ---------------- 安装 ----------------
INTERACTIVE=0
cmd_install() {
  local yes=0 prev_ssh
  DOMAIN="" PANEL_PORT="" REALITY_PORT="" SOCKS_PORT="" SOCKS_INBOUND="" XRAY_VERSION="" XUI_VERSION=latest
  PROTOCOL="" HY2_PORT=""
  SSH_PORTS="" FIREWALL="" REMARK="" PUBLIC_IP="" ACME_EMAIL="" SKIP_DNS_CHECK=0 CERT_DIR="" EXISTING_XUI=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) need_arg "$@"; DOMAIN=$2; shift 2 ;;
      --panel-port) need_arg "$@"; PANEL_PORT=$2; shift 2 ;;
      --reality-port) need_arg "$@"; REALITY_PORT=$2; shift 2 ;;
      --protocol) need_arg "$@"; PROTOCOL=${2,,}; shift 2 ;;
      --hy2-port) need_arg "$@"; HY2_PORT=$2; shift 2 ;;
      --socks-port) need_arg "$@"; SOCKS_PORT=$2; shift 2 ;;
      --socks-inbound) SOCKS_INBOUND=1; shift ;;
      --xray-version) need_arg "$@"; XRAY_VERSION=$2; shift 2 ;;
      --xui-version) need_arg "$@"; XUI_VERSION=$2; shift 2 ;;
      --ssh-port) need_arg "$@"; SSH_PORTS=$2; shift 2 ;;
      --no-firewall) FIREWALL=0; shift ;;
      --remark) need_arg "$@"; REMARK=$2; shift 2 ;;
      --ip) need_arg "$@"; PUBLIC_IP=$2; shift 2 ;;
      --acme-email) need_arg "$@"; ACME_EMAIL=$2; shift 2 ;;
      --skip-dns-check) SKIP_DNS_CHECK=1; shift ;;
      --reinstall-xui) EXISTING_XUI=reinstall; shift ;;
      --keep-xui) EXISTING_XUI=keep; shift ;;
      -y | --yes) yes=1; shift ;;
      -h | --help) usage_install; return 0 ;;
      *) die "未知参数: $1(xui-node install --help 看参数)" ;;
    esac
  done
  trap 'die "第 $LINENO 行出错(命令: $BASH_COMMAND)"' ERR
  need_root
  if [[ -t 0 && $yes -eq 0 ]]; then INTERACTIVE=1; fi
  preflight
  ensure_bin
  detect_ip

  # 默认值:选项 > 上次安装 > 内置默认
  [[ -n $DOMAIN ]] || DOMAIN=$(result_get DOMAIN)
  [[ -n $PANEL_PORT ]] || PANEL_PORT=$(result_get PANEL_PORT)
  [[ -n $REALITY_PORT ]] || REALITY_PORT=$(result_get REALITY_PORT)
  [[ -n $PROTOCOL ]] || PROTOCOL=$(result_get PROTOCOL)
  [[ -n $HY2_PORT ]] || HY2_PORT=$(result_get HY2_PORT)
  [[ -n $SOCKS_PORT ]] || SOCKS_PORT=$(result_get SOCKS_PORT)
  [[ -n $XRAY_VERSION ]] || XRAY_VERSION=$(result_get XRAY_VERSION)
  [[ -n $FIREWALL ]] || FIREWALL=$(result_get FIREWALL)
  PANEL_PORT=${PANEL_PORT:-$DEFAULT_PANEL_PORT}
  REALITY_PORT=${REALITY_PORT:-$DEFAULT_REALITY_PORT}
  PROTOCOL=${PROTOCOL:-$DEFAULT_PROTOCOL}
  [[ $PROTOCOL != hysteria2 ]] || PROTOCOL=hy2
  HY2_PORT=${HY2_PORT:-$DEFAULT_HY2_PORT}
  SOCKS_PORT=${SOCKS_PORT:-$DEFAULT_SOCKS_PORT}
  # 上次建过 SOCKS5 入站,这次默认也要
  if [[ -z $SOCKS_INBOUND ]]; then
    if [[ -n $(result_get SOCKS_URL) ]]; then SOCKS_INBOUND=1; else SOCKS_INBOUND=0; fi
  fi
  XRAY_VERSION=${XRAY_VERSION:-$DEFAULT_XRAY}
  FIREWALL=${FIREWALL:-1}
  # SSH 端口:没指定就把上次的、防火墙配置里的、自动识别的都并起来(只会多,不会把人关在外面)
  if [[ -z $SSH_PORTS ]]; then
    prev_ssh="$(result_get SSH_PORTS) $(fw_conf_get SSH_PORTS)"
    SSH_PORTS=$(words "$prev_ssh $(detect_ssh_ports)")
    if [[ -z $SSH_PORTS ]]; then
      SSH_PORTS=22
      warn "识别不出 SSH 端口,按 22;不对的话用 --ssh-port 指定"
    fi
  fi

  choose_existing_xui
  if [[ $INTERACTIVE -eq 1 ]]; then wizard; fi
  validate_inputs
  show_plan
  if [[ $INTERACTIVE -eq 1 ]]; then
    printf '\n'
    ask_yn "开始安装" y || { info "已取消"; exit 0; }
  fi
  REMARK=${REMARK:-${DOMAIN%%.*}}

  setup_deps
  recheck_ports
  precheck_existing
  setup_bbr
  result_set XUI_NODE_VERSION "$XUI_NODE_VERSION"
  result_set DOMAIN "$DOMAIN"
  result_set PUBLIC_IP "$PUBLIC_IP"
  result_set PANEL_PORT "$PANEL_PORT"
  result_set PROTOCOL "$PROTOCOL"
  result_set REALITY_PORT "$REALITY_PORT"
  result_set HY2_PORT "$HY2_PORT"
  result_set SOCKS_PORT "$SOCKS_PORT"
  result_set XRAY_VERSION "$XRAY_VERSION"
  result_set FIREWALL "$FIREWALL"
  result_set SSH_PORTS "$SSH_PORTS"

  setup_site
  setup_xui
  setup_xray
  setup_inbound
  setup_socks
  final_check
  # 防火墙最后上:前面哪步失败都不会动到它;在终端里装时生效后要确认 SSH 还能登录
  setup_firewall

  step "完成"
  FIREWALL=$(result_get FIREWALL)
  show_plan
  printf '\n'
  if [[ $SOCKS_INBOUND == 1 ]]; then
    info "面板地址、登录账号、API token 和 SOCKS5 地址保存在 $RESULT(只有 root 可读,安装过程中没有打印)。"
  else
    info "面板地址、登录账号和 API token 保存在 $RESULT(只有 root 可读,安装过程中没有打印)。"
  fi
  if [[ -f $XUI_RESULT ]]; then
    info "3x-ui 安装器自己的 $XUI_RESULT 也保留了,里面的端口和地址已改成现在的。"
  fi
  if [[ $EXISTING_XUI == reinstall ]]; then
    info "旧 3x-ui 的数据和配置备份在 $(result_get XUI_BACKUP)(只有 root 可读),旧用户可以照着里面的 email / UUID 加回来。"
  fi
  info "查看:xui-node info        管理菜单:xui-node"
  if [[ $PROTOCOL == hy2 ]]; then
    info "下一步:登录面板,在 Hysteria2 入站(UDP $HY2_PORT)里添加用户;或者把面板地址和 token 交给管理程序。"
    hint "服务商如果有安全组 / 云防火墙,要放行 UDP $HY2_PORT。"
  else
    info "下一步:登录面板,在 $REALITY_PORT 端口的入站里添加用户;或者把面板地址和 token 交给管理程序。"
  fi
  if [[ $SOCKS_INBOUND != 1 && $SOCKS_PORT != 0 ]]; then
    hint "要在 $SOCKS_PORT 端口建 SOCKS5 入站(账号密码认证,支持 UDP):xui-node socks"
  fi
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
  if [[ -n ${SOCKS_URL:-} ]]; then
    info "SOCKS5 地址     $SOCKS_URL"
  elif [[ ${SOCKS_PORT:-0} != 0 ]]; then
    info "SOCKS5          没建(预留了 $SOCKS_PORT 端口;要建就执行 xui-node socks)"
  fi
  printf '\n'
  hint "账号密码是安装时生成的;在面板里改过就以面板为准。"
  hint "管理程序登记这台面板:地址用不带结尾 / 的 PANEL_URL,token 用 PANEL_TOKEN(都在 $RESULT)。"
  if [[ -n ${SOCKS_URL:-} ]]; then
    hint "SOCKS5 地址是 socks5://用户:密码@域名:端口 格式(结果文件里的 SOCKS_URL);在面板里改过账号密码的话,执行一次 xui-node socks 会按面板重新写。"
  fi
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
  if [[ ${PROTOCOL:-vless} == hy2 ]]; then
    info "Xray:${st:-读不到}(Hysteria2 UDP 端口 $HY2_PORT$([[ $(port_owner_udp "$HY2_PORT") =~ \"xray ]] || echo ',没在监听'))"
  else
    info "Xray:${st:-读不到}(Reality 端口 $REALITY_PORT$([[ -n $(port_owner "$REALITY_PORT") ]] || echo ',没在监听'))"
  fi
  if [[ ${XRAY_VERSION:-keep} == keep ]]; then pin="不锁定"; else pin="$XRAY_VERSION,定时检查$(unit_state "$PIN_UNIT.timer")"; fi
  info "版本锁定:$pin"
  info "Nginx 站点:$(unit_state nginx)"
  if [[ -n ${SOCKS_URL:-} ]]; then
    info "SOCKS5:端口 $SOCKS_PORT$([[ -n $(port_owner "$SOCKS_PORT") ]] && echo ',在监听' || echo ',没在监听')"
  elif [[ ${SOCKS_PORT:-0} != 0 ]]; then
    info "SOCKS5:没建(预留了 $SOCKS_PORT 端口)"
  fi
  info "拥塞控制:$(bbr_state)"
  if [[ -f /etc/letsencrypt/live/$DOMAIN/cert.pem ]]; then
    end=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$DOMAIN/cert.pem" 2>/dev/null | cut -d= -f2 || true)
  fi
  if [[ -n $end ]]; then info "证书:到期 $end"; else info "证书:没找到"; fi
  if nft list table inet "$FW_TABLE" >/dev/null 2>&1; then
    info "防火墙:开,放行 $(fw_desc "$(words "$(fw_conf_get SSH_PORTS) $(fw_conf_get OPEN_PORTS) $(fw_conf_get EXTRA_PORTS)")" "$(fw_conf_get OPEN_UDP | xargs)")"
  else
    info "防火墙:没开"
  fi
}

cmd_fw() {
  need_root
  case "${1:-show}" in
    show)
      if nft list table inet "$FW_TABLE" 2>/dev/null; then
        hint "加端口:编辑 $FW_CONF 的 EXTRA_PORTS,再执行 xui-node fw apply"
      else
        info "防火墙没开(xui-node install 时可以开)"
      fi
      ;;
    apply)
      install -d -m 700 "$STATE_DIR"
      if [[ -t 0 ]]; then fw_apply 1; else fw_apply 0; fi
      ;;
    *) die "用法: xui-node fw show|apply" ;;
  esac
}

usage_socks() {
  cat <<EOF
用法: xui-node socks [--rotate]

在安装时预留的 SOCKS 端口上建一个 SOCKS5 入站:账号密码认证(随机生成),支持 UDP。
任何支持 SOCKS5 的程序都能用它当代理。可以重复执行:端口上已经有 SOCKS 入站就沿用,账号密码不变。
地址(socks5://用户:密码@域名:端口)写进 $RESULT 的 SOCKS_URL,用 xui-node info 查看,这里不打印。
防火墙开着的话,会同时放行 SOCKS5 的 UDP(SOCKS 端口和系统临时端口段)。

  --rotate     换一个新密码(用户名不变)。换了之后,所有用旧地址连这个 SOCKS5 的地方都要改成新地址。
EOF
}

cmd_socks() {
  local rotate=0 udp verified=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rotate) rotate=1; shift ;;
      -h | --help) usage_socks; return 0 ;;
      *) die "未知参数: $1(xui-node socks --help 看用法)" ;;
    esac
  done
  trap 'die "第 $LINENO 行出错(命令: $BASH_COMMAND)"' ERR
  need_root
  load_result
  [[ -n ${PANEL_TOKEN:-} ]] || die "结果文件里没有面板 token,先执行 xui-node install"
  SOCKS_PORT=$((10#${SOCKS_PORT:-0}))
  [[ $SOCKS_PORT != 0 ]] ||
    die "安装时没给 SOCKS 预留端口(设成了 0)。执行 xui-node install --socks-port ${DEFAULT_SOCKS_PORT} --socks-inbound 重新配置,会顺带建好"
  api_from_result
  api GET /server/status >/dev/null || die "面板接口连不上(本机 $PANEL_PORT 端口),先看 xui-node status"
  step "SOCKS5 入站(端口 $SOCKS_PORT)"
  socks_ensure "$rotate"
  SOCKS_INBOUND=1
  if [[ ${FIREWALL:-0} == 1 && -f $FW_CONF ]]; then
    udp=$(fw_open_udp)
    if [[ $(fw_conf_get OPEN_UDP | xargs) != "$udp" ]]; then
      step "防火墙:放行 SOCKS5 的 UDP"
      env_set "$FW_CONF" OPEN_UDP "$udp"
      fw_apply 0
    fi
  fi
  socks_verify && verified=1
  printf '\n'
  info "地址(socks5://用户:密码@${DOMAIN}:${SOCKS_PORT})写在 $RESULT 的 SOCKS_URL,用 xui-node info 查看。"
  if [[ $SOCKS_ROTATED == 1 ]]; then warn "密码换了:所有用旧地址连这个 SOCKS5 的地方都要改成新地址"; fi
  socks_hint_sg
  [[ $verified == 1 ]] || exit 1
}

cmd_xray_pin() {
  local want cur
  need_root
  [[ -f $RESULT ]] || return 0
  load_result
  if [[ ${XRAY_VERSION:-keep} == keep ]]; then
    [[ ! -t 1 ]] || info "没锁定 Xray 版本(用 3x-ui 自带的);要锁定就重新安装时填版本号"
    return 0
  fi
  [[ -n ${PANEL_TOKEN:-} ]] || return 0
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
  local c self
  need_root
  # 每一项都在单独的进程里跑:出错照常停下(在 || / if 里调函数,bash 会忽略 set -e)
  self=$(self_path)
  while :; do
    printf '\n%sxui-node %s%s  3x-ui 节点(VLESS + Reality / Hysteria2)\n' "$C_B" "$XUI_NODE_VERSION" "$C_0"
    if [[ -f $RESULT ]]; then
      if [[ $(result_get PROTOCOL) == hy2 ]]; then
        hint "$(result_get DOMAIN) · Hysteria2 UDP $(result_get HY2_PORT) · 面板 $(result_get PANEL_PORT)"
      else
        hint "$(result_get DOMAIN) · Reality $(result_get REALITY_PORT) · 面板 $(result_get PANEL_PORT)"
      fi
    else
      hint "还没安装"
    fi
    cat <<'EOF'

  1. 安装 / 重新配置
  2. 面板地址、账号、API token 和 SOCKS5 地址(会显示密码)
  3. 运行状态
  4. 防火墙规则
  5. 建 SOCKS5 入站(已有就沿用)
  6. 立即检查 Xray 版本锁定
  7. 更新 xui-node
  8. 打开 3x-ui 自带菜单(x-ui)
  0. 退出

EOF
    read -rp "请选择 [0-8]: " c || { echo; return 0; }
    case "$(trim "$c")" in
      1) bash "$self" install || true ;;
      2) bash "$self" info || true ;;
      3) bash "$self" status || true ;;
      4) bash "$self" fw show || true ;;
      5) bash "$self" socks || true ;;
      6) bash "$self" xray-pin || true ;;
      7) if bash "$self" update; then exec "$BIN"; fi ;;
      8) if command -v x-ui >/dev/null; then x-ui || true; else warn "还没装 3x-ui"; fi ;;
      0 | q) return 0 ;;
      *) warn "请输入 0-8"; continue ;;
    esac
    read -rp "回车返回菜单..." c || return 0
  done
}

usage() {
  cat <<'EOF'
xui-node:把 Debian / Ubuntu VPS 装成 3x-ui 节点(VLESS + Reality 或 Hysteria2,二选一)

  xui-node                    管理菜单
  xui-node install [选项]      安装 / 重新配置(xui-node install --help 看选项)
  xui-node info               面板地址、登录账号、API token(会显示密码)
  xui-node status             运行状态
  xui-node fw [show|apply]    防火墙规则
  xui-node socks [--rotate]   SOCKS5 入站:建好(或沿用已有的),地址写进结果文件;--rotate 换密码
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
    socks) shift; cmd_socks "$@" ;;
    xray-pin) cmd_xray_pin ;;
    update) cmd_update ;;
    version | -v | --version) echo "xui-node $XUI_NODE_VERSION" ;;
    help | -h | --help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

# 测试时 source 进来只要函数,不执行
if [[ ${XUI_NODE_SOURCED:-0} != 1 ]]; then main "$@"; fi
