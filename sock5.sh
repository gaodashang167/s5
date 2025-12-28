#!/bin/bash

# sing-box socks5 安装/卸载脚本 (支持纯 IPv6 环境)
# 用法：
# 安装：
#   PORT=16805 USERNAME=oneforall PASSWORD=allforone bash sock5_fixed.sh
# 卸载：
#   bash sock5_fixed.sh uninstall

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
  echo "PORT=16805 USERNAME=oneforall PASSWORD=allforone bash $0"
  exit 1
fi

echo "[INFO] 开始安装 socks5 代理服务..."
echo "[INFO] 端口: $PORT, 用户名: $USERNAME"

# ===== 检测网络环境 =====
echo "[INFO] 检测网络环境..."
HAS_IPV4=false
HAS_IPV6=false

# 检测 IPv4
if timeout 3 curl -s4 --max-time 2 icanhazip.com >/dev/null 2>&1; then
  HAS_IPV4=true
  IP_V4=$(curl -s4 --max-time 3 icanhazip.com 2>/dev/null || echo "")
fi

# 检测 IPv6
if timeout 3 curl -s6 --max-time 2 icanhazip.com >/dev/null 2>&1; then
  HAS_IPV6=true
  IP_V6=$(curl -s6 --max-time 3 icanhazip.com 2>/dev/null || echo "")
fi

if [[ "$HAS_IPV4" == false && "$HAS_IPV6" == false ]]; then
  echo "[ERROR] 无法检测到 IPv4 或 IPv6 网络连接"
  exit 1
fi

if [[ "$HAS_IPV6" == true ]]; then
  echo "[INFO] ✓ 检测到 IPv6 网络: $IP_V6"
  LISTEN_ADDR="::"
  echo "[INFO] 将监听 [::]:$PORT (IPv6)"
else
  echo "[INFO] ✓ 检测到 IPv4 网络: $IP_V4"
  LISTEN_ADDR="0.0.0.0"
  echo "[INFO] 将监听 0.0.0.0:$PORT (IPv4)"
fi

# ===== 安装依赖 =====
echo "[INFO] 检查并安装依赖..."
if command -v apt >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl tar file grep net-tools iproute2 >/dev/null 2>&1
  echo "[INFO] 依赖安装完成"
elif command -v yum >/dev/null 2>&1; then
  yum install -y curl tar file grep net-tools iproute >/dev/null 2>&1
  echo "[INFO] 依赖安装完成"
elif command -v apk >/dev/null 2>&1; then
  apk add --no-cache curl tar file grep >/dev/null 2>&1
  echo "[INFO] 依赖安装完成"
fi

# ===== 下载 sing-box =====
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR" || exit 1

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH_TYPE=amd64 ;;
  aarch64|arm64) ARCH_TYPE=arm64 ;;
  armv7*) ARCH_TYPE=armv7 ;;
  *) echo "[ERROR] 不支持的架构: $ARCH"; exit 1 ;;
esac

echo "[INFO] 获取 sing-box 最新版本..."

# 根据网络环境选择下载方式
if [[ "$HAS_IPV6" == true ]]; then
  SB_VER=$(curl -s6 --max-time 10 https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name"' | head -n1 | cut -d '"' -f4)
else
  SB_VER=$(curl -s4 --max-time 10 https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name"' | head -n1 | cut -d '"' -f4)
fi

if [[ -z "$SB_VER" ]]; then
  echo "[ERROR] 获取 sing-box 版本失败，请检查网络连接"
  echo "[INFO] 尝试使用备用方法..."
  SB_VER="v1.10.7"  # 备用版本
  echo "[WARN] 使用备用版本: $SB_VER"
fi

VERS="${SB_VER#v}"
URL="https://github.com/SagerNet/sing-box/releases/download/${SB_VER}/sing-box-${VERS}-linux-${ARCH_TYPE}.tar.gz"

echo "[INFO] 下载 sing-box ${SB_VER} for ${ARCH_TYPE}..."
echo "[INFO] 下载地址: $URL"

# 根据网络环境下载
if [[ "$HAS_IPV6" == true ]]; then
  curl -6 -L --retry 3 --retry-delay 2 --max-time 60 -o sb.tar.gz "$URL" || {
    echo "[ERROR] 下载失败，请检查网络连接或防火墙设置"
    exit 1
  }
else
  curl -4 -L --retry 3 --retry-delay 2 --max-time 60 -o sb.tar.gz "$URL" || {
    echo "[ERROR] 下载失败，请检查网络连接或防火墙设置"
    exit 1
  }
fi

echo "[INFO] 验证下载文件..."
if ! file sb.tar.gz | grep -q 'gzip compressed'; then
  echo "❌ 下载失败，文件不是有效的 gzip 格式"
  echo "[DEBUG] 文件内容前10行："
  head -n 10 sb.tar.gz
  exit 1
fi

echo "[INFO] 解压文件..."
tar -xzf sb.tar.gz --strip-components=1
chmod +x sing-box
rm -f sb.tar.gz

echo "[INFO] sing-box 二进制文件安装完成"

# ===== 生成配置文件 =====
echo "[INFO] 生成配置文件..."
cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "$LISTEN_ADDR",
      "listen_port": $PORT,
      "users": [{
        "username": "$USERNAME",
        "password": "$PASSWORD"
      }]
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

echo "[INFO] 配置文件已生成: $CONFIG_FILE"

# ===== 启动服务 =====
echo "[INFO] 启动 socks5 服务..."

# 停止可能存在的旧进程
pkill -f "sing-box run" 2>/dev/null || true

# 启动服务
nohup "$BIN_FILE" run -c "$CONFIG_FILE" > "$LOG_FILE" 2>&1 &
SING_PID=$!
echo $SING_PID > "$PID_FILE"

echo "[INFO] 服务已启动，PID: $SING_PID"
echo "[INFO] 等待服务启动..."
sleep 3

# ===== 检查进程 =====
if ! ps -p $SING_PID > /dev/null; then
  echo "❌ sing-box 进程启动失败"
  echo "[ERROR] 日志内容："
  cat "$LOG_FILE"
  exit 1
fi

echo "[INFO] ✓ sing-box 进程运行正常"

# ===== 检查端口监听 =====
echo "[INFO] 检查端口监听状态..."
sleep 2

LISTEN_CHECK=false
for i in {1..5}; do
  if command -v ss >/dev/null 2>&1; then
    if ss -tlnp | grep -q ":$PORT"; then
      LISTEN_CHECK=true
      LISTEN_INFO=$(ss -tlnp | grep ":$PORT")
      break
    fi
  elif command -v netstat >/dev/null 2>&1; then
    if netstat -tlnp | grep -q ":$PORT"; then
      LISTEN_CHECK=true
      LISTEN_INFO=$(netstat -tlnp | grep ":$PORT")
      break
    fi
  fi
  echo "[INFO] 等待端口监听... ($i/5)"
  sleep 2
done

if [[ "$LISTEN_CHECK" == false ]]; then
  echo "❌ 端口 $PORT 没有监听成功"
  echo "[ERROR] 最近20行日志："
  tail -n 20 "$LOG_FILE"
  exit 1
fi

echo "[INFO] ✓ 端口监听成功："
echo "$LISTEN_INFO"

# ===== 测试代理连接 =====
echo "[INFO] 测试代理连接..."

if [[ "$HAS_IPV6" == true ]]; then
  # 纯 IPv6 环境测试
  if curl -s6 --socks5-hostname "[::1]:$PORT" -U "$USERNAME:$PASSWORD" --max-time 10 http://ip.sb >/dev/null 2>&1; then
    echo "✅ IPv6 代理连接测试成功"
    TEST_RESULT=$(curl -s6 --socks5-hostname "[::1]:$PORT" -U "$USERNAME:$PASSWORD" --max-time 10 http://ip.sb)
    echo "[INFO] 通过代理访问的出口 IP: $TEST_RESULT"
  else
    echo "⚠️ IPv6 代理连接测试失败，但服务已启动"
    echo "[WARN] 请手动测试: curl -6 --socks5-hostname '[::1]:$PORT' -U '$USERNAME:$PASSWORD' http://ip.sb"
  fi
else
  # IPv4 环境测试
  if curl -s4 --socks5-hostname "127.0.0.1:$PORT" -U "$USERNAME:$PASSWORD" --max-time 10 http://ip.sb >/dev/null 2>&1; then
    echo "✅ IPv4 代理连接测试成功"
  else
    echo "⚠️ IPv4 代理连接测试失败，但服务已启动"
  fi
fi

# ===== 输出连接信息 =====
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Socks5 代理服务安装成功！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [[ "$HAS_IPV6" == true ]]; then
  echo "📡 连接信息 (IPv6):"
  echo "   socks5://$USERNAME:$PASSWORD@[$IP_V6]:$PORT"
  echo ""
  echo "🔧 配置参数:"
  echo "   服务器: $IP_V6"
  echo "   端口: $PORT"
  echo "   用户名: $USERNAME"
  echo "   密码: $PASSWORD"
  echo "   协议: SOCKS5"
else
  echo "📡 连接信息 (IPv4):"
  echo "   socks5://$USERNAME:$PASSWORD@$IP_V4:$PORT"
  echo ""
  echo "🔧 配置参数:"
  echo "   服务器: $IP_V4"
  echo "   端口: $PORT"
  echo "   用户名: $USERNAME"
  echo "   密码: $PASSWORD"
  echo "   协议: SOCKS5"
fi

echo ""
echo "📝 管理命令:"
echo "   查看日志: tail -f $LOG_FILE"
echo "   停止服务: kill \$(cat $PID_FILE)"
echo "   卸载服务: bash $0 uninstall"
echo ""
echo "⚠️  防火墙提醒:"
echo "   请确保服务器防火墙已开放 TCP $PORT 端口"
if [[ "$HAS_IPV6" == true ]]; then
  echo "   ip6tables -I INPUT -p tcp --dport $PORT -j ACCEPT"
else
  echo "   iptables -I INPUT -p tcp --dport $PORT -j ACCEPT"
fi
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit 0
