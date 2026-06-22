#!/usr/bin/env bash
set -euo pipefail

# Sing-box 简单安装脚本 - VLESS + Reality 单协议方案
# 适用于 Ubuntu/Debian x86_64/arm64

VERSION="1.13.0-rc.4"
PORT="443"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/sing-box"
SERVICE_FILE="/etc/systemd/system/sing-box.service"

# 颜色输出
info() { echo -e "\033[32m[INFO]\033[0m $*"; }
error() { echo -e "\033[31m[ERROR]\033[0m $*"; exit 1; }
warning() { echo -e "\033[33m[WARN]\033[0m $*"; }

# 检查 root 权限
[[ $EUID -ne 0 ]] && error "请使用 root 权限运行"

# 检测架构
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *) error "不支持的架构: $ARCH" ;;
esac

# 获取服务器 IP
SERVER_IP=$(ip addr show | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | head -1)
[[ -z "$SERVER_IP" ]] && error "无法获取服务器 IP"

info "开始安装 Sing-box ${VERSION}..."
info "架构: ${ARCH}"
info "服务器 IP: ${SERVER_IP}"

# 1. 下载 sing-box
info "下载 sing-box 二进制文件..."
cd /tmp
DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${ARCH}.tar.gz"
wget -q --show-progress "${DOWNLOAD_URL}" -O sing-box.tar.gz || error "下载失败"

# 2. 验证并解压
info "解压文件..."
tar xzf sing-box.tar.gz || error "解压失败"
chmod +x "sing-box-${VERSION}-linux-${ARCH}/sing-box"
mv "sing-box-${VERSION}-linux-${ARCH}/sing-box" "${INSTALL_DIR}/" || error "安装失败"
rm -rf sing-box.tar.gz "sing-box-${VERSION}-linux-${ARCH}"

# 3. 生成密钥对
info "生成 Reality 密钥对..."
KEYS=$(${INSTALL_DIR}/sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$KEYS" | grep "PrivateKey:" | awk '{print $2}')
PUBLIC_KEY=$(echo "$KEYS" | grep "PublicKey:" | awk '{print $2}')

# 4. 生成 UUID
UUID=$(cat /proc/sys/kernel/random/uuid)

# 5. 生成 short_id (8 字节十六进制)
SHORT_ID=$(openssl rand -hex 8)

info "生成的配置信息:"
info "  UUID: ${UUID}"
info "  Private Key: ${PRIVATE_KEY}"
info "  Public Key: ${PUBLIC_KEY}"
info "  Short ID: ${SHORT_ID}"

# 6. 创建配置目录
mkdir -p "${CONFIG_DIR}"

# 7. 生成配置文件
info "生成配置文件..."
cat > "${CONFIG_DIR}/config.json" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "tcp_fast_open": true,
      "sniff": true,
      "sniff_override_destination": true,
      "domain_strategy": "prefer_ipv4",
      "listen_port": ${PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.microsoft.com",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.microsoft.com",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": [
            "${SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ]
}
EOF

# 8. 创建 systemd 服务
info "创建 systemd 服务..."
cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Sing-box Service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/sing-box run -c ${CONFIG_DIR}/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

# 9. 配置防火墙
info "配置防火墙..."
if command -v ufw &> /dev/null; then
    ufw allow ${PORT}/tcp >/dev/null 2>&1 || true
    info "已开放 UFW 端口 ${PORT}"
elif command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-port=${PORT}/tcp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    info "已开放 firewalld 端口 ${PORT}"
fi

# 10. 启动服务
info "启动 sing-box 服务..."
systemctl daemon-reload
systemctl enable sing-box
systemctl start sing-box

# 11. 检查状态
sleep 2
if systemctl is-active --quiet sing-box; then
    info "✓ Sing-box 安装成功并已启动"
else
    error "✗ Sing-box 启动失败，请检查日志: journalctl -u sing-box -n 50"
fi

# 12. 生成客户端配置
info ""
info "=========================================="
info "客户端配置信息"
info "=========================================="
info "协议: VLESS + Reality"
info "服务器: ${SERVER_IP}"
info "端口: ${PORT}"
info "UUID: ${UUID}"
info "Flow: xtls-rprx-vision"
info "Public Key: ${PUBLIC_KEY}"
info "Short ID: ${SHORT_ID}"
info "SNI: www.microsoft.com"
info "=========================================="
info ""
info "Shadowrocket/V2rayN/Nekobox 导入链接:"
VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Sing-box-Reality"
echo "${VLESS_LINK}"
info ""
info "管理命令:"
info "  查看状态: systemctl status sing-box"
info "  查看日志: journalctl -u sing-box -f"
info "  重启服务: systemctl restart sing-box"
info "  停止服务: systemctl stop sing-box"
info ""
info "更换 UUID: 运行 change-uuid.sh 脚本"
info "卸载: systemctl stop sing-box && systemctl disable sing-box && rm -rf ${INSTALL_DIR}/sing-box ${CONFIG_DIR} ${SERVICE_FILE}"
