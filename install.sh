#!/usr/bin/env bash
set -Eeuo pipefail

# GOST SNI Manager one-key installer for Debian/Ubuntu.
# It installs GOST v3, Caddy, and a lightweight web panel that manages SNI-based TCP forwarding.

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
    echo "- 配置域名：脚本会写入 Caddy，访问 https://你的域名/，并自动申请证书。"
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
  awk '/^: <<'\''__GSM_PAYLOAD_START__'\''$/ {found=1; next} found && /^__GSM_PAYLOAD_START__$/ {exit} found {print}' "${BASH_SOURCE[0]}" | base64 -d | tar -xz -C "${tmp_dir}"
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
ExecStart=${INSTALL_DIR}/venv/bin/gunicorn --workers 1 --threads 4 --bind ${PANEL_BIND}:${PANEL_PORT} wsgi:app
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
    skip_install_trust
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
    skip_install_trust
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
  systemctl restart caddy || true
}

write_credentials_file() {
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
  echo "请立即保存上面的用户名和密码。"
  if [[ -n "${PANEL_DOMAIN}" ]]; then
    echo "提示: ${PANEL_DOMAIN} 需要解析到本机公网 IP；公网 443 由 GOST 接收，未知 SNI 会转发到 Caddy:${CADDY_HTTPS_PORT}。"
    echo "如果首次访问证书还在签发，稍后重试或查看: journalctl -u caddy -f"
  else
    warn "未配置面板域名，面板直接监听 ${PANEL_BIND}:${PANEL_PORT}。建议用防火墙限制来源，或后续配置域名。"
  fi
}

main() {
  prompt_panel_domain
  require_debian_like
  install_base_packages
  prepare_runtime_options
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

: <<'__GSM_PAYLOAD_START__'
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
aAEA
__GSM_PAYLOAD_START__
