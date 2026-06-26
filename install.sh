#!/usr/bin/env bash
set -Eeuo pipefail

# GOST SNI Manager one-key installer for Debian/Ubuntu.
# It installs GOST v3, Caddy, and a web panel that manages SNI-based TCP forwarding.

if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 root 执行：sudo bash install.sh"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

PANEL_USER="${PANEL_USER:-}"
PANEL_PASSWORD="${PANEL_PASSWORD:-}"
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
PANEL_PORT="${PANEL_PORT:-}"
PANEL_BIND="${PANEL_BIND:-}"
PANEL_ACCESS_URL=""
SERVER_IP=""
CADDY_HTTPS_PORT="${CADDY_HTTPS_PORT:-8053}"
GOST_LISTEN="${GOST_LISTEN:-:443}"
GOST_FALLBACK="${GOST_FALLBACK:-127.0.0.1:${CADDY_HTTPS_PORT}}"
INIT_RULES="${INIT_RULES:-}"
INSTALL_DIR="${INSTALL_DIR:-/opt/gost-sni-manager}"
DATA_DIR="${DATA_DIR:-/etc/gost-panel}"
GOST_CONFIG="${GOST_CONFIG:-/etc/gost/config.yaml}"
CREDENTIALS_FILE="${CREDENTIALS_FILE:-/root/gsm.txt}"
CLEAN_OLD_AURORA="${CLEAN_OLD_AURORA:-0}"

log() {
  printf '\n\033[1;36m==> %s\033[0m\n' "$*"
}

warn() {
  printf '\n\033[1;33m[!] %s\033[0m\n' "$*"
}

die() {
  printf '\n\033[1;31m[x] %s\033[0m\n' "$*" >&2
  exit 1
}

validate_domain_bash() {
  local domain="$1"
  [[ "${domain}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

sanitize_domain_input() {
  local raw="$1"
  raw="${raw#http://}"
  raw="${raw#https://}"
  raw="${raw%%/*}"
  raw="${raw%%:*}"
  printf '%s' "${raw}"
}

prompt_panel_domain() {
  if [[ -n "${PANEL_DOMAIN}" ]]; then
    PANEL_DOMAIN="$(sanitize_domain_input "${PANEL_DOMAIN}")"
    validate_domain_bash "${PANEL_DOMAIN}" || die "PANEL_DOMAIN 格式不正确：${PANEL_DOMAIN}"
    return 0
  fi

  if [[ -t 0 ]]; then
    echo
    echo "是否配置管理面板域名？"
    echo "- 配置域名：脚本会把域名写入 Caddy，访问 https://你的域名/，并自动申请证书。"
    echo "- 不配置域名：面板直接开放在随机高位端口，访问 http://服务器IP:端口/。"
    read -r -p "是否现在配置面板域名？[y/N]: " ans || true
    case "${ans:-}" in
      y|Y|yes|YES|Yes|是)
        while true; do
          read -r -p "请输入面板域名，例如 admin.example.com: " input_domain || true
          PANEL_DOMAIN="$(sanitize_domain_input "${input_domain:-}")"
          if validate_domain_bash "${PANEL_DOMAIN}"; then
            break
          fi
          warn "域名格式不正确，请重新输入。"
        done
        ;;
      *)
        PANEL_DOMAIN=""
        ;;
    esac
  fi
}

require_debian_like() {
  if [[ ! -f /etc/os-release ]]; then
    die "未检测到 /etc/os-release，暂只支持 Debian/Ubuntu。"
  fi
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *) warn "当前系统是 ${PRETTY_NAME:-unknown}，脚本将按 Debian/Ubuntu 方式安装。" ;;
  esac
}

install_base_packages() {
  log "安装基础依赖"
  apt-get update
  apt-get install -y ca-certificates curl tar gzip openssl python3 python3-venv python3-pip systemd iproute2 gnupg debian-keyring debian-archive-keyring apt-transport-https
}

generate_username() {
  python3 - <<'PY'
import secrets
print('gsm_' + secrets.token_hex(4))
PY
}

generate_password() {
  python3 - <<'PY'
import secrets, string
alphabet = string.ascii_letters + string.digits + '@#%+=_.:-'
print(''.join(secrets.choice(alphabet) for _ in range(36)))
PY
}

validate_port_number() {
  local port="$1"
  [[ "${port}" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

is_port_free() {
  local port="$1"
  ! ss -H -tuln 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:|\])${port}$"
}

choose_panel_port() {
  if [[ -n "${PANEL_PORT}" ]]; then
    validate_port_number "${PANEL_PORT}" || die "PANEL_PORT 端口无效：${PANEL_PORT}"
    (( PANEL_PORT >= 50000 && PANEL_PORT <= 55000 )) || die "PANEL_PORT 必须在 50000-55000 范围内：${PANEL_PORT}"
    if ! is_port_free "${PANEL_PORT}"; then
      die "PANEL_PORT=${PANEL_PORT} 已被占用，请换一个端口。"
    fi
    return 0
  fi

  local port i
  for i in $(seq 1 200); do
    port=$((50000 + RANDOM % 5001))
    if is_port_free "${port}"; then
      PANEL_PORT="${port}"
      return 0
    fi
  done

  for port in $(seq 50000 55000); do
    if is_port_free "${port}"; then
      PANEL_PORT="${port}"
      return 0
    fi
  done
  die "50000-55000 之间没有找到未占用端口。"
}

detect_server_ip() {
  local ip=""
  ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "${ip}" ]]; then
    ip="$(curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true)"
  fi
  if [[ -z "${ip}" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  printf '%s' "${ip:-服务器IP}"
}

prepare_runtime_options() {
  log "生成面板账号和运行参数"
  choose_panel_port
  if [[ -z "${PANEL_USER}" ]]; then
    PANEL_USER="$(generate_username)"
  fi
  if [[ -z "${PANEL_PASSWORD}" ]]; then
    PANEL_PASSWORD="$(generate_password)"
  fi

  if [[ -n "${PANEL_DOMAIN}" ]]; then
    PANEL_BIND="127.0.0.1"
    PANEL_ACCESS_URL="https://${PANEL_DOMAIN}/"
  else
    PANEL_BIND="0.0.0.0"
    SERVER_IP="$(detect_server_ip)"
    PANEL_ACCESS_URL="http://${SERVER_IP}:${PANEL_PORT}/"
  fi
}

install_gost() {
  log "安装或升级 GOST v3"
  bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh) --install
  if [[ ! -x /usr/local/bin/gost ]] && command -v gost >/dev/null 2>&1; then
    install -m 0755 "$(command -v gost)" /usr/local/bin/gost
  fi
  if [[ -x /usr/local/bin/gost ]] && [[ ! -x /usr/bin/gost ]]; then
    ln -sf /usr/local/bin/gost /usr/bin/gost
  fi
  /usr/local/bin/gost -V || gost -V || true
}

install_caddy() {
  log "安装 Caddy"
  if ! command -v caddy >/dev/null 2>&1; then
    install -d -m 0755 /etc/apt/keyrings
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /etc/apt/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
    chmod 0644 /etc/apt/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    apt-get install -y caddy
  fi
  caddy version || true
}

cleanup_old_aurora() {
  if [[ "${CLEAN_OLD_AURORA}" != "1" ]]; then
    return 0
  fi
  log "清理旧 aurora@gost v2 服务"
  systemctl stop 'aurora@*.service' 2>/dev/null || true
  systemctl disable 'aurora@*.service' 2>/dev/null || true
  pkill -f '/usr/local/bin/gost -C /usr/local/etc/aurora' 2>/dev/null || true
  rm -f /etc/systemd/system/aurora@*.service
  rm -f /etc/systemd/system/multi-user.target.wants/aurora@*.service
  rm -rf /usr/local/etc/aurora
  systemctl daemon-reload
  systemctl reset-failed || true
}

extract_payload() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local script_dir=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P 2>/dev/null || true)"
  fi
  if [[ -n "${script_dir}" && -f "${script_dir}/panel/app.py" ]]; then
    echo "${script_dir}/panel"
    return 0
  fi
  awk '/^__GOST_PANEL_ARCHIVE_BELOW__$/ {found=1; next} found {print}' "${BASH_SOURCE[0]}" | base64 -d | tar -xz -C "${tmp_dir}"
  echo "${tmp_dir}/panel"
}

install_panel_files() {
  log "安装管理面板"
  local src
  src="$(extract_payload)"
  rm -rf "${INSTALL_DIR}"
  mkdir -p "${INSTALL_DIR}" "${DATA_DIR}" /etc/gost
  cp -a "${src}/." "${INSTALL_DIR}/"
  python3 -m venv "${INSTALL_DIR}/venv"
  "${INSTALL_DIR}/venv/bin/python" -m pip install --upgrade pip setuptools wheel
  "${INSTALL_DIR}/venv/bin/pip" install -r "${INSTALL_DIR}/requirements.txt"
}

initialize_panel() {
  log "初始化账号、规则数据和 GOST 配置"
  GOST_PANEL_DATA="${DATA_DIR}" GOST_CONFIG="${GOST_CONFIG}" GOST_LISTEN="${GOST_LISTEN}" GOST_FALLBACK="${GOST_FALLBACK}" INIT_RULES="${INIT_RULES}" \
    "${INSTALL_DIR}/venv/bin/python" "${INSTALL_DIR}/app.py" init \
      --username "${PANEL_USER}" \
      --password "${PANEL_PASSWORD}" \
      --listen "${GOST_LISTEN}" \
      --fallback "${GOST_FALLBACK}" \
      --init-rules "${INIT_RULES}" \
      --force-auth
}

write_services() {
  log "写入 systemd 服务"
  cat > /etc/systemd/system/gost-panel.service <<EOF2
[Unit]
Description=GOST SNI Manager Web Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
Environment=GOST_PANEL_DATA=${DATA_DIR}
Environment=GOST_CONFIG=${GOST_CONFIG}
Environment=GOST_SERVICE=gost
Environment=CADDY_SERVICE=caddy
ExecStart=${INSTALL_DIR}/venv/bin/python ${INSTALL_DIR}/app.py serve --host ${PANEL_BIND} --port ${PANEL_PORT}
Restart=always
RestartSec=3
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOF2

  cat > /etc/systemd/system/gost.service <<EOF2
[Unit]
Description=GOST v3 SNI Reverse Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gost -C ${GOST_CONFIG}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF2
}

write_caddyfile() {
  log "写入 Caddy 配置"
  mkdir -p /etc/caddy
  if [[ -n "${PANEL_DOMAIN}" ]]; then
    cat > /etc/caddy/Caddyfile <<EOF2
{
    https_port ${CADDY_HTTPS_PORT}
    auto_https disable_redirects
}

https://${PANEL_DOMAIN} {
    encode zstd gzip
    reverse_proxy 127.0.0.1:${PANEL_PORT}
}

:${CADDY_HTTPS_PORT} {
    tls internal
    respond "GOST fallback OK" 200
}
EOF2
  else
    cat > /etc/caddy/Caddyfile <<EOF2
{
    https_port ${CADDY_HTTPS_PORT}
    auto_https disable_redirects
}

:${CADDY_HTTPS_PORT} {
    tls internal
    respond "GOST fallback OK" 200
}
EOF2
  fi
  caddy fmt --overwrite /etc/caddy/Caddyfile || true
}

start_services() {
  log "启动服务"
  systemctl daemon-reload
  systemctl enable --now gost-panel
  systemctl restart gost-panel
  systemctl enable --now caddy
  systemctl restart caddy
  systemctl enable --now gost
  systemctl restart gost
  # GOST 已接管 443 后，再重启一次 Caddy，便于域名证书申请流程通过 GOST fallback 到 8053。
  systemctl restart caddy || true
}

write_credentials_file() {
  log "写入登录信息到 ${CREDENTIALS_FILE}"
  install -m 0600 /dev/null "${CREDENTIALS_FILE}"
  cat > "${CREDENTIALS_FILE}" <<EOF2
GOST SNI Manager 登录信息

面板访问: ${PANEL_ACCESS_URL}
用户名: ${PANEL_USER}
密码: ${PANEL_PASSWORD}

GOST 配置文件: ${GOST_CONFIG}
面板数据目录: ${DATA_DIR}
面板内部端口: ${PANEL_PORT}
Caddy HTTPS fallback: 127.0.0.1:${CADDY_HTTPS_PORT}
GOST 监听: ${GOST_LISTEN}
未知 SNI 默认后端: ${GOST_FALLBACK}

请立即保存以上信息。此文件权限为 600，仅 root 可读。
EOF2
  chmod 0600 "${CREDENTIALS_FILE}"
}

print_summary() {
  write_credentials_file
  log "安装完成"
  echo "面板访问: ${PANEL_ACCESS_URL}"
  echo "用户名: ${PANEL_USER}"
  echo "密码: ${PANEL_PASSWORD}"
  echo "登录信息已保存: ${CREDENTIALS_FILE}"
  echo
  echo "请立即保存上面的用户名和密码。"
  if [[ -n "${PANEL_DOMAIN}" ]]; then
    echo "提示: ${PANEL_DOMAIN} 需要解析到本机公网 IP；公网 443 由 GOST 接收，未知 SNI 会转发到 Caddy:${CADDY_HTTPS_PORT}。"
    echo "如果首次访问证书还在签发，稍后重试或查看: journalctl -u caddy -f"
  else
    warn "未配置面板域名，面板直接监听 ${PANEL_BIND}:${PANEL_PORT}。建议用防火墙限制来源，或后续配置域名。"
  fi
  echo
  systemctl --no-pager --full status gost gost-panel caddy | sed -n '1,90p' || true
}

main() {
  prompt_panel_domain
  require_debian_like
  install_base_packages
  prepare_runtime_options
  cleanup_old_aurora
  install_gost
  install_caddy
  install_panel_files
  initialize_panel
  write_services
  write_caddyfile
  start_services
  print_summary
}

main "$@"
exit 0

__GOST_PANEL_ARCHIVE_BELOW__
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
tEiLROn/AA2LpdsA8AAA
