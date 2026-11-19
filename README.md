# xui-node

一条命令把一台 Debian / Ubuntu VPS 装成 [3x-ui](https://github.com/MHSanaei/3x-ui) 的 VLESS + Reality 节点。用的是“偷自己”的方式：Reality 的伪装目标是本机 Nginx 上的真站点和真证书，不借用别人的网站。

## 功能

- **3x-ui**：用官方安装器非交互安装最新版。
- **Xray 内核锁定版本**：默认 `v26.6.27`，通过 3x-ui 接口切换。之后每 10 分钟检查一次，被面板或 3x-ui 升级换掉了就自动换回；也可以选择不锁定。
- **本机伪装站点**：Nginx 静态站点，配 Let's Encrypt 证书（自动续期），只监听 `127.0.0.1:8443`。80 端口只用来签证书和跳转。申请证书前会先在本机访问一次验证地址，Nginx 没配好就不去申请，免得在 Let's Encrypt 留下失败记录。
- **一个 Reality 入站**：VLESS + Reality，默认端口 443，所有用户共用。target 是 `127.0.0.1:8443`，SNI 是本机域名，入站里还没有用户。不带 Reality 认证访问这个端口，看到的是本机的真站点和真证书。
- **面板**：端口统一 `2096`，用同一张证书走 HTTPS。3x-ui 自带的订阅服务默认也占 2096，所以会关掉。安装时会生成一个 API token，方便管理程序对接。
- **SOCKS5（可选）**：在预留的端口（默认 `10001`）上建一个 SOCKS5 入站，账号密码随机生成，支持 UDP，任何支持 SOCKS5 的程序都能拿它当代理。可以在安装时选，也可以以后执行 `xui-node socks`。
- **BBR**：自动开启（拥塞控制 bbr，队列 fq），写进 `/etc/sysctl.d`，重启后保持。内核不支持（OpenVZ / LXC 这类容器）就跳过，不影响安装。
- **防火墙**：用 nftables，只放行 SSH、80、443、10001（SOCKS5）、2096，对所有 IP 开放，其余入站连接一律丢弃。建了 SOCKS5 入站时还会放行它的 UDP（见下面 [SOCKS5](#socks5)）。可以不启用。
- **SSH 不是 22 端口也不用管**：会自动识别 SSH 端口（sshd 配置、实际监听的端口、ssh.socket、当前连接）。防火墙在安装的最后一步才生效；在终端里安装时，生效后会请你新开一个 SSH 窗口确认能登录，120 秒内不确认就自动撤销。
- **不打印密码**：面板地址、账号密码、API token 和 SOCKS5 地址只写进 `/etc/xui-node/result.env`（只有 root 可读），安装过程中不会打印出来。3x-ui 安装器自己写的 `/etc/x-ui/install-result.env` 也保留，里面的端口和地址会改成装好后的值；它记的 token（名字叫 install）也保留，和 xui-node 的 token 一样能用。

## 准备

1. 一台全新的 **Debian 11+ 或 Ubuntu 22.04+**（x86_64 / arm64），用 root 登录。
2. 一个**已经解析到这台机器 IP 的域名**（A 记录）。用 Cloudflare 的话要选**灰云（仅 DNS）**。
3. 服务商如果有安全组或云防火墙，先放行 TCP **80、443、2096** 和 SSH 端口；要用 SOCKS5 的话再放行 TCP **10001** 和 UDP **10001、32768–60999**。

## 安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fishermanxzx/xui-node/main/install.sh)
```

安装时会一步一步提问，直接回车就用方括号里的默认值：

1. 域名（会检查是否已经解析到本机）和证书提醒邮箱
2. 面板端口 `[2096]`
3. Reality 端口 `[443]`
4. SOCKS5 端口 `[10001]`（填 0 表示不预留），以及要不要现在就在这个端口建 SOCKS5 入站 `[N]`
5. Xray 内核版本 `[v26.6.27]`，填 keep 表示不锁定
6. 是否启用防火墙 `[Y]`，以及 SSH 端口（已自动识别好）

确认后开始安装，大约需要 2 到 5 分钟。可以重复执行：已经做完的步骤会跳过，上次选的域名、端口、Xray 版本、防火墙和 SSH 端口会作为默认值。已经装好的 Reality 入站不会被改：如果要换域名或 Reality 端口，先在面板里改好这个入站，再重新执行。

如果不想交互，可以直接带参数安装，例如通过 ssh 批量装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fishermanxzx/xui-node/main/install.sh) --domain us1.example.com -y
```

要顺带建好 SOCKS5 入站，再加 `--socks-inbound`。

全部参数见 `xui-node install --help`。

## 装好以后

```bash
xui-node info     # 面板地址、用户名、密码、API token、SOCKS5 地址
```

登录面板后，在 443 端口的入站里添加用户。如果要交给管理程序管理，就把 `PANEL_URL` 和 `PANEL_TOKEN` 给它。

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
