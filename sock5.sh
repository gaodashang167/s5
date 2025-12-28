#!/bin/bash

# sing-box socks5 安装脚本 (纯 IPv6 优化版，不依赖 GitHub API)
# 用法：
# 安装：PORT=16805 USERNAME=user PASSWORD=pass bash sock5.sh
# 卸载：bash sock5.sh uninstall

set -e

INSTALL_DIR="/usr/local/sb"
CONFIG_FILE="$INSTALL_DIR/config.json"
BIN_FILE="$INSTALL_DIR/sing-box"
LOG_FILE="$INSTALL_DIR/run.log"
PID_FILE="$INSTALL_DIR/sb.pid"

# 固定版本（避免 API 查询超时）
SING_BOX_VERSION="1.10.7"

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
  echo "[ERROR] 必须设置 PORT、USERNAME、PASSWORD 变量"
  echo "示例: PORT=16805 USERNAME=user PASSWORD=pass bash $0"
  exit 1
fi

echo "========================================="
echo " Socks5 代理安装程序"
echo "========================================="
echo "[INFO] 端口: $PORT"
echo "[INFO] 用户名: $USERNAME"
echo ""

# ===== 检测网络环境 =====
echo "[1/7] 检测网络环境..."
HAS_IPV6=false
IP_V6=""

# 快速检测 IPv6（3秒超时）
if timeout 3 curl -s6 --connect-timeout 2 icanhazip.com >/dev/null 2>&1; then
  HAS_IPV6=true
  IP_V6=$(timeout 3 curl -s6 --connect-timeout 2 icanhazip.com 2>/dev/null || echo "")
  echo "✓ IPv6 网络可用: $IP_V6"
else
  echo "✗ 未检测到 IPv6，将尝试 IPv4"
fi

# ===== 安装依赖 =====
echo ""
echo "[2/7] 安装依赖..."
if command -v apt >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq curl tar file iproute2 >/dev/null 2>&1 || true
fi
echo "✓ 依赖检查完成"

# ===== 准备安装目录 =====
echo ""
echo "[3/7] 准备安装目录..."
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR" || exit 1
echo "✓ 目录创建完成: $INSTALL_DIR"

# ===== 检测架构 =====
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH_TYPE=amd64 ;;
  aarch64|arm64) ARCH_TYPE=arm64 ;;
  armv7*) ARCH_TYPE=armv7 ;;
  *) echo "[ERROR] 不支持的架构: $ARCH"; exit 1 ;;
esac
echo "✓ 系统架构: $ARCH_TYPE"

# ===== 下载 sing-box =====
echo ""
echo "[4/7] 下载 sing-box v${SING_BOX_VERSION}..."

DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-${ARCH_TYPE}.tar.gz"
echo "下载地址: $DOWNLOAD_URL"

# 清理旧文件
rm -f sb.tar.gz sing-box

# 下载（IPv6 优先，60秒超时）
echo "正在下载..."
if [[ "$HAS_IPV6" == true ]]; then
  if ! curl -6 -L --connect-timeout 10 --max-time 120 -# -o sb.tar.gz "$DOWNLOAD_URL" 2>&1; then
    echo "[ERROR] IPv6 下载失败，尝试不指定协议版本..."
    curl -L --connect-timeout 10 --max-time 120 -# -o sb.tar.gz "$DOWNLOAD_URL" || {
      echo "[ERROR] 下载失败，请检查网络连接"
      exit 1
    }
  fi
else
  curl -L --connect-timeout 10 --max-time 120 -# -o sb.tar.gz "$DOWNLOAD_URL" || {
    echo "[ERROR] 下载失败"
    exit 1
  }
fi

# 验证文件
if [[ ! -f sb.tar.gz ]]; then
  echo "[ERROR] 下载的文件不存在"
  exit 1
fi

FILE_SIZE=$(stat -c%s sb.tar.gz 2>/dev/null || stat -f%z sb.tar.gz 2>/dev/null || echo "0")
if [[ "$FILE_SIZE" -lt 500000 ]]; then
  echo "[ERROR] 文件太小 ($FILE_SIZE 字节)，可能下载失败"
  exit 1
fi

echo "✓ 下载完成 ($(echo "scale=2; $FILE_SIZE/1048576" | bc 2>/dev/null || echo "?")MB)"

# ===== 解压安装 =====
echo ""
echo "[5/7] 解压并安装..."
tar -xzf sb.tar.gz --strip-components=1 || {
  echo "[ERROR] 解压失败"
  exit 1
}

if [[ ! -f sing-box ]]; then
  echo "[ERROR] 未找到 sing-box 可执行文件"
  ls -la
  exit 1
fi

chmod +x sing-box
rm -f sb.tar.gz
echo "✓ 安装完成"

# ===== 生成配置 =====
echo ""
echo "[6/7] 生成配置文件..."

LISTEN_ADDR="::"
if [[ "$HAS_IPV6" != true ]]; then
  LISTEN_ADDR="0.0.0.0"
fi

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

echo "✓ 配置文件已生成"

# ===== 启动服务 =====
echo ""
echo "[7/7] 启动服务..."

# 停止旧进程
pkill -f "sing-box run" 2>/dev/null || true
sleep 1

# 启动
nohup "$BIN_FILE" run -c "$CONFIG_FILE" > "$LOG_FILE" 2>&1 &
SING_PID=$!
echo $SING_PID > "$PID_FILE"

echo "✓ 服务已启动 (PID: $SING_PID)"
echo "等待服务就绪..."
sleep 3

# 检查进程
if ! ps -p $SING_PID > /dev/null 2>&1; then
  echo ""
  echo "❌ 服务启动失败！"
  echo ""
  echo "错误日志："
  cat "$LOG_FILE" 2>/dev/null || echo "无法读取日志"
  exit 1
fi

# 检查端口
LISTEN_OK=false
for i in {1..8}; do
  if ss -tlnp 2>/dev/null | grep -q ":$PORT" || netstat -tlnp 2>/dev/null | grep -q ":$PORT"; then
    LISTEN_OK=true
    break
  fi
  sleep 1
done

if [[ "$LISTEN_OK" != true ]]; then
  echo ""
  echo "❌ 端口 $PORT 未能正常监听"
  echo ""
  echo "进程状态:"
  ps aux | grep sing-box | grep -v grep
  echo ""
  echo "日志内容:"
  tail -n 20 "$LOG_FILE"
  exit 1
fi

echo "✓ 端口 $PORT 监听正常"

# 测试连接
echo ""
echo "测试代理连接..."
if [[ "$HAS_IPV6" == true ]]; then
  if timeout 5 curl -s6 --socks5-hostname "[::1]:$PORT" -U "$USERNAME:$PASSWORD" http://ip.sb >/dev/null 2>&1; then
    TEST_IP=$(timeout 5 curl -s6 --socks5-hostname "[::1]:$PORT" -U "$USERNAME:$PASSWORD" http://ip.sb 2>/dev/null || echo "")
    echo "✅ 代理测试成功！出口IP: $TEST_IP"
  else
    echo "⚠️ 本地测试未通过，但服务已启动"
  fi
else
  if timeout 5 curl -s --socks5-hostname "127.0.0.1:$PORT" -U "$USERNAME:$PASSWORD" http://ip.sb >/dev/null 2>&1; then
    echo "✅ 代理测试成功！"
  else
    echo "⚠️ 本地测试未通过，但服务已启动"
  fi
fi

# ===== 输出结果 =====
echo ""
echo "========================================="
echo "✅ 安装完成！"
echo "========================================="
echo ""

if [[ "$HAS_IPV6" == true && -n "$IP_V6" ]]; then
  echo "📡 连接地址:"
  echo "   socks5://$USERNAME:$PASSWORD@[$IP_V6]:$PORT"
  echo ""
  echo "📝 配置信息:"
  echo "   服务器: $IP_V6"
  echo "   端口: $PORT"
  echo "   用户名: $USERNAME"
  echo "   密码: $PASSWORD"
  echo "   协议: SOCKS5"
else
  echo "📡 连接地址:"
  echo "   socks5://$USERNAME:$PASSWORD@<您的服务器IP>:$PORT"
  echo ""
  echo "📝 配置信息:"
  echo "   端口: $PORT"
  echo "   用户名: $USERNAME"
  echo "   密码: $PASSWORD"
fi

echo ""
echo "💡 管理命令:"
echo "   查看日志: tail -f $LOG_FILE"
echo "   查看状态: ps aux | grep sing-box"
echo "   重启服务: kill \$(cat $PID_FILE) && bash $0"
echo "   停止服务: kill \$(cat $PID_FILE)"
echo "   卸载: bash $0 uninstall"
echo ""
echo "⚠️ 重要提醒:"
echo "   请确保防火墙已开放 TCP $PORT 端口"
if [[ "$HAS_IPV6" == true ]]; then
  echo "   IPv6 防火墙: ip6tables -I INPUT -p tcp --dport $PORT -j ACCEPT"
fi
echo ""
echo "========================================="

exit 0
