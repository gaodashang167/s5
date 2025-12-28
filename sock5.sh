#!/bin/bash

# sing-box socks5 安装脚本 (支持多下载源)
# 用法：PORT=16805 USERNAME=user PASSWORD=pass bash sock5.sh

set -e

INSTALL_DIR="/usr/local/sb"
CONFIG_FILE="$INSTALL_DIR/config.json"
BIN_FILE="$INSTALL_DIR/sing-box"
LOG_FILE="$INSTALL_DIR/run.log"
PID_FILE="$INSTALL_DIR/sb.pid"

SING_BOX_VERSION="1.10.7"

# ===== 卸载逻辑 =====
if [[ "${1:-}" == "uninstall" ]]; then
  echo "[INFO] 停止 socks5 服务..."
  pkill -f "sing-box run" || true
  [[ -f "$PID_FILE" ]] && kill "$(cat "$PID_FILE")" 2>/dev/null || true
  rm -rf "$INSTALL_DIR"
  echo "✅ socks5 卸载完成"
  exit 0
fi

# ===== 环境变量检查 =====
if [[ -z "${PORT:-}" || -z "${USERNAME:-}" || -z "${PASSWORD:-}" ]]; then
  echo "[ERROR] 必须设置 PORT、USERNAME、PASSWORD"
  echo "示例: PORT=16805 USERNAME=user PASSWORD=pass bash $0"
  exit 1
fi

echo "========================================="
echo " Socks5 代理安装程序"
echo "========================================="
echo "[INFO] 端口: $PORT | 用户名: $USERNAME"
echo ""

# ===== 检测网络 =====
echo "[1/7] 检测网络环境..."
IP_V6=$(timeout 3 curl -s6 icanhazip.com 2>/dev/null || echo "")
if [[ -n "$IP_V6" ]]; then
  echo "✓ IPv6: $IP_V6"
else
  echo "✓ IPv4 模式"
fi

# ===== 安装依赖 =====
echo ""
echo "[2/7] 安装依赖..."
if command -v apt >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq curl tar file iproute2 >/dev/null 2>&1 || true
fi
echo "✓ 依赖准备完成"

# ===== 准备目录 =====
echo ""
echo "[3/7] 准备安装目录..."
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR" || exit 1

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH_TYPE=amd64 ;;
  aarch64|arm64) ARCH_TYPE=arm64 ;;
  *) echo "[ERROR] 不支持的架构: $ARCH"; exit 1 ;;
esac
echo "✓ 架构: $ARCH_TYPE"

# ===== 下载 sing-box =====
echo ""
echo "[4/7] 下载 sing-box v${SING_BOX_VERSION}..."

rm -f sb.tar.gz sing-box

FILENAME="sing-box-${SING_BOX_VERSION}-linux-${ARCH_TYPE}.tar.gz"

# 多个下载源
SOURCES=(
  "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/${FILENAME}"
  "https://gh.ddlc.top/https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/${FILENAME}"
  "https://ghproxy.com/https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/${FILENAME}"
  "https://mirror.ghproxy.com/https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/${FILENAME}"
  "https://gh-proxy.com/https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/${FILENAME}"
)

DOWNLOAD_SUCCESS=false

for SOURCE in "${SOURCES[@]}"; do
  echo "尝试: $SOURCE"
  
  # 尝试下载（15秒超时）
  if curl -L --connect-timeout 5 --max-time 30 -# -o sb.tar.gz "$SOURCE" 2>&1; then
    # 检查文件大小
    if [[ -f sb.tar.gz ]]; then
      FILE_SIZE=$(stat -c%s sb.tar.gz 2>/dev/null || stat -f%z sb.tar.gz 2>/dev/null || echo "0")
      if [[ "$FILE_SIZE" -gt 500000 ]]; then
        echo "✓ 下载成功 ($(( FILE_SIZE / 1048576 ))MB)"
        DOWNLOAD_SUCCESS=true
        break
      else
        echo "✗ 文件太小，尝试下一个源..."
        rm -f sb.tar.gz
      fi
    fi
  else
    echo "✗ 连接失败，尝试下一个源..."
  fi
  
  sleep 1
done

if [[ "$DOWNLOAD_SUCCESS" != true ]]; then
  echo ""
  echo "❌ 所有下载源均失败"
  echo ""
  echo "可能原因："
  echo "1. 服务器无法访问外网"
  echo "2. 防火墙阻止了 HTTPS 连接"
  echo "3. DNS 解析问题"
  echo ""
  echo "请尝试手动下载："
  echo "1. 访问 https://github.com/SagerNet/sing-box/releases"
  echo "2. 下载 $FILENAME"
  echo "3. 上传到服务器 $INSTALL_DIR 目录"
  echo "4. 运行: cd $INSTALL_DIR && tar -xzf $FILENAME --strip-components=1"
  exit 1
fi

# ===== 解压安装 =====
echo ""
echo "[5/7] 解压安装..."
tar -xzf sb.tar.gz --strip-components=1 || {
  echo "[ERROR] 解压失败"
  exit 1
}

if [[ ! -f sing-box ]]; then
  echo "[ERROR] 未找到 sing-box 文件"
  exit 1
fi

chmod +x sing-box
rm -f sb.tar.gz
echo "✓ 安装完成"

# ===== 生成配置 =====
echo ""
echo "[6/7] 生成配置..."

# IPv6 环境监听 ::，否则监听 0.0.0.0
LISTEN_ADDR="::"
[[ -z "$IP_V6" ]] && LISTEN_ADDR="0.0.0.0"

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

echo "✓ 配置文件生成完成"

# ===== 启动服务 =====
echo ""
echo "[7/7] 启动服务..."

pkill -f "sing-box run" 2>/dev/null || true
sleep 1

nohup "$BIN_FILE" run -c "$CONFIG_FILE" > "$LOG_FILE" 2>&1 &
SING_PID=$!
echo $SING_PID > "$PID_FILE"

echo "✓ 服务已启动 (PID: $SING_PID)"
sleep 3

# 检查进程
if ! ps -p $SING_PID > /dev/null 2>&1; then
  echo ""
  echo "❌ 服务启动失败"
  echo ""
  cat "$LOG_FILE" 2>/dev/null || echo "无法读取日志"
  exit 1
fi

# 检查端口
LISTEN_OK=false
for i in {1..6}; do
  if ss -tlnp 2>/dev/null | grep -q ":$PORT" || netstat -tlnp 2>/dev/null | grep -q ":$PORT"; then
    LISTEN_OK=true
    break
  fi
  sleep 1
done

if [[ "$LISTEN_OK" != true ]]; then
  echo ""
  echo "❌ 端口 $PORT 未能监听"
  echo ""
  tail -n 20 "$LOG_FILE"
  exit 1
fi

echo "✓ 端口 $PORT 监听正常"

# 测试代理
echo ""
echo "测试代理..."
if [[ -n "$IP_V6" ]]; then
  if timeout 5 curl -s6 --socks5 "[::1]:$PORT" -U "$USERNAME:$PASSWORD" http://ip.sb >/dev/null 2>&1; then
    echo "✅ 代理测试成功"
  else
    echo "⚠️ 本地测试失败（但服务已启动）"
  fi
else
  if timeout 5 curl -s --socks5 "127.0.0.1:$PORT" -U "$USERNAME:$PASSWORD" http://ip.sb >/dev/null 2>&1; then
    echo "✅ 代理测试成功"
  else
    echo "⚠️ 本地测试失败（但服务已启动）"
  fi
fi

# ===== 输出信息 =====
echo ""
echo "========================================="
echo "✅ 安装完成！"
echo "========================================="
echo ""

if [[ -n "$IP_V6" ]]; then
  echo "📡 连接信息 (IPv6):"
  echo "   socks5://$USERNAME:$PASSWORD@[$IP_V6]:$PORT"
else
  echo "📡 连接信息:"
  echo "   socks5://$USERNAME:$PASSWORD@<服务器IP>:$PORT"
fi

echo ""
echo "📝 配置:"
echo "   端口: $PORT"
echo "   用户: $USERNAME"
echo "   密码: $PASSWORD"
echo ""
echo "💡 管理:"
echo "   日志: tail -f $LOG_FILE"
echo "   状态: ps aux | grep sing-box"
echo "   停止: kill \$(cat $PID_FILE)"
echo "   卸载: bash $0 uninstall"
echo ""
echo "⚠️ 确保防火墙已开放端口 $PORT"
[[ -n "$IP_V6" ]] && echo "   ip6tables -I INPUT -p tcp --dport $PORT -j ACCEPT"
echo ""
echo "========================================="

exit 0
