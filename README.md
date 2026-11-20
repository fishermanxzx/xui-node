# xui-node

一条命令把一台 Debian / Ubuntu VPS 装成 [3x-ui](https://github.com/MHSanaei/3x-ui) 节点，协议二选一：

- **VLESS + Reality**（默认，TCP 443）：用的是“偷自己”的方式，Reality 的伪装目标是本机 Nginx 上的真站点和真证书，不借用别人的网站。
- **Hysteria2**（UDP 443）：TLS 用本机域名的真证书，开 salamander 混淆。

## 功能

- **3x-ui**：用官方安装器非交互安装最新版。
- **Xray 内核**：默认用 3x-ui 自带的版本，不锁定，3x-ui 升级时跟着升。也可以锁定某个版本（例如 `--xray-version v26.11.9`）：通过 3x-ui 接口切换，之后每 10 分钟检查一次，被面板或 3x-ui 升级换掉了就自动换回。
- **本机伪装站点**：Nginx 静态站点，配 Let's Encrypt 证书（自动续期），只监听 `127.0.0.1:8443`。80 端口只用来签证书和跳转。申请证书前会先在本机访问一次验证地址，Nginx 没配好就不去申请，免得在 Let's Encrypt 留下失败记录。
- **一个节点入站**，所有用户共用，刚装好时里面还没有用户：
  - VLESS + Reality：默认 TCP 443，target 是 `127.0.0.1:8443`，SNI 是本机域名。不带 Reality 认证访问这个端口，看到的是本机的真站点和真证书。
  - Hysteria2：默认 UDP 443，证书和 SNI 是本机域名，salamander 混淆密码随机生成（分享链接里自带）。见下面 [Hysteria2](#hysteria2)。
- **面板**：端口统一 `2096`，用同一张证书走 HTTPS。3x-ui 自带的订阅服务默认也占 2096，所以会关掉。安装时会生成一个 API token，方便管理程序对接。
- **SOCKS5（可选）**：在预留的端口（默认 `10001`）上建一个 SOCKS5 入站，账号密码随机生成，支持 UDP，任何支持 SOCKS5 的程序都能拿它当代理。可以在安装时选，也可以以后执行 `xui-node socks`。
- **BBR**：自动开启（拥塞控制 bbr，队列 fq），写进 `/etc/sysctl.d`，重启后保持。内核不支持（OpenVZ / LXC 这类容器）就跳过，不影响安装。
- **防火墙**：用 nftables，只放行 SSH、80、节点端口（Reality 是 TCP 443，Hysteria2 是 UDP 443）、10001（SOCKS5）、2096，对所有 IP 开放，其余入站连接一律丢弃。建了 SOCKS5 入站时还会放行它的 UDP（见下面 [SOCKS5](#socks5)）。可以不启用。
- **SSH 不是 22 端口也不用管**：会自动识别 SSH 端口（sshd 配置、实际监听的端口、ssh.socket、当前连接）。防火墙在安装的最后一步才生效；在终端里安装时，生效后会请你新开一个 SSH 窗口确认能登录，120 秒内不确认就自动撤销。
- **不打印密码**：面板地址、账号密码、API token 和 SOCKS5 地址只写进 `/etc/xui-node/result.env`（只有 root 可读），安装过程中不会打印出来。3x-ui 安装器自己写的 `/etc/x-ui/install-result.env` 也保留，里面的端口和地址会改成装好后的值；它记的 token（名字叫 install）也保留，和 xui-node 的 token 一样能用。

## 准备

1. 一台全新的 **Debian 11+ 或 Ubuntu 22.04+**（x86_64 / arm64），用 root 登录。
2. 一个**已经解析到这台机器 IP 的域名**（A 记录）。用 Cloudflare 的话要选**灰云（仅 DNS）**。
3. 服务商如果有安全组或云防火墙，先放行 TCP **80、2096** 和 SSH 端口，再按协议放行 TCP **443**（VLESS + Reality）或 UDP **443**（Hysteria2）；要用 SOCKS5 的话再放行 TCP **10001** 和 UDP **10001、32768–60999**。

## 安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fishermanxzx/xui-node/main/install.sh)
```

安装时会一步一步提问，直接回车就用方括号里的默认值：

1. 域名（会检查是否已经解析到本机）和证书提醒邮箱
2. 面板端口 `[2096]`
3. 协议：1 = VLESS + Reality `[默认]`，2 = Hysteria2；然后是它的端口 `[443]`
4. SOCKS5 端口 `[10001]`（填 0 表示不预留），以及要不要现在就在这个端口建 SOCKS5 入站 `[N]`
5. Xray 内核版本 `[keep]`，keep 表示用 3x-ui 自带的、不锁定；填版本号（如 `v26.11.9`）就锁定
6. 是否启用防火墙 `[Y]`，以及 SSH 端口（已自动识别好）

确认后开始安装，大约需要 2 到 5 分钟。可以重复执行：已经做完的步骤会跳过，上次选的域名、端口、Xray 版本、防火墙和 SSH 端口会作为默认值。已经装好的 Reality 入站不会被改：如果要换域名或 Reality 端口，先在面板里改好这个入站，再重新执行。

如果不想交互，可以直接带参数安装，例如通过 ssh 批量装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fishermanxzx/xui-node/main/install.sh) --domain us1.example.com -y
```

要顺带建好 SOCKS5 入站，再加 `--socks-inbound`；要装成 Hysteria2 节点，再加 `--protocol hy2`。

### 机器上已经装了 3x-ui

如果机器上已经有 3x-ui，但不是 xui-node 装的，安装前会先问你怎么处理：

- **重装**：先把旧数据（入站、用户、面板账号）整个备份到 `/etc/xui-node/backup/`（只有 root 可读），再卸载旧 3x-ui、全新安装，装好后和新机器一样。旧入站上的用户会断开，之后可以照着备份里的数据库把用户加回来。安装器下载失败或备份没成功时，旧 3x-ui 原样不动。
- **保留**：沿用旧 3x-ui 继续装，已有的入站和用户都不动。面板会换到 2096 端口，换上新证书，关掉 3x-ui 自带的订阅服务，再新建 Reality 入站。限制：
  - 旧 3x-ui 要 v3.9.0 以上；
  - Reality 端口和面板端口上不能已经有旧入站；
  - 启用防火墙的话，其它端口上的旧入站会被挡住（安装计划里会列出来）。

不交互安装时用 `--reinstall-xui` 或 `--keep-xui` 指定，两个都没加就直接停下，什么都不改。选过一次以后，再执行安装不会再问。

全部参数见 `xui-node install --help`。

## 装好以后

```bash
xui-node info     # 面板地址、用户名、密码、API token、SOCKS5 地址
```

登录面板后，在节点入站（443 端口那个）里添加用户。如果要交给管理程序管理，就把 `PANEL_URL` 和 `PANEL_TOKEN` 给它。

## 管理

```bash
xui-node                # 管理菜单
xui-node status         # 运行状态：面板、Xray 版本、证书到期时间、防火墙
xui-node fw             # 查看防火墙规则
xui-node fw apply       # 重新生成防火墙规则（会重新识别 SSH 端口；改了 SSH 端口后执行一次）
xui-node socks          # 建 SOCKS5 入站（已有就沿用）；--rotate 换密码
xui-node xray-pin       # 立即检查一次 Xray 版本
xui-node update         # 更新 xui-node 脚本
x-ui                    # 3x-ui 自带的菜单（重置账号密码等）
```

要额外放行别的端口：编辑 `/etc/xui-node/firewall.conf` 里的 `EXTRA_PORTS`（重新安装时会保留），再执行 `xui-node fw apply`。

注意：
- 每次重新执行安装都会重新生成名为 xui-node 的 API token，旧的作废；安装器生成的 install token 不受影响。
- 证书续期（大约每 60 天一次）后，面板要重启才能用上新证书。重启 x-ui 会让 Xray 一起重启，在线用户会断开几秒，所以安排在续期后的下一个凌晨 4 点（按服务器时区）。

## Hysteria2

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fishermanxzx/xui-node/main/install.sh) --domain hk1.example.com --protocol hy2 -y
```

- 入站用 UDP 443（`--hy2-port` 可以换），和 Reality 的 TCP 443 不冲突，但一台只装一种。
- TLS 用本机域名的 Let's Encrypt 证书（和 Nginx、面板同一张），SNI 是本机域名。Xray 每小时重新读一次证书文件，续期后不用重启。
- 开 salamander 混淆，密码每台随机生成，只存在面板里，从面板导出的分享链接（`hysteria2://…&obfs=salamander&obfs-password=…`）里自带。
- 没有 TCP 的 HTTPS，所以 80 端口直接给本机站点，不跳转。
- 已经装成 VLESS + Reality 的机器要换成 Hysteria2（或反过来），先在面板里删掉原来的入站，再用新协议重新执行安装。

## SOCKS5

```bash
xui-node socks            # 在 SOCKS 端口建 SOCKS5 入站，已有就沿用（账号密码不变），可以重复执行
xui-node socks --rotate   # 换一个新密码（用户名不变）
```

- 地址是 `socks5://用户:密码@域名:端口` 格式，写在 `/etc/xui-node/result.env` 的 `SOCKS_URL`，用 `xui-node info` 查看，安装和这个命令都不会打印出来。
- 换密码后，所有用旧地址连这个 SOCKS5 的地方都要改成新地址。
- 端口上已经有 SOCKS 入站（比如自己在面板里建的）就沿用，账号密码不动，只把 UDP 设置补上（停用的会启用）；没设账号密码的不会直接沿用，要加 `--rotate` 给它设上。
- 端口用安装时设的（默认 10001）；当时填了 0 的话，先执行 `xui-node install --socks-port 10001 --socks-inbound`。
- UDP：Xray 处理 SOCKS5 的 UDP 时，每次另开一个系统临时端口（`ip_local_port_range`，一般是 32768–60999）收发，不走 SOCKS 端口本身，所以防火墙会放行这一段 UDP；Xray 只接收完成了账号密码认证的那个 IP 发来的包。入站的 `ip` 设成 `0.0.0.0`：客户端收到这个地址，按惯例会改用它连过来的地址发 UDP（Xray 就是这样），NAT 后面的云主机也能用。
- 建好后会在本机用这个账号密码经 SOCKS5 访问一次外网，确认能用。

## License

MIT
