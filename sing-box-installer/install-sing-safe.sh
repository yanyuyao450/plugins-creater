#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly PROGRAM_NAME="${0##*/}"
readonly CONFIG_DIR="/etc/sing-box"
readonly CONFIG_FILE="$CONFIG_DIR/config.json"
readonly BIN_FILE="/usr/local/bin/sing-box"
readonly UNIT_FILE="/etc/systemd/system/sing-box.service"
readonly SYSCTL_FILE="/etc/sysctl.d/99-sing-box.conf"
readonly CLIENT_FILE="/root/sing-box-client-links.txt"

DOMAIN="${DOMAIN:-www.microsoft.com}"
PORT="${PORT:-443}"
SHORT_ID="${SHORT_ID:-a1b2c3d4e5f6}"
SING_BOX_VERSION="${SING_BOX_VERSION:-}"

TEMP_DIR=""
BACKUP_DIR=""
TRANSACTION_ACTIVE=0
INSTALL_COMPLETED=0
WAS_ACTIVE=0
WAS_ENABLED=0

log() {
  printf '[INFO] %s\n' "$*" >&2
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

retry() {
  local max_attempts="$1"
  local delay="$2"
  shift 2

  local attempt=1
  until "$@"; do
    if (( attempt >= max_attempts )); then
      return 1
    fi
    warn "命令失败，${delay} 秒后重试（${attempt}/${max_attempts}）：$*"
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
}

normalize_arch() {
  case "$1" in
    x86_64 | amd64) printf 'amd64\n' ;;
    aarch64 | arm64) printf 'arm64\n' ;;
    *) return 1 ;;
  esac
}

normalize_version() {
  local version="${1#v}"
  if [[ "$version" =~ ^[0-9]+(\.[0-9]+){2}([.-][0-9A-Za-z.-]+)?$ ]]; then
    printf '%s\n' "$version"
  else
    return 1
  fi
}

validate_port() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

extract_key() {
  local name="$1"
  local output="$2"
  awk -v name="$name" '
    $0 ~ "^[[:space:]]*" name "[[:space:]]*:" {
      sub("^[[:space:]]*" name "[[:space:]]*:[[:space:]]*", "")
      print
      exit
    }
    $1 == name {
      print $2
      exit
    }
  ' <<<"$output"
}

require_supported_system() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请使用 root 权限运行：sudo bash $PROGRAM_NAME"
  [[ -r /etc/os-release ]] || die "无法识别操作系统，仅支持 Ubuntu"

  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "仅支持 Ubuntu，当前系统：${PRETTY_NAME:-unknown}"
  command -v systemctl >/dev/null 2>&1 || die "未找到 systemd"
  [[ -d /run/systemd/system ]] || die "systemd 未运行，不能安装系统服务"
}

install_dependencies() {
  export DEBIAN_FRONTEND=noninteractive
  retry 4 2 apt-get update ||
    die "apt-get update 多次重试后仍失败，请检查 Ubuntu 软件源和网络"
  retry 4 2 apt-get install -y --no-install-recommends \
    ca-certificates curl jq tar iproute2 ||
    die "依赖安装失败"
}

fetch_latest_release_url() {
  local output_file="$1"
  curl -fsSL \
    --connect-timeout 10 \
    --max-time 60 \
    -o /dev/null \
    -w '%{url_effective}' \
    "https://github.com/SagerNet/sing-box/releases/latest" >"$output_file"
}

resolve_version() {
  if [[ -n "$SING_BOX_VERSION" ]]; then
    normalize_version "$SING_BOX_VERSION" ||
      die "SING_BOX_VERSION 格式不安全：$SING_BOX_VERSION"
    return
  fi

  local metadata="$TEMP_DIR/latest.json"
  if retry 5 2 curl -fsSL \
    --connect-timeout 10 \
    --max-time 60 \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: sing-box-safe-installer" \
    "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
    -o "$metadata"; then
    local tag
    tag="$(jq -er '.tag_name' "$metadata")" ||
      die "GitHub 返回的版本信息无效"
    normalize_version "$tag" ||
      die "GitHub 返回了无法识别的版本：$tag"
    return
  fi

  warn "GitHub API 不可用，尝试通过最新稳定版重定向获取版本"
  local release_url tag
  retry 5 2 fetch_latest_release_url "$TEMP_DIR/latest-url" ||
    die "无法从 GitHub 获取 sing-box 最新稳定版本"
  release_url="$(<"$TEMP_DIR/latest-url")"
  tag="${release_url##*/}"
  normalize_version "$tag" ||
    die "GitHub 最新版本重定向无效：$release_url"
}

download_release() {
  local version="$1"
  local arch="$2"
  local archive="$TEMP_DIR/sing-box.tar.gz"
  local archive_dir="sing-box-${version}-linux-${arch}"
  local base_url="https://github.com/SagerNet/sing-box/releases/download/v${version}"
  local archive_name="${archive_dir}.tar.gz"

  log "下载 sing-box ${version} (${arch})"
  retry 5 2 curl -fL \
    --connect-timeout 10 \
    --max-time 300 \
    "${base_url}/${archive_name}" \
    -o "$archive" ||
    die "下载失败：${base_url}/${archive_name}"

  tar -tzf "$archive" >"$TEMP_DIR/archive.list" ||
    die "下载文件不是有效的 gzip/tar 压缩包"
  grep -Fqx "${archive_dir}/sing-box" "$TEMP_DIR/archive.list" ||
    die "压缩包中缺少 sing-box 可执行文件"

  local checksums="$TEMP_DIR/checksums.txt"
  if curl -fsSL --connect-timeout 10 --max-time 60 \
    "${base_url}/sing-box-${version}-checksums.txt" -o "$checksums"; then
    local expected
    expected="$(awk -v file="$archive_name" '$2 == file || $2 == "*" file {print $1; exit}' "$checksums")"
    if [[ -n "$expected" ]]; then
      local actual
      actual="$(sha256sum "$archive" | awk '{print $1}')"
      [[ "$actual" == "$expected" ]] || die "下载文件 SHA-256 校验失败"
      log "下载文件 SHA-256 校验通过"
    else
      warn "校验文件中没有当前压缩包记录，继续使用压缩包结构校验"
    fi
  else
    warn "未能获取官方校验文件，继续使用压缩包结构校验"
  fi

  tar -xzf "$archive" -C "$TEMP_DIR" "${archive_dir}/sing-box"
  local staged_bin="$TEMP_DIR/sing-box"
  install -m 0755 "$TEMP_DIR/$archive_dir/sing-box" "$staged_bin"
  "$staged_bin" version >/dev/null ||
    die "下载的 sing-box 无法执行，可能与当前系统不兼容"
  printf '%s\n' "$staged_bin"
}

generate_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    "$1" generate uuid
  fi
}

write_candidate_config() {
  local staged_bin="$1"
  local candidate="$2"
  local key_output private_key

  key_output="$("$staged_bin" generate reality-keypair)" ||
    die "生成 Reality 密钥失败"
  private_key="$(extract_key PrivateKey "$key_output")"
  PUBLIC_KEY="$(extract_key PublicKey "$key_output")"
  [[ -n "$private_key" && -n "$PUBLIC_KEY" ]] ||
    die "无法解析 sing-box 生成的 Reality 密钥"

  UUID1="$(generate_uuid "$staged_bin")"
  UUID2="$(generate_uuid "$staged_bin")"
  UUID3="$(generate_uuid "$staged_bin")"

  jq -n \
    --arg domain "$DOMAIN" \
    --argjson port "$PORT" \
    --arg private_key "$private_key" \
    --arg short_id "$SHORT_ID" \
    --arg uuid1 "$UUID1" \
    --arg uuid2 "$UUID2" \
    --arg uuid3 "$UUID3" \
    '{
      log: {level: "info", timestamp: true},
      inbounds: [{
        type: "vless",
        tag: "vless-reality-in",
        listen: "::",
        listen_port: $port,
        users: [
          {name: "user1", uuid: $uuid1, flow: "xtls-rprx-vision"},
          {name: "user2", uuid: $uuid2, flow: "xtls-rprx-vision"},
          {name: "user3", uuid: $uuid3, flow: "xtls-rprx-vision"}
        ],
        tls: {
          enabled: true,
          server_name: $domain,
          reality: {
            enabled: true,
            handshake: {server: $domain, server_port: 443},
            private_key: $private_key,
            short_id: [$short_id]
          }
        }
      }]
    }' >"$candidate"

  "$staged_bin" check -c "$candidate" ||
    die "新配置未通过 sing-box check，未修改现有服务"
}

write_candidate_unit() {
  local candidate="$1"
  cat >"$candidate" <<'EOF'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

backup_file() {
  local path="$1"
  local name="$2"
  if [[ -e "$path" || -L "$path" ]]; then
    cp -a "$path" "$BACKUP_DIR/$name"
  else
    : >"$BACKUP_DIR/$name.absent"
  fi
}

restore_file() {
  local path="$1"
  local name="$2"
  if [[ -e "$BACKUP_DIR/$name.absent" ]]; then
    rm -f "$path"
  elif [[ -e "$BACKUP_DIR/$name" || -L "$BACKUP_DIR/$name" ]]; then
    mkdir -p "$(dirname "$path")"
    rm -f "$path"
    cp -a "$BACKUP_DIR/$name" "$path"
  fi
}

rollback() {
  (( TRANSACTION_ACTIVE == 1 )) || return 0
  TRANSACTION_ACTIVE=0
  warn "安装未完成，正在恢复原有 sing-box 文件"

  restore_file "$BIN_FILE" "sing-box"
  restore_file "$CONFIG_FILE" "config.json"
  restore_file "$UNIT_FILE" "sing-box.service"
  systemctl daemon-reload >/dev/null 2>&1 || true

  if (( WAS_ENABLED == 1 )); then
    systemctl enable sing-box >/dev/null 2>&1 || true
  else
    systemctl disable sing-box >/dev/null 2>&1 || true
  fi
  if (( WAS_ACTIVE == 1 )); then
    systemctl restart sing-box >/dev/null 2>&1 || true
  else
    systemctl stop sing-box >/dev/null 2>&1 || true
  fi
  warn "已回滚；备份保留在：$BACKUP_DIR"
}

cleanup() {
  local status=$?
  if (( status != 0 && TRANSACTION_ACTIVE == 1 )); then
    rollback
  fi
  [[ -z "$TEMP_DIR" ]] || rm -rf "$TEMP_DIR"
  exit "$status"
}

deploy() {
  local staged_bin="$1"
  local candidate_config="$2"
  local candidate_unit="$3"

  BACKUP_DIR="/var/backups/sing-box-installer/$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$BACKUP_DIR"
  systemctl is-active --quiet sing-box && WAS_ACTIVE=1 || true
  systemctl is-enabled --quiet sing-box && WAS_ENABLED=1 || true
  backup_file "$BIN_FILE" "sing-box"
  backup_file "$CONFIG_FILE" "config.json"
  backup_file "$UNIT_FILE" "sing-box.service"

  TRANSACTION_ACTIVE=1
  mkdir -p "$CONFIG_DIR"
  install -m 0755 "$staged_bin" "$BIN_FILE"
  install -m 0600 "$candidate_config" "$CONFIG_FILE"
  install -m 0644 "$candidate_unit" "$UNIT_FILE"

  systemctl daemon-reload
  systemctl enable sing-box
  if ! systemctl restart sing-box; then
    journalctl -u sing-box -n 80 --no-pager >&2 || true
    die "sing-box 服务启动失败"
  fi

  local attempt
  for attempt in {1..10}; do
    if systemctl is-active --quiet sing-box &&
      ss -H -lnt "sport = :$PORT" 2>/dev/null | grep -q .; then
      TRANSACTION_ACTIVE=0
      INSTALL_COMPLETED=1
      return 0
    fi
    sleep 1
  done

  journalctl -u sing-box -n 80 --no-pager >&2 || true
  die "sing-box 未在 ${PORT}/tcp 正常监听"
}

configure_sysctl() {
  local candidate="$TEMP_DIR/99-sing-box.conf"
  : >"$candidate"

  local setting key
  for setting in \
    "net.core.somaxconn=65535" \
    "net.core.netdev_max_backlog=250000" \
    "net.ipv4.tcp_keepalive_time=300" \
    "net.ipv4.tcp_keepalive_intvl=30" \
    "net.ipv4.tcp_keepalive_probes=5"; do
    key="${setting%%=*}"
    if sysctl -N "$key" >/dev/null 2>&1; then
      printf '%s\n' "$setting" >>"$candidate"
    fi
  done

  modprobe tcp_bbr >/dev/null 2>&1 || true
  if [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]] &&
    grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
    printf '%s\n' "net.core.default_qdisc=fq" >>"$candidate"
    printf '%s\n' "net.ipv4.tcp_congestion_control=bbr" >>"$candidate"
  else
    warn "当前内核未提供 BBR，跳过 BBR 配置"
  fi

  if ! install -m 0644 "$candidate" "$SYSCTL_FILE"; then
    warn "无法写入网络优化配置，但不影响 sing-box 服务"
    return 0
  fi
  if ! sysctl -p "$SYSCTL_FILE"; then
    warn "部分网络优化参数未生效，但不影响 sing-box 服务"
  fi
}

configure_firewall() {
  if ! command -v ufw >/dev/null 2>&1; then
    return 0
  fi
  if LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${PORT}/tcp" >/dev/null ||
      warn "UFW 规则添加失败，请手动放行 ${PORT}/tcp"
  else
    log "UFW 未启用，不主动修改防火墙状态"
  fi
}

get_public_ip() {
  local endpoint ip
  for endpoint in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://icanhazip.com"; do
    ip="$(curl -4fsSL --connect-timeout 5 --max-time 10 "$endpoint" 2>/dev/null || true)"
    ip="${ip//$'\r'/}"
    ip="${ip//$'\n'/}"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')"
  [[ -n "$ip" ]] && printf '%s\n' "$ip"
}

write_client_links() {
  local ip
  ip="$(get_public_ip || true)"
  [[ -n "$ip" ]] || ip="YOUR_SERVER_IP"

  {
    printf 'IP: %s\nSNI: %s\nPORT: %s\n\n' "$ip" "$DOMAIN" "$PORT"
    printf 'User1:\nvless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&flow=xtls-rprx-vision&type=tcp#user1\n\n' \
      "$UUID1" "$ip" "$PORT" "$DOMAIN" "$PUBLIC_KEY" "$SHORT_ID"
    printf 'User2:\nvless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&flow=xtls-rprx-vision&type=tcp#user2\n\n' \
      "$UUID2" "$ip" "$PORT" "$DOMAIN" "$PUBLIC_KEY" "$SHORT_ID"
    printf 'User3:\nvless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&flow=xtls-rprx-vision&type=tcp#user3\n' \
      "$UUID3" "$ip" "$PORT" "$DOMAIN" "$PUBLIC_KEY" "$SHORT_ID"
  } | tee "$CLIENT_FILE"
  chmod 0600 "$CLIENT_FILE"
}

main() {
  require_supported_system
  validate_port "$PORT" || die "PORT 必须是 1-65535 的整数"
  [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "DOMAIN 格式无效"
  [[ "$SHORT_ID" =~ ^([0-9A-Fa-f]{2}){1,8}$ ]] ||
    die "SHORT_ID 必须是 2-16 位偶数长度十六进制字符串"

  TEMP_DIR="$(mktemp -d)"
  trap cleanup EXIT

  log "安装运行依赖"
  install_dependencies

  local arch version staged_bin candidate_config candidate_unit
  arch="$(normalize_arch "$(uname -m)")" ||
    die "不支持的 CPU 架构：$(uname -m)"
  version="$(resolve_version)"
  log "将安装 sing-box ${version}"
  staged_bin="$(download_release "$version" "$arch")"

  candidate_config="$TEMP_DIR/config.json"
  candidate_unit="$TEMP_DIR/sing-box.service"
  write_candidate_config "$staged_bin" "$candidate_config"
  write_candidate_unit "$candidate_unit"
  deploy "$staged_bin" "$candidate_config" "$candidate_unit"

  configure_sysctl
  configure_firewall
  write_client_links

  log "安装完成；客户端链接已保存到 $CLIENT_FILE"
  log "安装前文件备份：$BACKUP_DIR"
}

if [[ "${INSTALL_SING_LIB_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
