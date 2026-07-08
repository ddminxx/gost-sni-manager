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
RELAY_SERVICE="${RELAY_SERVICE:-gsm-relay}"
GOST_FORWARD_MODE="${GOST_FORWARD_MODE:-direct}"

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
  apt-get -qq update
  apt-get install -y -qq --no-install-recommends ca-certificates curl tar gzip openssl python3 python3-venv systemd iproute2
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

detect_asset_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7*) echo "armv7" ;;
    armv6l|armv6*) echo "armv6" ;;
    *) die "暂不支持的 CPU 架构：$(uname -m)" ;;
  esac
}

install_gost() {
  log "安装或升级 GOST v3"
  local version="${GOST_VERSION:-3.2.6}"
  local arch tarball url tmp
  arch="$(detect_asset_arch)"
  tmp="$(mktemp -d)"
  tarball="gost_${version}_linux_${arch}.tar.gz"
  url="https://github.com/go-gost/gost/releases/download/v${version}/${tarball}"
  curl -fsSL -o "${tmp}/${tarball}" "${url}"
  tar -xzf "${tmp}/${tarball}" -C "${tmp}"
  install -m 0755 "${tmp}/gost" /usr/local/bin/gost
  ln -sf /usr/local/bin/gost /usr/bin/gost
  rm -rf "${tmp}"
  /usr/local/bin/gost -V || true
}

install_caddy_binary() {
  local version="${CADDY_VERSION:-2.10.2}"
  local arch tarball url tmp
  arch="$(detect_asset_arch)"
  tmp="$(mktemp -d)"
  tarball="caddy_${version}_linux_${arch}.tar.gz"
  url="https://github.com/caddyserver/caddy/releases/download/v${version}/${tarball}"
  curl -fsSL -o "${tmp}/${tarball}" "${url}"
  tar -xzf "${tmp}/${tarball}" -C "${tmp}" caddy
  install -m 0755 "${tmp}/caddy" /usr/bin/caddy
  rm -rf "${tmp}"
  mkdir -p /etc/caddy /var/lib/caddy /var/log/caddy
  if [[ ! -f /etc/systemd/system/caddy.service && ! -f /usr/lib/systemd/system/caddy.service && ! -f /lib/systemd/system/caddy.service ]]; then
    cat > /etc/systemd/system/caddy.service <<'EOF2'
[Unit]
Description=Caddy
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF2
  fi
}

install_caddy() {
  log "安装 Caddy"
  if ! command -v caddy >/dev/null 2>&1; then
    rm -f /etc/apt/sources.list.d/caddy-stable.list /etc/apt/sources.list.d/caddy*.list /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || true
    if ! apt-get install -y -qq --no-install-recommends caddy; then
      warn "系统仓库未能安装 Caddy，改用 GitHub 二进制安装。"
      install_caddy_binary
    fi
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
  "${INSTALL_DIR}/venv/bin/python" -m pip install -q --upgrade pip setuptools wheel
  "${INSTALL_DIR}/venv/bin/pip" install -q -r "${INSTALL_DIR}/requirements.txt"
}

initialize_panel() {
  log "初始化账号、规则数据和 GOST 配置"
  GOST_PANEL_DATA="${DATA_DIR}" GOST_CONFIG="${GOST_CONFIG}" GOST_LISTEN="${GOST_LISTEN}" GOST_FALLBACK="${GOST_FALLBACK}" INIT_RULES="${INIT_RULES}" \
    "${INSTALL_DIR}/venv/bin/python" "${INSTALL_DIR}/app.py" init \
      --username "${PANEL_USER}" \
      --password "${PANEL_PASSWORD}" \
      --listen "${GOST_LISTEN}" \
      --fallback "${GOST_FALLBACK}" \
      --panel-domain "${PANEL_DOMAIN}" \
      --init-rules "${INIT_RULES}" \
      --mode "${GOST_FORWARD_MODE}" \
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

  cat > /etc/systemd/system/gsm-relay.service <<EOF2
[Unit]
Description=GOST SNI Manager Local Relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
Environment=GOST_PANEL_DATA=${DATA_DIR}
Environment=GOST_PANEL_DB=${DATA_DIR}/gsm.db
ExecStart=${INSTALL_DIR}/venv/bin/python ${INSTALL_DIR}/relay.py
Restart=always
RestartSec=3
LimitNOFILE=1048576

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
  if [[ "${GOST_FORWARD_MODE}" == "carpool" ]]; then
    systemctl enable --now gsm-relay
    systemctl restart gsm-relay
  else
    systemctl disable --now gsm-relay >/dev/null 2>&1 || true
  fi
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
默认运行模式: 自用模式（GOST 直连目标，gsm-relay 默认不启动）
拼车模式中继服务: gsm-relay.service
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

__GSM_PAYLOAD_START__
