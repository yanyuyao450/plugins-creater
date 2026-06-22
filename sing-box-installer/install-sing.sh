#!/bin/bash

set -e

echo "=================================="
echo "sing-box Reality Enterprise v2"
echo "Auto Version + Anti 404 Fix"
echo "=================================="

# ===== root check =====
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 运行"
  exit 1
fi

# ===== deps =====
apt update -y
apt install -y curl jq ufw wget tar

# ===== get latest version (方案2核心) =====
echo "[1/7] 获取版本..."

VERSION="1.13.0-rc.4"

echo "✔ 版本: $VERSION"

ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *) echo "不支持架构: $ARCH"; exit 1 ;;
esac

echo "[2/7] 下载 sing-box..."

URL="https://github.com/SagerNet/sing-box/releases/download/${VERSION}/sing-box-${VERSION}-linux-${ARCH}.tar.gz"

echo "URL: $URL"

curl -fL "$URL" -o sing-box.tar.gz

tar -xzf sing-box.tar.gz

# 🔥 关键：自动识别目录（避免再踩坑）
DIR=$(ls -d sing-box-*linux-${ARCH} 2>/dev/null | head -n 1)

if [ -z "$DIR" ]; then
  echo "❌ 解压目录不存在"
  ls -al
  exit 1
fi

echo "✔ 解压目录: $DIR"

install -m 755 "$DIR/sing-box" /usr/local/bin/sing-box

rm -rf sing-box.tar.gz "$DIR"

echo "✔ sing-box 安装完成"

# ===== sysctl (BBR) =====
echo "[3/7] 优化网络..."

cat >> /etc/sysctl.conf <<EOF

net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

net.core.somaxconn=65535
net.core.netdev_max_backlog=250000

net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
EOF

sysctl -p

# ===== firewall =====
echo "[4/7] 防火墙设置..."

ufw allow 443/tcp
ufw allow OpenSSH
ufw --force enable

# ===== params =====
echo "[5/7] 生成配置..."

DOMAIN="www.microsoft.com"
PORT=443
SHORT_ID="a1b2c3d4e5f6"

UUID1=$(cat /proc/sys/kernel/random/uuid)
UUID2=$(cat /proc/sys/kernel/random/uuid)
UUID3=$(cat /proc/sys/kernel/random/uuid)

KEYS=$(sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$KEYS" | grep PrivateKey | awk '{print $2}')
PUBLIC_KEY=$(echo "$KEYS" | grep PublicKey | awk '{print $2}')

IP=$(curl -s ifconfig.me)

# ===== config =====
mkdir -p /etc/sing-box

cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "info"
  },

  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $PORT,

      "users": [
        { "uuid": "$UUID1" },
        { "uuid": "$UUID2" },
        { "uuid": "$UUID3" }
      ],

      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",

        "reality": {
          "enabled": true,

          "handshake": {
            "server": "$DOMAIN",
            "server_port": 443
          },

          "private_key": "$PRIVATE_KEY",

          "short_id": [
            "$SHORT_ID",
            "b2c3d4e5",
            "c3d4e5f6"
          ]
        }
      },

      "transport": {
        "type": "tcp"
      }
    }
  ],

  "outbounds": [
    {
      "type": "direct"
    }
  ]
}
EOF

# ===== systemd =====
echo "[6/7] 启动服务..."

cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
RestartSec=3
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box

sleep 2

# ===== self check =====
echo "[7/7] 自检..."

if systemctl is-active --quiet sing-box; then
  echo "✔ 服务运行正常"
else
  echo "❌ 服务启动失败"
  journalctl -u sing-box -e --no-pager | tail -50
  exit 1
fi

if ! ss -lntp | grep -q ":$PORT"; then
  echo "❌ 端口未监听"
  exit 1
fi

# ===== output =====
echo ""
echo "=================================="
echo "部署完成"
echo "=================================="
echo ""

echo "IP: $IP"
echo "SNI: $DOMAIN"
echo "PORT: $PORT"
echo ""

echo "User1:"
echo "vless://$UUID1@$IP:$PORT?encryption=none&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&flow=xtls-rprx-vision&type=tcp#user1"
echo ""

echo "User2:"
echo "vless://$UUID2@$IP:$PORT?encryption=none&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&flow=xtls-rprx-vision&type=tcp#user2"
echo ""

echo "User3:"
echo "vless://$UUID3@$IP:$PORT?encryption=none&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&flow=xtls-rprx-vision&type=tcp#user3"
echo ""

echo "=================================="
echo "Flow: xtls-rprx-vision"
echo "Security: reality"
echo "Fingerprint: chrome"
echo "=================================="