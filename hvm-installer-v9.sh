#!/usr/bin/env bash
# HVM Panel improved installer
# Usage: sudo ./hvm-installer-v9.sh [install|update|uninstall|status]
# Optional env vars:
#   HVM_URL        zip download URL
#   HVM_SHA256     expected sha256 of the zip (recommended)
#   PANEL_PORT     default 5000
#   ALLOW_IP       only allow this IP/CIDR (IPv4 or IPv6) through the firewall
#   HVM_ZIP        path to a local zip (use this on IPv6-only VPS, since github.com has no IPv6)
#   BIND_V6        set to 1 to patch hvm.py to listen on :: (IPv6 + IPv4 dual-stack)

set -Eeuo pipefail

HVM_URL="${HVM_URL:-https://github.com/user-attachments/files/31306142/hvm-working-20260821_111531.zip}"
HVM_SHA256="${HVM_SHA256:-}"
PANEL_PORT="${PANEL_PORT:-5000}"
ALLOW_IP="${ALLOW_IP:-}"
HVM_ZIP="${HVM_ZIP:-}"
BIND_V6="${BIND_V6:-1}"

INSTALL_DIR="/opt/hvm"
APP_DIR="${INSTALL_DIR}/hvm"
APP_FILE="${APP_DIR}/hvm.py"
VENV_DIR="${INSTALL_DIR}/venv"
BACKUP_DIR="${INSTALL_DIR}/backups"
SERVICE="hvm"
LOG_FILE="/var/log/hvm.log"

C_R="\e[1;31m"; C_G="\e[1;32m"; C_Y="\e[1;33m"; C_C="\e[1;36m"; NC="\e[0m"
info() { echo -e "${C_C}[INFO]${NC} $*"; }
ok()   { echo -e "${C_G}[OK]${NC} $*"; }
warn() { echo -e "${C_Y}[WARN]${NC} $*"; }
err()  { echo -e "${C_R}[ERROR]${NC} $*" >&2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
trap 'err "Failed at line $LINENO. See output above."' ERR

need_root() { [[ $EUID -eq 0 ]] || { err "Run as root."; exit 1; }; }

install_deps() {
  info "Installing system dependencies..."
  local pkgs_common="curl unzip lsof ca-certificates"
  if command -v apt-get >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y $pkgs_common python3 python3-pip python3-venv
  elif command -v dnf >/dev/null; then
    dnf install -y $pkgs_common python3 python3-pip
  elif command -v yum >/dev/null; then
    yum install -y $pkgs_common python3 python3-pip
  elif command -v pacman >/dev/null; then
    pacman -Sy --noconfirm $pkgs_common python python-pip
  elif command -v apk >/dev/null; then
    apk add $pkgs_common python3 py3-pip
  elif command -v zypper >/dev/null; then
    zypper install -y $pkgs_common python3 python3-pip
  else
    err "Unsupported distribution."; exit 1
  fi
}

download_zip() {
  if [[ -n "$HVM_ZIP" ]]; then
    [[ -f "$HVM_ZIP" ]] || { err "HVM_ZIP file not found: $HVM_ZIP"; exit 1; }
    cp "$HVM_ZIP" "$TMP/hvm.zip"
    info "Using local zip: $HVM_ZIP"
  else
    info "Downloading HVM zip..."
    if ! curl -fL --retry 3 --retry-delay 3 --progress-bar -o "$TMP/hvm.zip" "$HVM_URL"; then
      err "Download failed."
      if ! curl -4 -s --max-time 5 -o /dev/null https://github.com; then
        warn "This VPS looks IPv6-only and github.com has no IPv6 address."
        warn "Fix: download the zip on another machine, scp it to this VPS, then run:"
        warn "  sudo HVM_ZIP=/root/hvm.zip $0 install"
        warn "Or enable NAT64/DNS64 (e.g. set resolver to 2a00:1098:2b::1 / 2a01:4f8:c2c:123f::1)."
      fi
      exit 1
    fi
  fi
  if [[ -n "$HVM_SHA256" ]]; then
    echo "${HVM_SHA256}  $TMP/hvm.zip" | sha256sum -c - || { err "Checksum mismatch."; exit 1; }
    ok "Checksum verified."
  else
    warn "No HVM_SHA256 set, zip is NOT verified. SHA256: $(sha256sum "$TMP/hvm.zip" | cut -d' ' -f1)"
  fi
  unzip -tq "$TMP/hvm.zip" >/dev/null || { err "Invalid zip."; exit 1; }
}

backup_existing() {
  if [[ -d "$APP_DIR" ]]; then
    mkdir -p "$BACKUP_DIR"
    local f="${BACKUP_DIR}/hvm-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "$f" -C "$INSTALL_DIR" hvm
    ok "Backup saved: $f"
    # keep the 5 newest backups
    ls -1t "$BACKUP_DIR"/hvm-*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm -f
  fi
}

deploy_app() {
  mkdir -p "$INSTALL_DIR"
  unzip -q "$TMP/hvm.zip" -d "$TMP/x"
  [[ -f "$TMP/x/hvm/hvm.py" ]] || { err "hvm/hvm.py not found in zip."; exit 1; }
  [[ -f "$TMP/x/hvm/requirements.txt" ]] || { err "requirements.txt not found."; exit 1; }

  # preserve user data on update
  local keep="$TMP/keep"; mkdir -p "$keep"
  for p in data database db instance uploads config.json .env *.db *.sqlite *.sqlite3; do
    for f in "$APP_DIR"/$p; do
      [[ -e "$f" ]] && cp -a "$f" "$keep/" || true
    done
  done

  systemctl stop "$SERVICE" 2>/dev/null || true
  rm -rf "$APP_DIR"
  mv "$TMP/x/hvm" "$APP_DIR"
  cp -a "$keep"/. "$APP_DIR"/ 2>/dev/null || true
  ok "Application deployed."
  bind_ipv6
}

bind_ipv6() {
  [[ "$BIND_V6" == "1" ]] || return 0
  if grep -qE "0\.0\.0\.0" "$APP_FILE"; then
    sed -i "s/0\.0\.0\.0/::/g" "$APP_FILE"
    ok "Patched hvm.py to listen on :: (works for IPv6 and IPv4)."
  else
    warn "No 0.0.0.0 found in hvm.py. Check how the app binds (host=...) and make sure it listens on '::'."
  fi
}

setup_venv() {
  info "Setting up Python environment..."
  [[ -x "$VENV_DIR/bin/python" ]] || python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/python" -m pip install --upgrade pip -q
  "$VENV_DIR/bin/python" -m pip install -r "$APP_DIR/requirements.txt" -q
  [[ -f "$APP_DIR/bot/requirements.txt" ]] && \
    "$VENV_DIR/bin/python" -m pip install -r "$APP_DIR/bot/requirements.txt" -q || true
  ok "Python dependencies installed."
}

setup_firewall() {
  info "Configuring firewall..."
  local fam="ipv4"; [[ "$ALLOW_IP" == *:* ]] && fam="ipv6"
  if command -v ufw >/dev/null; then
    if [[ -n "$ALLOW_IP" ]]; then
      ufw allow from "$ALLOW_IP" to any port "$PANEL_PORT" proto tcp >/dev/null 2>&1 || true
    else
      ufw allow "${PANEL_PORT}/tcp" >/dev/null 2>&1 || true   # covers v4 and v6
    fi
  elif command -v firewall-cmd >/dev/null; then
    if [[ -n "$ALLOW_IP" ]]; then
      firewall-cmd --permanent --add-rich-rule="rule family=${fam} source address=${ALLOW_IP} port port=${PANEL_PORT} protocol=tcp accept" >/dev/null 2>&1 || true
    else
      firewall-cmd --permanent --add-port="${PANEL_PORT}/tcp" >/dev/null 2>&1 || true
    fi
    firewall-cmd --reload >/dev/null 2>&1 || true
  elif command -v ip6tables >/dev/null; then
    ip6tables -C INPUT -p tcp --dport "$PANEL_PORT" -j ACCEPT 2>/dev/null || \
      ip6tables -I INPUT -p tcp --dport "$PANEL_PORT" -j ACCEPT || true
  fi
  [[ -z "$ALLOW_IP" ]] && warn "Panel port is open to everyone. Re-run with ALLOW_IP=<your ip> to restrict it."
  warn "Also check your VPS provider's cloud firewall allows TCP ${PANEL_PORT} over IPv6."
}

setup_service() {
  info "Creating systemd service..."
  cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=HVM Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
ExecStart=${VENV_DIR}/bin/python ${APP_FILE}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
Environment=PYTHONUNBUFFERED=1
Environment=PORT=${PANEL_PORT}
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/logrotate.d/hvm <<EOF
${LOG_FILE} {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
}
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null 2>&1
  systemctl restart "$SERVICE"
}

health_check() {
  info "Waiting for panel to respond..."
  for _ in $(seq 1 30); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://[::1]:${PANEL_PORT}/" || true)"
    [[ "$code" == "000" ]] && code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${PANEL_PORT}/" || true)"
    if [[ "$code" =~ ^(200|301|302|303|307|308|401|403)$ ]]; then
      ok "Panel is responding (HTTP $code)."
      return 0
    fi
    sleep 2
  done
  err "Panel did not respond. Last log lines:"
  tail -n 40 "$LOG_FILE" 2>/dev/null || true
  exit 1
}

summary() {
  local ip6 ip4
  ip6="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 | head -n1)"
  ip4="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"
  local url
  if [[ -n "$ip6" ]]; then url="http://[${ip6}]:${PANEL_PORT}"; elif [[ -n "$ip4" ]]; then url="http://${ip4}:${PANEL_PORT}"; else url="http://YOUR_SERVER_IP:${PANEL_PORT}"; fi
  cat <<EOF

================ HVM PANEL READY ================
URL      : ${url}
Note     : IPv6 URLs need [brackets]; your PC/ISP must also have IPv6 to reach it.
Login    : admin / admin  <-- CHANGE THIS IMMEDIATELY
Logs     : journalctl -u ${SERVICE} -f   (or ${LOG_FILE})
Restart  : systemctl restart ${SERVICE}
Update   : sudo $0 update
Backups  : ${BACKUP_DIR}
=================================================
EOF
}

port_check() {
  if lsof -Pi ":${PANEL_PORT}" -sTCP:LISTEN -t >/dev/null 2>&1 && ! systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    err "Port ${PANEL_PORT} is used by another process. Set PANEL_PORT to something else."
    exit 1
  fi
}

do_install() {
  need_root; install_deps; port_check; download_zip
  backup_existing; deploy_app; setup_venv; setup_firewall; setup_service
  health_check; summary
}

do_update() {
  need_root; [[ -d "$APP_DIR" ]] || { err "Not installed."; exit 1; }
  download_zip; backup_existing; deploy_app; setup_venv; setup_service
  health_check; ok "Updated."
}

do_uninstall() {
  need_root
  read -rp "Remove HVM (a backup is kept in ${BACKUP_DIR}.bak)? (y/N): " a
  [[ "$a" == "y" ]] || exit 0
  backup_existing
  systemctl disable --now "$SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE}.service" /etc/logrotate.d/hvm
  systemctl daemon-reload
  [[ -d "$BACKUP_DIR" ]] && mv "$BACKUP_DIR" "${BACKUP_DIR}.bak" 2>/dev/null || true
  rm -rf "$APP_DIR" "$VENV_DIR"
  ok "Uninstalled."
}

do_status() {
  systemctl status "$SERVICE" --no-pager -l || true
  tail -n 30 "$LOG_FILE" 2>/dev/null || true
}

case "${1:-install}" in
  install)   do_install ;;
  update)    do_update ;;
  uninstall) do_uninstall ;;
  status)    do_status ;;
  *) echo "Usage: $0 [install|update|uninstall|status]"; exit 1 ;;
esac
