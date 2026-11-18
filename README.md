# xui-node

一条命令把一台 Debian / Ubuntu VPS 装成 [3x-ui](https://github.com/MHSanaei/3x-ui) 的 VLESS + Reality 节点。用的是“偷自己”的方式：Reality 的伪装目标是本机 Nginx 上的真站点和真证书，不借用别人的网站。

## 功能

- **3x-ui**：用官方安装器非交互安装最新版。
- **Xray 内核锁定版本**：默认 `v26.6.27`，通过 3x-ui 接口切换。之后每 10 分钟检查一次，被面板或 3x-ui 升级换掉了就自动换回；也可以选择不锁定。
- **本机伪装站点**：Nginx 静态站点，配 Let's Encrypt 证书（自动续期），只监听 `127.0.0.1:8443`。80 端口只用来签证书和跳转。
- **一个 Reality 入站**：VLESS + Reality，默认端口 443，所有用户共用。target 是 `127.0.0.1:8443`，SNI 是本机域名，入站里还没有用户。不带 Reality 认证访问这个端口，看到的是本机的真站点和真证书。
- **面板**：端口统一 `2096`，用同一张证书走 HTTPS。3x-ui 自带的订阅服务默认也占 2096，所以会关掉。安装时会生成一个 API token，方便管理程序对接。
- **防火墙**：用 nftables，只放行 SSH、80、443、10001（预留给 SOCKS）、2096，对所有 IP 开放，其余入站连接一律丢弃。可以不启用。
- **不打印密码**：面板地址、账号密码和 API token 只写进 `/etc/xui-node/result.env`（只有 root 可读），安装过程中不会打印出来。

## 准备

1. 一台全新的 **Debian 11+ 或 Ubuntu 22.04+**（x86_64 / arm64），用 root 登录。
2. 一个**已经解析到这台机器 IP 的域名**（A 记录）。用 Cloudflare 的话要选**灰云（仅 DNS）**。
3. 服务商如果有安全组或云防火墙，先放行 TCP **80、443、2096** 和 SSH 端口。

## 安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fishermanxzx/xui-node/main/install.sh)
```

安装时会一步一步提问，直接回车就用方括号里的默认值：

1. 域名（会检查是否已经解析到本机）和证书提醒邮箱
2. 面板端口 `[2096]`
3. Reality 端口 `[443]`
4. SOCKS 预留端口 `[10001]`，填 0 表示不预留
5. Xray 内核版本 `[v26.6.27]`，填 keep 表示不锁定
6. 是否启用防火墙 `[Y]`，以及 SSH 端口

确认后开始安装，大约需要 2 到 5 分钟。可以重复执行：已经做完的步骤会跳过，上次填的值会作为默认值。

如果不想交互，可以直接带参数安装，例如通过 ssh 批量装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fishermanxzx/xui-node/main/install.sh) --domain us1.example.com -y
```

全部参数见 `xui-node install --help`。

## 装好以后

```bash
xui-node info     # 面板地址、用户名、密码、API token
```

登录面板后，在 443 端口的入站里添加用户。如果要交给管理程序管理，就把 `PANEL_URL` 和 `PANEL_TOKEN` 给它。

## 管理

```bash
xui-node                # 管理菜单
xui-node status         # 运行状态：面板、Xray 版本、证书到期时间、防火墙
xui-node fw             # 查看防火墙规则（改端口：编辑 /etc/xui-node/firewall.conf，再执行 xui-node fw apply）
xui-node xray-pin       # 立即检查一次 Xray 版本
xui-node update         # 更新 xui-node 脚本
x-ui                    # 3x-ui 自带的菜单（重置账号密码等）
```

注意：每次重新执行安装都会生成新的 API token，旧的作废。

## License

MIT
