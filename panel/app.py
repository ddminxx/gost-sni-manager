#!/usr/bin/env python3
"""GOST v3 SNI forwarding manager.

This panel manages a GOST v3 TCP reverse-proxy configuration that dispatches
connections by TLS SNI/Host. It is intentionally small and dependency-light so
it can run on a Debian VPS behind Caddy.
"""
from __future__ import annotations

import argparse
import functools
import hashlib
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Any, Dict, List, Tuple

from flask import (
    Flask,
    Response,
    flash,
    redirect,
    render_template,
    request,
    send_file,
    session,
    url_for,
)
from werkzeug.security import check_password_hash, generate_password_hash

APP_NAME = "GOST SNI Manager"
DATA_DIR = Path(os.environ.get("GOST_PANEL_DATA", "/etc/gost-panel"))
STATE_FILE = Path(os.environ.get("GOST_PANEL_STATE", str(DATA_DIR / "rules.json")))
AUTH_FILE = Path(os.environ.get("GOST_PANEL_AUTH", str(DATA_DIR / "auth.json")))
SECRET_FILE = Path(os.environ.get("GOST_PANEL_SECRET", str(DATA_DIR / "secret.key")))
GOST_CONFIG = Path(os.environ.get("GOST_CONFIG", "/etc/gost/config.yaml"))
GOST_SERVICE = os.environ.get("GOST_SERVICE", "gost")
CADDY_SERVICE = os.environ.get("CADDY_SERVICE", "caddy")
DEFAULT_LISTEN = os.environ.get("GOST_LISTEN", ":443")
DEFAULT_FALLBACK = os.environ.get("GOST_FALLBACK", "127.0.0.1:8053")

DOMAIN_RE = re.compile(r"^(?=.{1,253}$)([A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$")
HOST_RE = re.compile(r"^[A-Za-z0-9.-]+$|^\[[0-9A-Fa-f:.]+\]$")
LISTEN_RE = re.compile(r"^(:\d{1,5}|[A-Za-z0-9.:-]+:\d{1,5}|\[[0-9A-Fa-f:.]+\]:\d{1,5})$")


def create_app() -> Flask:
    app = Flask(__name__)
    ensure_dirs()
    app.secret_key = read_or_create_secret()
    app.config.update(
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Lax",
        PERMANENT_SESSION_LIFETIME=3600 * 8,
    )

    @app.context_processor
    def inject_globals() -> Dict[str, Any]:
        return {
            "app_name": APP_NAME,
            "version": "1.1.0",
            "csrf_token": get_csrf_token(),
        }

    @app.get("/login")
    def login_page() -> str:
        if is_logged_in():
            return redirect(url_for("dashboard"))  # type: ignore[return-value]
        return render_template("login.html")

    @app.post("/login")
    def login_submit() -> Response | str:
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")
        auth = load_auth()
        # Small fixed delay makes repeated guessing slightly noisier without hurting normal login.
        time.sleep(0.2)
        if username == auth.get("username") and check_password_hash(auth.get("password_hash", ""), password):
            session.clear()
            session["user"] = username
            session["csrf"] = secrets.token_urlsafe(32)
            flash("登录成功。", "success")
            return redirect(url_for("dashboard"))
        flash("用户名或密码错误。", "error")
        return render_template("login.html"), 401

    @app.post("/logout")
    @require_login
    @require_csrf
    def logout() -> Response:
        session.clear()
        flash("已退出登录。", "success")
        return redirect(url_for("login_page"))

    @app.get("/")
    @require_login
    def dashboard() -> str:
        state = load_state()
        status = collect_status()
        return render_template("dashboard.html", state=state, status=status, config_path=str(GOST_CONFIG))

    @app.post("/rules")
    @require_login
    @require_csrf
    def add_rule() -> Response:
        state = load_state()
        try:
            rule = parse_rule_form(request.form)
            rule["id"] = uuid.uuid4().hex[:12]
            state.setdefault("rules", []).append(rule)
            save_state(state)
            apply_config(restart=True)
            flash("规则已添加，并已重启 GOST。", "success")
        except ValueError as exc:
            flash(str(exc), "error")
        except RuntimeError as exc:
            flash(f"规则已保存，但应用配置失败：{exc}", "error")
        return redirect(url_for("dashboard"))

    @app.post("/rules/<rule_id>/update")
    @require_login
    @require_csrf
    def update_rule(rule_id: str) -> Response:
        state = load_state()
        try:
            new_rule = parse_rule_form(request.form)
            found = False
            for idx, rule in enumerate(state.get("rules", [])):
                if rule.get("id") == rule_id:
                    new_rule["id"] = rule_id
                    state["rules"][idx] = new_rule
                    found = True
                    break
            if not found:
                raise ValueError("找不到这条规则。")
            save_state(state)
            apply_config(restart=True)
            flash("规则已更新，并已重启 GOST。", "success")
        except ValueError as exc:
            flash(str(exc), "error")
        except RuntimeError as exc:
            flash(f"规则已保存，但应用配置失败：{exc}", "error")
        return redirect(url_for("dashboard"))

    @app.post("/rules/<rule_id>/toggle")
    @require_login
    @require_csrf
    def toggle_rule(rule_id: str) -> Response:
        state = load_state()
        for rule in state.get("rules", []):
            if rule.get("id") == rule_id:
                rule["enabled"] = not bool(rule.get("enabled", True))
                save_state(state)
                try:
                    apply_config(restart=True)
                    flash("规则状态已切换，并已重启 GOST。", "success")
                except RuntimeError as exc:
                    flash(f"规则已保存，但应用配置失败：{exc}", "error")
                break
        else:
            flash("找不到这条规则。", "error")
        return redirect(url_for("dashboard"))

    @app.post("/rules/<rule_id>/delete")
    @require_login
    @require_csrf
    def delete_rule(rule_id: str) -> Response:
        state = load_state()
        before = len(state.get("rules", []))
        state["rules"] = [r for r in state.get("rules", []) if r.get("id") != rule_id]
        if len(state["rules"]) == before:
            flash("找不到这条规则。", "error")
        else:
            save_state(state)
            try:
                apply_config(restart=True)
                flash("规则已删除，并已重启 GOST。", "success")
            except RuntimeError as exc:
                flash(f"规则已删除，但应用配置失败：{exc}", "error")
        return redirect(url_for("dashboard"))

    @app.post("/settings")
    @require_login
    @require_csrf
    def update_settings() -> Response:
        state = load_state()
        try:
            listen = request.form.get("listen", "").strip() or DEFAULT_LISTEN
            fallback = request.form.get("fallback_addr", "").strip() or DEFAULT_FALLBACK
            if not validate_listen(listen):
                raise ValueError("监听地址格式不正确，例如 :443。")
            if not validate_backend_addr(fallback):
                raise ValueError("默认后端格式不正确，例如 127.0.0.1:8053。")
            state["listen"] = listen
            state["fallback_addr"] = fallback
            save_state(state)
            apply_config(restart=True)
            flash("基础配置已更新，并已重启 GOST。", "success")
        except ValueError as exc:
            flash(str(exc), "error")
        except RuntimeError as exc:
            flash(f"配置已保存，但应用失败：{exc}", "error")
        return redirect(url_for("dashboard"))

    @app.post("/apply")
    @require_login
    @require_csrf
    def apply_now() -> Response:
        try:
            apply_config(restart=True)
            flash("已重新生成 GOST 配置并重启服务。", "success")
        except RuntimeError as exc:
            flash(f"应用失败：{exc}", "error")
        return redirect(url_for("dashboard"))

    @app.get("/config")
    @require_login
    def view_config() -> Response:
        yaml_text = generate_gost_config(load_state())
        return Response(yaml_text, mimetype="text/plain; charset=utf-8")

    @app.get("/download/config.yaml")
    @require_login
    def download_config() -> Response:
        if not GOST_CONFIG.exists():
            apply_config(restart=False)
        return send_file(GOST_CONFIG, as_attachment=True, download_name="config.yaml")

    @app.get("/logs")
    @require_login
    def logs() -> str:
        gost_logs = run_cmd(["journalctl", "-u", GOST_SERVICE, "-n", "120", "--no-pager"], allow_fail=True)[1]
        caddy_logs = run_cmd(["journalctl", "-u", CADDY_SERVICE, "-n", "60", "--no-pager"], allow_fail=True)[1]
        return render_template("logs.html", gost_logs=gost_logs, caddy_logs=caddy_logs)

    return app


def require_login(func):
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        if not is_logged_in():
            return redirect(url_for("login_page"))
        return func(*args, **kwargs)
    return wrapper


def require_csrf(func):
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        token = request.form.get("csrf_token", "")
        if not token or token != session.get("csrf"):
            flash("页面已过期，请刷新后重试。", "error")
            return redirect(url_for("dashboard"))
        return func(*args, **kwargs)
    return wrapper


def is_logged_in() -> bool:
    return bool(session.get("user"))


def get_csrf_token() -> str:
    if "csrf" not in session:
        session["csrf"] = secrets.token_urlsafe(32)
    return session["csrf"]


def ensure_dirs() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    GOST_CONFIG.parent.mkdir(parents=True, exist_ok=True)


def read_or_create_secret() -> str:
    ensure_dirs()
    if SECRET_FILE.exists():
        return SECRET_FILE.read_text(encoding="utf-8").strip()
    secret = secrets.token_urlsafe(48)
    atomic_write_text(SECRET_FILE, secret + "\n", mode=0o600)
    return secret


def load_auth() -> Dict[str, str]:
    if not AUTH_FILE.exists():
        raise RuntimeError("尚未初始化登录账号，请先运行 install.sh。")
    return json.loads(AUTH_FILE.read_text(encoding="utf-8"))


def save_auth(username: str, password: str) -> None:
    ensure_dirs()
    data = {
        "username": username,
        "password_hash": generate_password_hash(password, method="pbkdf2:sha256", salt_length=16),
        "updated_at": int(time.time()),
    }
    atomic_write_text(AUTH_FILE, json.dumps(data, ensure_ascii=False, indent=2) + "\n", mode=0o600)


def default_state() -> Dict[str, Any]:
    return {
        "listen": DEFAULT_LISTEN,
        "fallback_addr": DEFAULT_FALLBACK,
        "rules": [],
    }


def load_state() -> Dict[str, Any]:
    ensure_dirs()
    if not STATE_FILE.exists():
        state = default_state()
        save_state(state)
        return state
    with STATE_FILE.open("r", encoding="utf-8") as fh:
        data = json.load(fh)
    data.setdefault("listen", DEFAULT_LISTEN)
    data.setdefault("fallback_addr", DEFAULT_FALLBACK)
    data.setdefault("rules", [])
    return data


def save_state(state: Dict[str, Any]) -> None:
    ensure_dirs()
    atomic_write_text(STATE_FILE, json.dumps(state, ensure_ascii=False, indent=2) + "\n", mode=0o600)


def atomic_write_text(path: Path, text: str, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.chmod(tmp_path, mode)
        os.replace(tmp_path, path)
    finally:
        try:
            os.unlink(tmp_path)
        except FileNotFoundError:
            pass


def parse_rule_form(form) -> Dict[str, Any]:
    sni = form.get("sni", "").strip().lower()
    target = form.get("target", "").strip()
    port_str = form.get("port", "443").strip()
    note = form.get("note", "").strip()[:120]
    enabled = form.get("enabled") == "on" or form.get("enabled") == "true"

    if not validate_domain(sni):
        raise ValueError("SNI 域名格式不正确，例如 www.dropbox.com。")
    if not validate_host(target):
        raise ValueError("目标域名/IP 格式不正确，例如 hk-alice.example.com。")
    try:
        port = int(port_str)
    except ValueError as exc:
        raise ValueError("端口必须是数字。") from exc
    if not (1 <= port <= 65535):
        raise ValueError("端口范围必须是 1-65535。")
    return {"sni": sni, "target": target, "port": port, "note": note, "enabled": enabled}


def validate_domain(domain: str) -> bool:
    if "`" in domain or "\n" in domain or "\r" in domain:
        return False
    return bool(DOMAIN_RE.match(domain))


def validate_host(host: str) -> bool:
    if not host or "`" in host or "\n" in host or "\r" in host or "/" in host:
        return False
    if host.startswith("[") and "]" in host:
        return bool(HOST_RE.match(host))
    return bool(HOST_RE.match(host)) and len(host) <= 253


def validate_backend_addr(addr: str) -> bool:
    if not addr or "`" in addr or "\n" in addr or "\r" in addr or "/" in addr:
        return False
    if addr.startswith("["):
        m = re.match(r"^\[[0-9A-Fa-f:.]+\]:(\d{1,5})$", addr)
        return bool(m and 1 <= int(m.group(1)) <= 65535)
    if ":" not in addr:
        return False
    host, port_s = addr.rsplit(":", 1)
    if not validate_host(host):
        return False
    try:
        port = int(port_s)
    except ValueError:
        return False
    return 1 <= port <= 65535


def validate_listen(listen: str) -> bool:
    if not LISTEN_RE.match(listen):
        return False
    try:
        port = int(listen.rsplit(":", 1)[1])
    except ValueError:
        return False
    return 1 <= port <= 65535


def sanitize_node_name(sni: str, fallback: bool = False) -> str:
    if fallback:
        return "caddy-fallback"
    cleaned = re.sub(r"[^A-Za-z0-9_-]+", "-", sni).strip("-")[:32]
    suffix = hashlib.sha1(sni.encode("utf-8")).hexdigest()[:8]
    return f"sni-{cleaned}-{suffix}"


def generate_gost_config(state: Dict[str, Any]) -> str:
    listen = state.get("listen") or DEFAULT_LISTEN
    fallback = state.get("fallback_addr") or DEFAULT_FALLBACK
    if not validate_listen(listen):
        raise RuntimeError(f"监听地址无效：{listen}")
    if not validate_backend_addr(fallback):
        raise RuntimeError(f"默认后端无效：{fallback}")

    lines: List[str] = [
        "services:",
        "- name: reality-443",
        f'  addr: "{listen}"',
        "  handler:",
        "    type: tcp",
        "    metadata:",
        "      sniffing: true",
        "  listener:",
        "    type: tcp",
        "  forwarder:",
        "    nodes:",
    ]

    enabled_rules = [r for r in state.get("rules", []) if r.get("enabled", True)]
    for rule in enabled_rules:
        sni = str(rule.get("sni", "")).strip().lower()
        target = str(rule.get("target", "")).strip()
        port = int(rule.get("port", 443))
        if not validate_domain(sni):
            raise RuntimeError(f"SNI 域名无效：{sni}")
        if not validate_host(target) or not (1 <= port <= 65535):
            raise RuntimeError(f"后端无效：{target}:{port}")
        lines.extend([
            f"    - name: {sanitize_node_name(sni)}",
            f"      addr: {target}:{port}",
            "      matcher:",
            f"        rule: Host(`{sni}`)",
        ])

    lines.extend([
        f"    - name: {sanitize_node_name('', fallback=True)}",
        f"      addr: {fallback}",
        "",
    ])
    return "\n".join(lines)


def apply_config(restart: bool) -> None:
    yaml_text = generate_gost_config(load_state())
    atomic_write_text(GOST_CONFIG, yaml_text, mode=0o644)
    if restart:
        code, out = run_cmd(["systemctl", "restart", GOST_SERVICE], allow_fail=True)
        if code != 0:
            raise RuntimeError(out.strip() or f"systemctl restart {GOST_SERVICE} failed")


def collect_status() -> Dict[str, str]:
    status: Dict[str, str] = {}
    for svc in (GOST_SERVICE, CADDY_SERVICE):
        code, out = run_cmd(["systemctl", "is-active", svc], allow_fail=True)
        status[svc] = out.strip() if out.strip() else ("active" if code == 0 else "unknown")
    status["gost_version"] = run_cmd(["/usr/local/bin/gost", "-V"], allow_fail=True)[1].strip()
    status["listen_443"] = run_cmd(["bash", "-lc", "ss -tulnp | grep ':443' || true"], allow_fail=True)[1].strip()
    return status


def run_cmd(cmd: List[str], allow_fail: bool = False) -> Tuple[int, str]:
    try:
        completed = subprocess.run(cmd, check=False, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=12)
        if completed.returncode != 0 and not allow_fail:
            raise RuntimeError(completed.stdout)
        return completed.returncode, completed.stdout
    except Exception as exc:  # pragma: no cover - defensive for VPS runtime
        if allow_fail:
            return 1, str(exc)
        raise


def parse_init_rules(raw: str) -> List[Dict[str, Any]]:
    rules: List[Dict[str, Any]] = []
    if not raw.strip():
        return rules
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        if "=" not in item or ":" not in item:
            raise ValueError("INIT_RULES 格式应为 sni=target:port,sni2=target2:port")
        sni, backend = item.split("=", 1)
        target, port_s = backend.rsplit(":", 1)
        port = int(port_s)
        if not validate_domain(sni.strip().lower()) or not validate_host(target.strip()) or not (1 <= port <= 65535):
            raise ValueError(f"初始化规则无效：{item}")
        rules.append({
            "id": uuid.uuid4().hex[:12],
            "sni": sni.strip().lower(),
            "target": target.strip(),
            "port": port,
            "note": "初始化规则",
            "enabled": True,
        })
    return rules


def cli() -> int:
    parser = argparse.ArgumentParser(description=APP_NAME)
    sub = parser.add_subparsers(dest="command")

    serve = sub.add_parser("serve", help="run web panel")
    serve.add_argument("--host", default=os.environ.get("GOST_PANEL_HOST", "127.0.0.1"))
    serve.add_argument("--port", type=int, default=int(os.environ.get("GOST_PANEL_PORT", "7080")))

    init = sub.add_parser("init", help="initialize auth and state")
    init.add_argument("--username", required=True)
    init.add_argument("--password", required=True)
    init.add_argument("--listen", default=DEFAULT_LISTEN)
    init.add_argument("--fallback", default=DEFAULT_FALLBACK)
    init.add_argument("--init-rules", default=os.environ.get("INIT_RULES", ""))
    init.add_argument("--force-auth", action="store_true")

    sub.add_parser("render-config", help="write gost config from state")

    args = parser.parse_args()
    if args.command == "serve":
        app = create_app()
        app.run(host=args.host, port=args.port)
        return 0
    if args.command == "init":
        ensure_dirs()
        read_or_create_secret()
        if args.force_auth or not AUTH_FILE.exists():
            save_auth(args.username, args.password)
        state = load_state()
        state["listen"] = args.listen
        state["fallback_addr"] = args.fallback
        if not state.get("rules"):
            state["rules"] = parse_init_rules(args.init_rules)
        save_state(state)
        apply_config(restart=False)
        return 0
    if args.command == "render-config":
        apply_config(restart=False)
        return 0
    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(cli())
