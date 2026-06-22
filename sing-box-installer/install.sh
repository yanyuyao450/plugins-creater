#!/bin/bash

set -e

echo "=================================="
echo "Enterprise sing-box Reality Setup"
echo "=================================="

# ===== root check =====
if [ "$EUID" -ne 0 ]; then
  echo "Run as root"
  exit 1
fi

# ===== install deps =====
apt update -y
apt install -y curl ufw jq

# ===== install sing-box =====
bash <(curl -Ls https://raw.githubusercontent.com/SagerNet/sing-box/releases/download/v1.9.0/install.sh)

# ===== system tuning (BBR + TCP) =====
echo "[1] enabling BBR + TCP tuning..."

cat >> /etc/sysctl.conf <<EOF

net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

net.core.somaxconn=65535
net.core.netdev_max_backlog=250000

net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5

net.core.rmem_max=67108864
net.core.wmem_max=67108864

net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
EOF

sysctl -p

# ===== firewall =====
echo "[2] configuring firewall..."

ufw allow 443/tcp
ufw allow OpenSSH
ufw --force enable

# ===== variables =====
echo "[3] generating config..."

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
      "tag": "reality-in",
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
echo "[4] setting systemd..."

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

# ===== self-check =====
echo "[5] self check..."

if systemctl is-active --quiet sing-box; then
  echo "OK: sing-box running"
else
  echo "FAILED: service not running"
  journalctl -u sing-box -e --no-pager | tail -50
  exit 1
fi

if ! ss -lntp | grep -q ":443"; then
  echo "FAILED: port not listening"
  exit 1
fi

# ===== output =====
echo ""
echo "=================================="
echo "SETUP COMPLETE"
echo "=================================="
echo ""
echo "SNI: $DOMAIN"
echo "IP: $IP"
echo "PORT: $PORT"
echo "=================================="
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
echo "IMPORTANT:"
echo "- Flow: xtls-rprx-vision"
echo "- Security: reality"
echo "- Fingerprint: chrome"
echo "=================================="