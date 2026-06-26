# GOST SNI Manager

一个用于 Debian/Ubuntu VPS 的 GOST v3 443 SNI 分流管理面板。

适合这种结构：

```text
公网 443 -> GOST v3
  ├─ SNI = www.dropbox.com  -> 落地 A:443
  ├─ SNI = drive.google.com -> 落地 B:443
  └─ 其他未知 SNI          -> 本机 Caddy:8053
```

面板功能：

- 随机用户名 + 强密码登录
- 添加、编辑、禁用、删除 SNI 转发规则
- 自动生成 `/etc/gost/config.yaml`
- 自动重启 `gost.service`
- 查看 GOST/Caddy 运行状态和日志
- Caddy fallback 默认站点
- 可选管理域名，域名会自动写入 Caddy 并申请证书
- 未配置域名时，面板直接开放在随机高位端口

> GOST 只做 TCP 透传和 SNI 嗅探，不解密 TLS。REALITY 后端仍然会收到原始 TLS/REALITY 握手。

## 一键安装

上传到 GitHub 后，在 VPS 上执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/你的用户名/gost-sni-manager/main/install.sh)
```

脚本会交互询问：

```text
是否配置管理面板域名？[y/N]
```

### 选择配置域名

先把管理域名解析到这台中转 VPS，例如：

```text
admin.example.com A/AAAA -> 中转 VPS IP
```

安装时选择 `y`，然后输入：

```text
admin.example.com
```

安装完成后访问：

```text
https://admin.example.com/
```

访问链路：

```text
浏览器 https://admin.example.com:443
  -> GOST 443
  -> 未匹配 REALITY SNI，fallback 到 Caddy 8053
  -> Caddy 自动申请并提供 admin.example.com 证书
  -> Caddy reverse_proxy 到面板 127.0.0.1:随机端口
```

### 不配置域名

安装时选择 `n` 或直接回车。脚本会在 `50000-55000` 中随机选择一个未占用端口，并输出：

```text
http://服务器IP:随机端口/
```

这种方式建议用防火墙限制来源，后续再配置管理域名。

## 安装完成后的登录信息

脚本会随机生成用户名和强密码，并在安装完成后显示：

```text
面板访问: https://admin.example.com/
用户名: gsm_xxxxxxxx
密码: 随机强密码
登录信息已保存: /root/gsm.txt
```

同样内容会保存到：

```bash
/root/gsm.txt
```

文件权限为 `600`，仅 root 可读。请立即保存。

## 初始化转发规则

安装时可以通过 `INIT_RULES` 预置规则，格式：

```bash
INIT_RULES='www.dropbox.com=hk-a.example.com:443,drive.google.com=hk-b.example.com:443' \
bash <(curl -fsSL https://raw.githubusercontent.com/你的用户名/gost-sni-manager/main/install.sh)
```

安装后也可以直接在页面里新增规则。

## 常用环境变量

| 变量 | 默认值 | 说明 |
|---|---:|---|
| `PANEL_DOMAIN` | 空 | 面板域名；设置后跳过交互询问 |
| `PANEL_USER` | 随机生成 | 自定义登录用户名 |
| `PANEL_PASSWORD` | 随机生成 | 自定义初始密码，不建议手动设置弱密码 |
| `PANEL_PORT` | 随机空闲端口 | 面板内部端口，默认在 `50000-55000` 中选择 |
| `CADDY_HTTPS_PORT` | `8053` | Caddy HTTPS fallback 端口 |
| `GOST_LISTEN` | `:443` | GOST 监听地址 |
| `GOST_FALLBACK` | `127.0.0.1:8053` | 未匹配 SNI 的默认后端 |
| `INIT_RULES` | 空 | 初始化规则 |
| `CLEAN_OLD_AURORA` | `0` | 设为 `1` 会清理旧 aurora@gost v2 服务 |
| `CREDENTIALS_FILE` | `/root/gsm.txt` | 登录信息保存路径 |

## 非交互安装示例

已经准备好域名时：

```bash
PANEL_DOMAIN=admin.example.com \
INIT_RULES='www.dropbox.com=hk-a.example.com:443,drive.google.com=hk-b.example.com:443' \
bash <(curl -fsSL https://raw.githubusercontent.com/你的用户名/gost-sni-manager/main/install.sh)
```

清理旧 aurora@gost v2 服务并安装：

```bash
CLEAN_OLD_AURORA=1 bash <(curl -fsSL https://raw.githubusercontent.com/你的用户名/gost-sni-manager/main/install.sh)
```

## 面板操作逻辑

1. 在页面添加 SNI 和后端，例如 `www.dropbox.com -> hk-a.example.com:443`。
2. 面板保存到 `/etc/gost-panel/rules.json`。
3. 面板重新生成 `/etc/gost/config.yaml`。
4. 面板执行 `systemctl restart gost`。
5. GOST 根据 ClientHello 里的 SNI 选择后端。
6. 没匹配到任何规则的连接会进入默认后端 `127.0.0.1:8053`。

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
    - name: sni-example
      addr: hk-a.example.com:443
      matcher:
        rule: Host(`www.dropbox.com`)
    - name: caddy-fallback
      addr: 127.0.0.1:8053
```

## 常用命令

```bash
systemctl status gost gost-panel caddy --no-pager
journalctl -u gost -f
journalctl -u gost-panel -f
journalctl -u caddy -f
cat /root/gsm.txt
cat /etc/gost/config.yaml
```

## 上传到 GitHub

在项目目录执行：

```bash
git init
git add .
git commit -m "initial gost sni manager"
git branch -M main
git remote add origin git@github.com:你的用户名/gost-sni-manager.git
git push -u origin main
```

随后即可使用 raw 一键安装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/你的用户名/gost-sni-manager/main/install.sh)
```

## 卸载

```bash
bash uninstall.sh
```
