# Panel runtime files

这是 GOST SNI Manager 的面板程序目录。

- `app.py`：面板主程序，负责账号、规则、模式切换、配置生成和服务重启。
- `relay.py`：拼车模式使用的本地 TCP 中继，负责流量统计、限速、流量限制和过期规则拦截。
- `wsgi.py`：Gunicorn 入口。
- `templates/`：页面模板。
- `static/style.css`：页面样式。
- `requirements.txt`：Python 依赖。

默认自用模式下，规则由 GOST 直接转发到目标落地 VPS；拼车模式下，规则先进入本机中继再连接落地 VPS。
