#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 root 执行：sudo bash uninstall.sh"
  exit 1
fi
systemctl stop gost-panel gsm-relay gost 2>/dev/null || true
systemctl disable gost-panel gsm-relay gost 2>/dev/null || true
rm -f /etc/systemd/system/gost-panel.service /etc/systemd/system/gsm-relay.service /etc/systemd/system/gost.service
systemctl daemon-reload
systemctl reset-failed || true
rm -rf /opt/gost-sni-manager /etc/gost-panel /etc/gost /root/gsm.txt /root/gost-panel-credentials.txt
read -r -p "是否同时删除 /usr/local/bin/gost ? [y/N] " ans || true
case "${ans:-}" in
  y|Y|yes|YES) rm -f /usr/local/bin/gost /usr/bin/gost ;;
esac
read -r -p "是否同时卸载 caddy 软件包 ? [y/N] " ans2 || true
case "${ans2:-}" in
  y|Y|yes|YES) apt-get remove -y caddy || true ;;
esac
echo "卸载完成。"
