# GOST SNI Manager

GOST SNI Manager（简称 GSM）是一个用于中转 VPS 的轻量级 443 端口复用管理面板，支持 **自用模式** 和 **拼车模式** 两种运行方式。

它让 **GOST 转发**、**Caddy 反代** 和 **REALITY 多落地分流** 共存：中转 VPS 只暴露一个 443 端口，GOST 根据落地 VPS 的 REALITY `SNI / serverName` 判断流量应该转发到哪台落地 VPS；没有命中已配置 SNI 的流量，则转发到本机 Caddy，由 Caddy 处理网站、面板或其他反代服务。

## 项目功能

### 两种运行模式

- **自用模式（默认）**：GOST 命中 SNI 后直接转发到目标落地 VPS，链路最短，性能最好，适合自己使用。
- **拼车模式**：GOST 命中 SNI 后先转发到本机 `gsm-relay`，再由 `gsm-relay` 连接落地 VPS，可实现子账号、限速、流量统计、流量限制和有效期控制。
- 可在面板中随时切换运行模式，切换后自动生成 GOST 配置并重启服务。

### 443 端口复用

- 中转 VPS 实现 443 端口复用。
- GOST 监听公网 443。
- Caddy 默认监听本机 8053。
- GOST 识别 REALITY 握手里的 SNI。
- 命中 SNI 规则：按当前模式转发到落地 VPS。
- 未命中 SNI 规则：转发到 Caddy fallback。
- 避免为不同落地 VPS 暴露多个非标端口，降低非标端口转发 REALITY 协议带来的风险。

### 拼车面板

拼车功能仅在“拼车模式”下启用：

- 安装时自动生成主账号用户名和强密码。
- 主账号可创建多个子账号。
- 主账号可限制子账号最多添加多少条转发规则。
- 主账号可限制子账号每条规则的限速。
- 主账号可限制子账号每条规则的流量。
- 主账号可限制子账号账号总流量。
- 主账号可设置子账号有效期。
- 子账号过期、禁用、超出流量后，其规则自动失效。
- 子账号可自行添加、编辑、删除自己的转发规则。
- 子账号不能修改主账号分配的限速、流量、规则数量和有效期。
- 子账号可查看自己的已用流量、剩余流量和到期时间。

### 运维功能

- 面板添加/修改规则后自动生成 `/etc/gost/config.yaml`。
- 自用模式下自动重启 `gost.service`。
- 拼车模式下自动启用并重启 `gost.service` 和 `gsm-relay.service`。
- 支持查看 GOST、本地中继、Caddy 日志。
- 支持查看实时 GOST 配置，方便排错。
- 一键脚本自动安装依赖、GOST v3、Caddy 和管理面板。
- 面板端口自动选择 `50000-55000` 之间未占用端口。
- 可选配置面板域名；配置后由 Caddy 自动申请证书。
- 登录信息保存到 `/root/gsm.txt`。

## 工作原理

### 自用模式，默认

```text
客户端连接中转 VPS:443
        ↓
GOST 监听 443，并读取 TLS/REALITY 握手里的 SNI
        ↓
如果 SNI 命中规则：GOST 直接连接到落地 VPS 的域名或 IP:端口
        ↓
落地 VPS 的 Xray REALITY 继续处理连接

如果 SNI 未命中规则：GOST 转发到 127.0.0.1:8053
        ↓
Caddy 处理网站、管理面板或其他反代服务
```

自用模式链路最短：

```text
客户端 → GOST:443 → 落地 VPS:443
```

### 拼车模式

```text
客户端连接中转 VPS:443
        ↓
GOST 监听 443，并读取 TLS/REALITY 握手里的 SNI
        ↓
如果 SNI 命中规则：GOST 转发到本机 gsm-relay 中继端口
        ↓
gsm-relay 统计流量、执行限速、检查账号是否过期或超量
        ↓
gsm-relay 连接到落地 VPS 的域名或 IP:端口

如果 SNI 未命中规则：GOST 转发到 127.0.0.1:8053
        ↓
Caddy 处理网站、管理面板或其他反代服务
```

拼车模式链路为：

```text
客户端 → GOST:443 → gsm-relay 本机中继 → 落地 VPS:443
```

## 轻量说明

GSM 本身比较轻量。默认自用模式下，`gsm-relay` 不启动，资源占用更低。

```text
GOST：负责 443 SNI 分流
GSM Panel：Flask + Gunicorn 管理面板
Caddy：负责 fallback 网站/面板反代
gsm-relay：仅拼车模式启用，用于统计流量和执行限速
```

大致资源占用如下，不同系统和版本会有差异：

```text
项目面板代码：约几 MB
Python 虚拟环境：约 35-90 MB
GOST 二进制：约 20-50 MB
Caddy 及依赖：约 30-120 MB
SQLite 数据库：初始很小，随规则和流量统计增长
脚本依赖：采用 --no-install-recommends，尽量避免安装 gcc、g++、build-essential 等编译组件
总磁盘占用：通常约 120-260 MB

自用模式空闲内存：通常约 60-160 MB
拼车模式空闲内存：通常约 80-240 MB
```

转发性能主要取决于中转 VPS 线路、带宽、CPU、并发连接数以及中转到落地的网络质量。GOST 在这里只做 TCP 透传和 SNI 分流，不解密 REALITY 流量。自用模式性能最好；拼车模式会多经过本机中继，换来限速、流量统计和账号管理能力。

## 一键安装

在中转 VPS 上执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ddminxx/gost-sni-manager/main/install.sh)
```

脚本会自动安装轻量依赖、GOST v3、Caddy 和面板，并询问：

```text
是否现在配置面板域名？[y/N]
```

### 配置面板域名

先将面板域名解析到中转 VPS，例如：

```text
admin.example.com -> 中转 VPS IP
```

安装时选择 `y`，然后输入：

```text
admin.example.com
```

安装完成后访问：

```text
https://admin.example.com/
```

### 不配置面板域名

安装时直接回车或输入 `n`。脚本会自动选择 `50000-55000` 之间未占用的高位端口，并让面板监听公网：

```text
http://中转VPS_IP:随机端口/
```

这种方式更简单，但建议用防火墙限制访问来源，或者后续再配置面板域名。

## 安装完成后的信息

安装结束后脚本会显示：

```text
面板访问: https://admin.example.com/
用户名: gsm_xxxxxxxx
密码: 随机强密码
登录信息已保存: /root/gsm.txt
```

如果没有配置面板域名，会显示类似：

```text
面板访问: http://中转VPS_IP:54735/
用户名: gsm_xxxxxxxx
密码: 随机强密码
登录信息已保存: /root/gsm.txt
[!] 未配置面板域名，面板直接监听 0.0.0.0:54735。建议用防火墙限制来源，或后续配置域名。
```

请立即保存用户名和密码。后续也可以在 VPS 上查看：

```bash
cat /root/gsm.txt
```

## 使用示例

假设有 3 台 VPS：

### 1. 中转 VPS A

```text
中转 VPS：A
中转域名：a.example.com
网站/反代域名：aweb.example.com

a.example.com 已解析到 VPS A 的 IP
aweb.example.com 已解析到 VPS A 的 IP
```

### 2. 落地 VPS B

```text
落地 VPS：B
落地域名：b.example.com

b.example.com 已解析到 VPS B 的 IP
VPS B 已安装 Xray
VPS B 已配置 REALITY
REALITY SNI / serverName：apple.com
REALITY 连接端口：443
```

### 3. 落地 VPS C

```text
落地 VPS：C
落地域名：c.example.com

c.example.com 已解析到 VPS C 的 IP
VPS C 已安装 Xray
VPS C 已配置 REALITY
REALITY SNI / serverName：visa.cn
REALITY 连接端口：443
```

### 4. 在中转 VPS A 安装 GSM 面板

在 VPS A 执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ddminxx/gost-sni-manager/main/install.sh)
```

安装完成后登录面板。默认是“自用模式”。

### 5. 添加落地 B 的规则

在面板中添加：

```text
SNI / serverName：apple.com
目标域名或 IP：b.example.com
目标端口：443
备注：落地 B
```

### 6. 添加落地 C 的规则

在面板中添加：

```text
SNI / serverName：visa.cn
目标域名或 IP：c.example.com
目标端口：443
备注：落地 C
```

### 7. 添加 Caddy 反代规则，可选

如果你希望 `aweb.example.com` 明确进入本机 Caddy，可以在面板中添加：

```text
SNI / serverName：aweb.example.com
目标域名或 IP：127.0.0.1
目标端口：8053
备注：反代
```

说明：默认情况下，未匹配到任何规则的 SNI 也会进入 `127.0.0.1:8053`。所以这条规则不是必须的，但添加后逻辑更直观。

Caddy 中仍需要你自行配置 `aweb.example.com` 的具体反代规则。

### 8. 客户端连接方式

连接落地 VPS B 时，把客户端里的连接地址改成中转 VPS A：

```text
原连接地址：b.example.com
新连接地址：a.example.com
端口：443
SNI / serverName：apple.com
```

连接落地 VPS C 时：

```text
原连接地址：c.example.com
新连接地址：a.example.com
端口：443
SNI / serverName：visa.cn
```

访问 Caddy 反代服务时，直接访问：

```text
https://aweb.example.com/
```

## 拼车模式使用方法

主账号登录后，在“运行模式”中切换为“拼车模式”。切换后，面板会启用 `gsm-relay.service`，并让 GOST 将命中的 SNI 先转到本机中继。

主账号可以创建子账号，例如：

```text
用户名：user01
最多规则：2 条
每条规则限速：30 Mbps
每条规则流量：100 GB
账号总流量：200 GB
有效期：2026-12-31 23:59
```

子账号登录后可以自己添加规则，但不能修改限速、流量和有效期。子账号能看到：

```text
账号到期时间
账号总流量
已用流量
剩余流量
每条规则限速
每条规则流量
```

如果账号过期、账号总流量用完、某条规则流量用完，相关转发会自动停止。

## 面板操作逻辑

### 自用模式

1. 添加 SNI 和转发目标。
2. 面板保存规则到 SQLite 数据库 `/etc/gost-panel/gsm.db`。
3. 面板生成 `/etc/gost/config.yaml`。
4. GOST 监听公网 443。
5. 命中 SNI 的流量由 GOST 直接转发到目标落地 VPS。
6. 未命中 SNI 的流量转发到 Caddy fallback。

### 拼车模式

1. 主账号切换为拼车模式。
2. 添加 SNI 和转发目标。
3. 面板为每条规则分配一个本机中继端口。
4. 面板生成 `/etc/gost/config.yaml`。
5. GOST 继续监听公网 443。
6. 命中 SNI 的流量转发到本机限速中继。
7. 本机限速中继统计流量、执行限速和流量限制。
8. 中继再连接到真正落地 VPS。
9. 未命中 SNI 的流量转发到 Caddy fallback。

## 生成的 GOST 配置示例

自用模式：

```yaml
services:
- name: reality-443
  addr: ":443"
  handler:
    type: tcp
    metadata:
      sniffing: true
  listener:
    type: tcp
  forwarder:
    nodes:
    - name: sni-apple-com-xxxxxx
      addr: b.example.com:443
      matcher:
        rule: Host(`apple.com`)
    - name: sni-visa-cn-xxxxxx
      addr: c.example.com:443
      matcher:
        rule: Host(`visa.cn`)
    - name: caddy-fallback
      addr: 127.0.0.1:8053
```

拼车模式：

```yaml
services:
- name: reality-443
  addr: ":443"
  handler:
    type: tcp
    metadata:
      sniffing: true
  listener:
    type: tcp
  forwarder:
    nodes:
    - name: sni-apple-com-xxxxxx
      addr: 127.0.0.1:56001
      matcher:
        rule: Host(`apple.com`)
    - name: sni-visa-cn-xxxxxx
      addr: 127.0.0.1:56002
      matcher:
        rule: Host(`visa.cn`)
    - name: caddy-fallback
      addr: 127.0.0.1:8053
```

## 常用命令

查看登录信息：

```bash
cat /root/gsm.txt
```

查看服务状态：

```bash
systemctl status gost --no-pager
systemctl status gost-panel --no-pager
systemctl status caddy --no-pager
systemctl status gsm-relay --no-pager
```

查看日志：

```bash
journalctl -u gost -f
journalctl -u gost-panel -f
journalctl -u caddy -f
journalctl -u gsm-relay -f
```

重启服务：

```bash
systemctl restart gost gost-panel caddy
systemctl restart gsm-relay
```

查看 GOST 配置：

```bash
cat /etc/gost/config.yaml
```

查看数据库文件：

```bash
ls -lh /etc/gost-panel/gsm.db
```

## 常见问题

### 提示 curl: command not found

极简 Debian 系统可能没有预装 `curl`，而 raw 一键安装命令本身依赖 curl。先执行：

```bash
apt update && apt install -y curl ca-certificates
```

然后再运行一键安装命令。

### Caddy 源或 keyring 报错

新版脚本不再使用 Caddy Cloudsmith 源，默认优先从系统仓库安装 Caddy；如果系统仓库不可用，会自动改用 GitHub 二进制安装。

如果旧脚本残留过 Caddy 源，可以先清理：

```bash
rm -f /etc/apt/sources.list.d/caddy-stable.list
rm -f /etc/apt/sources.list.d/caddy*.list
rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
apt update
```

## 卸载

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ddminxx/gost-sni-manager/main/uninstall.sh)
```

卸载脚本会删除面板、数据库、GOST 配置和 systemd 服务，并询问是否删除 GOST 二进制和 Caddy 软件包。

## 注意事项

1. 中转 VPS 的 443 必须由 GOST 监听。
2. Caddy 默认监听本机 8053，用于 fallback。
3. 面板域名、网站域名需要解析到中转 VPS。
4. 落地 VPS 的 REALITY SNI 必须和面板里的 SNI 一致。
5. 客户端连接地址改成中转 VPS，SNI 仍保持落地 VPS 的 REALITY SNI。
6. 自用模式性能最好，但不做限速和流量统计。
7. 拼车模式支持限速和流量统计，但会多经过本机中继，高速大流量场景请给中转 VPS 留足 CPU 和内存。
8. 如果未配置面板域名，面板会公网监听随机高位端口，建议使用防火墙限制来源 IP。
