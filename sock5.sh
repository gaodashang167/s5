#!/bin/bash

# sing-box socks5 安装/卸载脚本 (真正支持 IPv4/IPv6 双栈)
# 用法：
# 安装：
#   PORT=16805 USERNAME=oneforall PASSWORD=allforone bash <(curl -Ls https://你的URL/sock5.sh)
#   说明：监听 :: 以真正实现 IPv4/IPv6 双栈兼容
# 卸载：
#   bash <(curl -Ls https://你的URL/sock5.sh) uninstall

set -euo pipefail

INSTALL_DIR="/usr/local/sb"
CONFIG_FILE="$INSTALL_DIR/config.json"
BIN_FILE="$INSTALL_DIR/sing-box"
LOG_FILE="$INSTALL_DIR/run.log"
PID_FILE="$INSTALL_DIR/sb.pid"

# ===== 卸载逻辑 =====
if [[ "${1:-}" == "uninstall" ]]; then
  echo "[INFO] 停止 socks5 服务..."
  pkill -f "sing-box run" || true
  if [[ -f "$PID_FILE" ]]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f "$PID_FILE"
  fi
  echo "[INFO] 删除安装目录 $INSTALL_DIR"
  rm -rf "$INSTALL_DIR"
  echo "✅ socks5 卸载完成。"
  exit 0
fi

# ===== 环境变量检查 =====
if [[ -z "${PORT:-}" || -z "${USERNAME:-}" || -z "${PASSWORD:-}" ]]; then
  echo "[ERROR] 必须设置 PORT、USERNAME、PASSWORD 变量，例如："
  echo "PORT=16805 USERNAME=oneforall PASSWORD=allforone bash <(curl -Ls https://你的URL/sock5.sh)"
  exit 1
fi

# ===== 检测 LXC/Docker 容器环境 =====
if grep -qaE 'lxc|docker' /proc/1/environ 2>/dev/null || grep -qaE 'lxc' /proc/1/cgroup 2>/dev/null; then
  echo "[WARN] 检测到可能运行在 LXC/Docker 容器中，请确保容器网络配置允许外部访问端口 $PORT"
fi

# ===== 获取公网 IP =====
echo "[INFO] 获取公网 IP..."
IP_V4=$(timeout 5 curl -s4 ipv4.ip.sb 2>/dev/null || timeout 5 curl -s4 ifconfig.me 2>/dev/null || echo "")
IP_V6=$(timeout 5 curl -s6 ipv6.ip.sb 2>/dev/null || echo "")

if [[ -n "$IP_V4" ]]; then
  echo "[INFO] 公网 IPv4: $IP_V4"
else
  echo "[INFO] 未检测到 IPv4 地址"
fi

if [[ -n "$IP_V6" ]]; then
  echo "[INFO] 公网 IPv6: $IP_V6"
else
  echo "[INFO] 未检测到 IPv6 地址"
fi

# ===== 安装依赖 =====
echo "[INFO] 安装依赖 curl tar unzip file grep ..."
if command -v apk >/dev/null 2>&1; then
  apk update
  apk add --no-cache curl tar unzip file grep
elif command -v apt >/dev/null 2>&1; then
  apt update
  apt install -y curl tar unzip file grep net-tools iproute2
elif command -v yum >/dev/null 2>&1; then
  yum install -y curl tar unzip file grep net-tools iproute
else
  echo "[WARN] 未检测到已知包管理器，请确保 curl tar unzip file grep 已安装"
fi

# ===== 下载 sing-box =====
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR" || exit 1

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH_TYPE=amd64 ;;
  aarch64 | arm64) ARCH_TYPE=arm64 ;;
  *) echo "[ERROR] 不支持的架构: $ARCH"; exit 1 ;;
esac

echo "[INFO] 获取 sing-box 最新版本..."
SB_VER=$(timeout 10 curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | grep '"tag_name"' | head -n1 | cut -d '"' -f4 || echo "")

if [[ -z "$SB_VER" ]]; then
  echo "[WARN] 无法获取最新版本，使用固定版本 v1.10.7"
  SB_VER="v1.10.7"
fi

echo "[INFO] 将安装版本: $SB_VER"

VERS="${SB_VER#v}"
URL="https://github.com/SagerNet/sing-box/releases/download/${SB_VER}/sing-box-${VERS}-linux-${ARCH_TYPE}.tar.gz"

echo "[INFO] 下载 sing-box: $URL"
curl -L --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 120 -o sb.tar.gz "$URL"

if ! file sb.tar.gz | grep -q 'gzip compressed'; then
  echo "❌ 下载失败，文件不是有效的 gzip 格式。内容如下："
  head -n 10 sb.tar.gz
  exit 1
fi

tar -xzf sb.tar.gz --strip-components=1
chmod +x sing-box
rm -f sb.tar.gz

# ===== 生成配置文件（关键修复：使用 :: 而不是 0.0.0.0）=====
cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "::",
      "listen_port": $PORT,
      "users": [{
        "username": "$USERNAME",
        "password": "$PASSWORD"
      }]
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    }
  ]
}
EOF

# ===== 启动服务 =====
echo "[INFO] 启动 socks5 服务..."
nohup "$BIN_FILE" run -c "$CONFIG_FILE" > "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"

sleep 4

# ===== 检查端口监听 =====
echo "[INFO] 检查端口监听状态..."

if command -v ss >/dev/null 2>&1; then
  LISTEN_INFO=$(ss -tnlp | grep ":$PORT" || true)
elif command -v netstat >/dev/null 2>&1; then
  LISTEN_INFO=$(netstat -tnlp | grep ":$PORT" || true)
else
  LISTEN_INFO=""
fi

if [[ -z "$LISTEN_INFO" ]]; then
  echo "❌ 端口 $PORT 没有监听，请查看日志：$LOG_FILE"
  tail -n 20 "$LOG_FILE"
  exit 1
fi

echo "[INFO] 端口监听信息："
echo "$LISTEN_INFO"

# ===== 本地连接测试 =====
echo "[INFO] 测试本地 socks5 代理连接..."

# 测试 IPv4 连接
if timeout 5 curl -s --socks5-hostname "127.0.0.1:$PORT" -U "$USERNAME:$PASSWORD" http://ip.sb >/dev/null 2>&1; then
  echo "✅ 本地 IPv4 代理连接测试成功"
else
  echo "⚠️ 本地 IPv4 代理连接测试失败"
fi

# 测试 IPv6 连接
if [[ -n "$IP_V6" ]]; then
  if timeout 5 curl -s --socks5-hostname "[::1]:$PORT" -U "$USERNAME:$PASSWORD" http://ip.sb >/dev/null 2>&1; then
    echo "✅ 本地 IPv6 代理连接测试成功"
  else
    echo "⚠️ 本地 IPv6 代理连接测试失败"
  fi
fi

# ===== 防火墙提示 =====
echo
echo "⚠️ 请确保服务器防火墙或云安全组已开放端口 $PORT 的 TCP 入站规则。"
echo "示例（iptables 放行端口命令）："
echo "iptables -I INPUT -p tcp --dport $PORT -j ACCEPT"
echo "ip6tables -I INPUT -p tcp --dport $PORT -j ACCEPT"
echo

# ===== 输出连接信息 =====
echo "✅ Socks5 启动成功："

if [[ -n "$IP_V4" ]]; then
  echo "socks5://$USERNAME:$PASSWORD@$IP_V4:$PORT (IPv4)"
fi

if [[ -n "$IP_V6" ]]; then
  echo "socks5://$USERNAME:$PASSWORD@[$IP_V6]:$PORT (IPv6)"
fi

echo
echo "💡 使用说明："
echo "  - 监听地址: :::$PORT (真正的 IPv4/IPv6 双栈)"
echo "  - 用户名: $USERNAME"
echo "  - 密码: $PASSWORD"
echo
echo "💾 管理命令:"
echo "  - 查看日志: tail -f $LOG_FILE"
echo "  - 查看状态: ps aux | grep sing-box"
echo "  - 停止服务: kill \$(cat $PID_FILE)"
echo "  - 卸载服务: bash <(curl -Ls https://你的URL/sock5.sh) uninstall"

exit 0
