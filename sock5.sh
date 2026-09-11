#!/bin/bash
set -euo pipefail

INSTALL_DIR="/usr/local/sb"
CONFIG_FILE="$INSTALL_DIR/config.json"
BIN_FILE="$INSTALL_DIR/sing-box"
SERVICE_NAME="sing-box-socks5.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
SB_VER="${SB_VER:-v1.12.0}"

log() { printf '[INFO] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请使用 root 用户运行"

if [[ "${1:-}" == "uninstall" ]]; then
  log "停止并删除服务"
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload
  rm -rf "$INSTALL_DIR"
  printf 'Socks5 已卸载。\n'
  exit 0
fi

[[ -n "${PORT:-}" && -n "${USERNAME:-}" && -n "${PASSWORD:-}" ]] || \
  die "必须设置 PORT、USERNAME、PASSWORD"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "PORT 必须是整数"
(( PORT >= 1 && PORT <= 65535 )) || die "PORT 必须在 1-65535 之间"
[[ ${#USERNAME} -le 128 ]] || die "USERNAME 不能超过 128 字符"
[[ ${#PASSWORD} -le 256 ]] || die "PASSWORD 不能超过 256 字符"

install_dependencies() {
  local missing=()
  local cmd

  for cmd in curl tar python3 systemctl; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  (( ${#missing[@]} == 0 )) && return 0

  log "检测到缺少依赖: ${missing[*]}，正在自动安装..."

  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl tar python3
  elif command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends curl tar python3 ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl tar python3 ca-certificates
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl tar python3 ca-certificates
  else
    die "未识别到受支持的包管理器，无法自动安装: ${missing[*]}"
  fi

  for cmd in curl tar python3 systemctl; do
    command -v "$cmd" >/dev/null 2>&1 || die "依赖自动安装后仍不可用: $cmd"
  done
}

install_dependencies

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "不支持的架构: $(uname -m)" ;;
esac

VERSION="${SB_VER#v}"
ARCHIVE="sing-box-${VERSION}-linux-${ARCH}.tar.gz"
URL="https://github.com/SagerNet/sing-box/releases/download/${SB_VER}/${ARCHIVE}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

log "下载 sing-box $SB_VER"
curl --fail --location --proto '=https' --tlsv1.2 \
  --retry 3 --connect-timeout 10 --max-time 180 \
  --output "$TMP_DIR/$ARCHIVE" "$URL"
tar -tzf "$TMP_DIR/$ARCHIVE" >/dev/null || die "下载包校验失败"
tar -xzf "$TMP_DIR/$ARCHIVE" -C "$TMP_DIR"
SOURCE_BIN="$(find "$TMP_DIR" -type f -name sing-box -print -quit)"
[[ -n "$SOURCE_BIN" ]] || die "压缩包内未找到 sing-box"

install -d -m 0750 "$INSTALL_DIR"
install -m 0755 "$SOURCE_BIN" "$BIN_FILE"

export CONFIG_FILE PORT USERNAME PASSWORD
python3 <<'PY'
import json
import os

config = {
    "log": {"level": "info", "timestamp": True},
    "inbounds": [{
        "type": "socks",
        "tag": "socks-in",
        "listen": "::",
        "listen_port": int(os.environ["PORT"]),
        "users": [{
            "username": os.environ["USERNAME"],
            "password": os.environ["PASSWORD"],
        }],
    }],
    "outbounds": [{"type": "direct", "tag": "direct"}],
}
with open(os.environ["CONFIG_FILE"], "w", encoding="utf-8") as f:
    json.dump(config, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
chmod 0600 "$CONFIG_FILE"

"$BIN_FILE" check -c "$CONFIG_FILE" || die "sing-box 配置检查失败"

cat >"$SERVICE_FILE" <<'EOF'
[Unit]
Description=Sing-box SOCKS5 service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sb/sing-box run -c /usr/local/sb/config.json
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/usr/local/sb

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"
sleep 1
if ! systemctl is-active --quiet "$SERVICE_NAME"; then
  systemctl status "$SERVICE_NAME" --no-pager -l || true
  journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
  die "服务启动失败"
fi

printf '\nSocks5 安装成功。\n'
printf '端口: %s\n用户名: %s\n' "$PORT" "$USERNAME"
printf '密码已写入 %s，不在终端回显。\n' "$CONFIG_FILE"
printf '状态: systemctl status %s\n' "$SERVICE_NAME"
printf '日志: journalctl -u %s -f\n' "$SERVICE_NAME"
printf '提示: :: 是否同时接受 IPv4 取决于系统 net.ipv6.bindv6only 设置。\n'
