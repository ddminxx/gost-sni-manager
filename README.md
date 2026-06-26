# GOST SNI Manager

GOST SNI Manager（简称 GSM）是一个用于中转 VPS 的轻量级 443 端口复用管理面板。

它的目标是让 **Caddy 反代** 和 **GOST 转发** 共存：中转 VPS 只暴露一个 443 端口，GOST 根据落地 VPS 的 REALITY `SNI / serverName` 判断流量应该转发到哪台落地 VPS；没有命中已配置 SNI 的流量，则转发到本机 Caddy，由 Caddy 处理网站、面板或其他反代服务。

## 项目功能

- 中转 VPS 实现 443 端口复用。
- GOST 监听 443，Caddy 默认监听 8053。
- GOST 通过 REALITY 的 SNI 区分多台落地 VPS。
- 支持将不同 SNI 转发到不同落地 VPS 的域名或 IP。
- 未匹配到规则的未知 SNI 自动转发到 Caddy。
- 面板支持添加、编辑、启用/禁用、删除转发规则。
- 面板操作后自动生成 `/etc/gost/config.yaml` 并重启 GOST。
- 一键脚本自动安装依赖、GOST v3、Caddy 和管理面板。
- 一键脚本自动生成随机用户名和强密码，并保存到 `/root/gsm.txt`。
- 面板端口自动选择 `50000-55000` 之间未占用端口。
- 可选配置面板域名；配置后由 Caddy 自动申请证书。

## 适用场景

假设你有多台落地 VPS，每台落地 VPS 都已经安装 Xray 并配置 REALITY 协议。传统方式可能需要不同的非标端口做中转转发，容易暴露特征，也不方便管理。

GSM 的思路是：

```text
客户端连接中转 VPS:443
        ↓
GOST 读取 TLS/REALITY 握手里的 SNI
        ↓
如果 SNI 命中规则：转发到对应落地 VPS:443
如果 SNI 未命中规则：转发到本机 Caddy:8053
```

这样可以让多台落地 VPS 共用中转 VPS 的同一个 443 入口，客户端只需要把连接地址改成中转 VPS 的域名或 IP，REALITY 的 `serverName / SNI` 保持为对应落地配置的 SNI。

## 轻量说明

GSM 本身很轻量，面板只是一个小型 Flask + Gunicorn Web 应用，主要工作是保存规则、生成 GOST 配置并重启服务。

大致资源占用如下，不同系统和版本会有差异：

```text
项目面板代码：约几 MB
Python 虚拟环境：约 30-80 MB
GOST 二进制：约 20-50 MB
Caddy 及依赖：约 50-150 MB
总磁盘占用：通常约 100-300 MB

空闲内存占用：
GOST：约 15-40 MB
面板：约 30-80 MB
Caddy：约 20-60 MB
合计：通常约 70-180 MB
```

实际转发性能主要取决于中转 VPS 线路、带宽、CPU、并发连接数以及中转到落地的网络质量。GOST 在这里只做 TCP 透传和 SNI 分流，不解密 REALITY 流量，通常性能损耗很小。

## 一键安装

在中转 VPS 上执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ddminxx/gost-sni-manager/main/install.sh)
```

脚本会自动安装需要的依赖，并询问：

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

其中：
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

安装完成后登录面板。

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

## 面板操作逻辑

1. 添加 SNI 和转发目标。
2. 面板保存规则到 `/etc/gost-panel/rules.json`。
3. 面板生成 `/etc/gost/config.yaml`。
4. 面板重启 `gost.service`。
5. GOST 继续监听公网 443。
6. 命中 SNI 的流量转发到落地 VPS。
7. 未命中 SNI 的流量转发到 Caddy fallback。

## 生成的 GOST 配置示例

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
    - name: sni-apple-com
      addr: b.example.com:443
      matcher:
        rule: Host(`apple.com`)
    - name: sni-visa-cn
      addr: c.example.com:443
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
systemctl status gost gost-panel caddy --no-pager
```

查看 GOST 日志：

```bash
journalctl -u gost -f
```

查看面板日志：

```bash
journalctl -u gost-panel -f
```

查看 Caddy 日志：

```bash
journalctl -u caddy -f
```

查看当前 GOST 配置：

```bash
cat /etc/gost/config.yaml
```

## 非交互安装

已经准备好面板域名时：

```bash
PANEL_DOMAIN=admin.example.com \
INIT_RULES='apple.com=b.example.com:443,visa.cn=c.example.com:443' \
bash <(curl -fsSL https://raw.githubusercontent.com/ddminxx/gost-sni-manager/main/install.sh)
```

## 卸载

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ddminxx/gost-sni-manager/main/uninstall.sh)
```

卸载脚本会删除面板、GOST 配置和 systemd 服务。是否删除 GOST 二进制、是否卸载 Caddy，会在卸载过程中询问。
