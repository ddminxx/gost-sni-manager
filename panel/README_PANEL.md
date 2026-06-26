# Panel files

这些文件会被 `install.sh` 安装到 `/opt/gost-sni-manager`。

运行方式：

```bash
/opt/gost-sni-manager/venv/bin/python /opt/gost-sni-manager/app.py serve --host 127.0.0.1 --port 50000
```

数据目录默认：

```text
/etc/gost-panel
```

面板会管理：

```text
/etc/gost/config.yaml
```

登录信息由安装脚本生成并保存到：

```text
/root/gsm.txt
```
