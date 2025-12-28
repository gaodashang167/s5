#!/bin/bash

# sing-box socks5 安装/卸载脚本 (支持纯 IPv6 环境)
# 用法：
# 安装：
#   PORT=16805 USERNAME=oneforall PASSWORD=allforone bash sock5_fixed.sh
# 卸载：
#   bash sock5_fixed.sh uninstall

set -e  # 遇到错误立即退出

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
IP_V4=""
IP_V6=""

# 检测 IPv4
if timeout 3 curl -s4 --max-time 2 icanhazip.com >/dev/null 2>&1; then
  HAS_IPV4=true
  IP_V4=$(curl -s4 --max-time 3 icanhazip.com 2>/dev/null || echo "")
  echo "[INFO] ✓ 检测到 IPv4: $IP_V4"
fi

# 检测 IPv6
if timeout 3 curl -s6 --max-time 2 icanhazip.com >/dev/null 2>&1; then
  HAS_IPV6=true
  IP_V6=$(curl -s6 --max-time 3 icanhazip.com 2>/dev/null || echo "")
  echo "[INFO] ✓ 检测到 IPv6: $IP_V6"
fi

if [[ "$HAS_IPV4" == false && "$HAS_IPV6" == false ]]; then
  echo "[ERROR] 无法检测到 IPv4 或 IPv6 网络连接"
  exit 1
fi

# 设置监听地址
if [[ "$HAS_IPV6" == true ]]; then
  LISTEN_ADDR="::"
  echo "[INFO] 将监听 [::]:$PORT (IPv6)"
else
  LISTEN_ADDR="0.0.0.0"
  echo "[INFO] 将监听 0.0.0.0:$PORT (IPv4)"
fi

# ===== 安装依赖 =====
echo "[INFO] 检查并安装依赖..."
if command -v apt >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1
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

echo "[INFO] 系统架构: $ARCH -> $ARCH_TYPE"
echo "[INFO] 获取 sing-box 最新版本..."

# 获取版本号
SB_VER=""
if [[ "$HAS_IPV6" == true ]]; then
  echo "[DEBUG] 使用 IPv6 获取版本信息..."
  SB_VER=$(curl -s6 --max-time 15 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | grep '"tag_name"' | head -n1 | cut -d '"' -f4 || echo "")
else
  echo "[DEBUG] 使用 IPv4 获取版本信息..."
  SB_VER=$(curl -s4 --max-time 15 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | grep '"tag_name"' | head -n1 | cut -d '"' -f4 || echo "")
fi

if [[ -z "$SB_VER" ]]; then
  echo "[WARN] 无法从 GitHub API 获取版本，使用固定版本"
  SB_VER="v1.10.7"
fi

echo "[INFO] 将下载版本: $SB_VER"

VERS="${SB_VER#v}"
URL="https://github.com/SagerNet/sing-box/releases/download/${SB_VER}/sing-box-${VERS}-linux-${ARCH_TYPE}.tar.gz"

echo "[INFO] 下载地址: $URL"
echo "[INFO] 开始下载 sing-box..."

# 下载文件
DOWNLOAD_SUCCESS=false
if [[ "$HAS_IPV6" == true ]]; then
  echo "[DEBUG] 使用 IPv6 下载..."
  if curl -6 -L --retry 3 --retry-delay 2 --max-time 120 --progress-bar -o sb.tar.gz "$URL" 2>&1; then
    DOWNLOAD_SUCCESS=true
  fi
else
  echo "[DEBUG] 使用 IPv4 下载..."
  if curl -4 -L --retry 3 --retry-delay 2 --max-time 120 --progress-bar -o sb.tar.gz "$URL" 2>&1; then
    DOWNLOAD_SUCCESS=true
  fi
fi

if [[ "$DOWNLOAD_SUCCESS" == false ]]; then
  echo "[ERROR] 下载失败"
  if [[ -f sb.tar.gz ]]; then
    echo "[DEBUG] 文件大小: $(ls -lh sb.tar.gz | awk '{print $5}')"
    echo "[DEBUG] 文件类型: $(file sb.tar.gz)"
  fi
  exit 1
fi

echo "[INFO] 下载完成，验证文件..."

# 验证文件
if [[ ! -f sb.tar.gz ]]; then
  echo "[ERROR] 文件不存在: sb.tar.gz"
  exit 1
fi

FILE_SIZE=$(stat -c%s sb.tar.gz 2>/dev/null || stat -f%z sb.tar.gz 2>/dev/null || echo "0")
echo "[INFO] 文件大小: $FILE_SIZE 字节"

if [[ "$FILE_SIZE" -lt 1000000 ]]; then
  echo "[ERROR] 文件太小，可能下载失败"
  echo "[DEBUG] 文件内容："
  head -n 10 sb.tar.gz
  exit 1
fi

if ! file sb.tar.gz | grep -q 'gzip compressed'; then
  echo "[ERROR] 文件不是有效的 gzip 格式"
  echo "[DEBUG] file 命令输出: $(file sb.tar.gz)"
  exit 1
fi

echo "[INFO] 文件验证通过，开始解压..."
if ! tar -xzf sb.tar.gz --strip-components=1 2>&1; then
  echo "[ERROR] 解压失败"
  exit 1
fi

if [[ ! -f sing-box ]]; then
  echo "[ERROR] 解压后未找到 sing-box 文件"
  echo "[DEBUG] 目录内容："
  ls -la
  exit 1
fi

chmod +x sing-box
rm -f sb.tar.gz

echo "[INFO] ✓ sing-box 安装完成"

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

echo "[INFO] ✓ 配置文件生成完成"

# ===== 启动服务 =====
echo "[INFO] 启动 socks5 服务..."

# 停止可能存在的旧进程
pkill -f "sing-box run" 2>/dev/null || true
sleep 1

# 启动服务
nohup "$BIN_FILE" run -c "$CONFIG_FILE" > "$LOG_FILE" 2>&1 &
SING_PID=$!
echo $SING_PID > "$PID_FILE"

echo "[INFO] 服务已启动，PID: $SING_PID"
echo "[INFO] 等待服务启动..."
sleep 4

# ===== 检查进程 =====
if ! ps -p $SING_PID > /dev/null 2>&1; then
  echo "[ERROR] sing-box 进程启动失败"
  echo "[ERROR] 日志内容："
  cat "$LOG_FILE" 2>/dev/null || echo "无法读取日志文件"
  exit 1
fi

echo "[INFO] ✓ sing-box 进程运行正常"

# ===== 检查端口监听 =====
echo "[INFO] 检查端口监听状态..."

LISTEN_CHECK=false
for i in {1..10}; do
  if command -v ss >/dev/null 2>&1; then
    if ss -tlnp 2>/dev/null | grep -q ":$PORT"; then
      LISTEN_CHECK=true
      LISTEN_INFO=$(ss -tlnp 2>/dev/null | grep ":$PORT")
      break
    fi
  elif command -v netstat >/dev/null 2>&1; then
    if netstat -tlnp 2>/dev/null | grep -q ":$PORT"; then
      LISTEN_CHECK=true
      LISTEN_INFO=$(netstat -tlnp 2>/dev/null | grep ":$PORT")
      break
    fi
  fi
  echo "[INFO] 等待端口监听... ($i/10)"
  sleep 2
done

if [[ "$LISTEN_CHECK" == false ]]; then
  echo "[ERROR] 端口 $PORT 没有监听成功"
  echo "[ERROR] 进程状态："
  ps aux | grep sing-box
  echo "[ERROR] 最近30行日志："
  tail -n 30 "$LOG_FILE" 2>/dev/null || echo "无法读取日志"
  exit 1
fi

echo "[INFO] ✓ 端口监听成功："
echo "$LISTEN_INFO"

# ===== 测试代理连接 =====
echo "[INFO] 测试代理连接..."

if [[ "$HAS_IPV6" == true ]]; then
  if curl -s6 --socks5-hostname "[::1]:$PORT" -U "$USERNAME:$PASSWORD" --max-time 10 http://ip.sb >/dev/null 2>&1; then
    echo "✅ IPv6 代理连接测试成功"
    TEST_IP=$(curl -s6 --socks5-hostname "[::1]:$PORT" -U "$USERNAME:$PASSWORD" --max-time 10 http://ip.sb 2>/dev/null || echo "无法获取")
    echo "[INFO] 出口 IP: $TEST_IP"
  else
    echo "⚠️ IPv6 代理连接测试失败，但服务已启动"
  fi
else
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

if [[ "$HAS_IPV6" == true && -n "$IP_V6" ]]; then
  echo "📡 连接信息 (IPv6):"
  echo "   socks5://$USERNAME:$PASSWORD@[$IP_V6]:$PORT"
  echo ""
  echo "🔧 配置参数:"
  echo "   服务器: $IP_V6"
  echo "   端口: $PORT"
  echo "   用户名: $USERNAME"
  echo "   密码: $PASSWORD"
fi

if [[ "$HAS_IPV4" == true && -n "$IP_V4" ]]; then
  echo "📡 连接信息 (IPv4):"
  echo "   socks5://$USERNAME:$PASSWORD@$IP_V4:$PORT"
  echo ""
  echo "🔧 配置参数:"
  echo "   服务器: $IP_V4"
  echo "   端口: $PORT"
  echo "   用户名: $USERNAME"
  echo "   密码: $PASSWORD"
fi

echo ""
echo "📝 管理命令:"
echo "   查看日志: tail -f $LOG_FILE"
echo "   查看状态: ps aux | grep sing-box"
echo "   停止服务: kill \$(cat $PID_FILE)"
echo "   卸载服务: bash $0 uninstall"
echo ""
echo "⚠️  防火墙提醒:"
if [[ "$HAS_IPV6" == true ]]; then
  echo "   ip6tables -I INPUT -p tcp --dport $PORT -j ACCEPT"
fi
if [[ "$HAS_IPV4" == true ]]; then
  echo "   iptables -I INPUT -p tcp --dport $PORT -j ACCEPT"
fi
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit 0
