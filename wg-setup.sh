#!/usr/bin/env bash
set -euo pipefail

# WireGuard installer and manager for Ubuntu with nftables NAT across multiple or all egress interfaces.
# Features:
# - Install required packages (wireguard, qrencode, nftables)
# - Initialize server: choose subnet, DNS, port, optional endpoint; no single NIC selection required
# - NAT via nftables for either all non-WireGuard interfaces or a provided allowlist of egress interfaces
# - Manage clients: add, remove, list, show, and generate QR codes
# - Idempotent where possible; safe to re-run commands

WG_INTERFACE="wg0"
WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/${WG_INTERFACE}.conf"
WG_STATE_DIR="${WG_DIR}/${WG_INTERFACE}.d"
WG_CLIENTS_DIR="${WG_STATE_DIR}/clients"
WG_META_FILE="${WG_STATE_DIR}/server.meta"
WG_SERVER_PRIVKEY_FILE="${WG_STATE_DIR}/server_private.key"
WG_SERVER_PUBKEY_FILE="${WG_STATE_DIR}/server_public.key"

NFT_MAIN_CONF="/etc/nftables.conf"
NFT_INCLUDE_DIR="/etc/nftables.d"
NFT_TABLE_NAME="wg_${WG_INTERFACE}"
NFT_CONF_FILE="${NFT_INCLUDE_DIR}/${NFT_TABLE_NAME}.nft"

REQUIRED_CMDS=("wg" "wg-quick" "nft")

print_header() {
  echo "[wg-setup] $*"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
  fi
}

require_ubuntu() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
      echo "This script targets Ubuntu. Detected: ${ID:-unknown}" >&2
      exit 1
    fi
  else
    echo "/etc/os-release not found; cannot verify Ubuntu." >&2
    exit 1
  fi
}

ensure_dirs() {
  mkdir -p "${WG_DIR}" "${WG_STATE_DIR}" "${WG_CLIENTS_DIR}" "${NFT_INCLUDE_DIR}"
  chmod 700 "${WG_DIR}"
}

ensure_commands() {
  local missing=()
  for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    echo "Missing required commands: ${missing[*]}" >&2
    echo "Run: $0 install" >&2
    exit 1
  fi
}

apt_install() {
  require_root
  require_ubuntu
  print_header "Installing packages: wireguard, wireguard-tools, qrencode, nftables"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y wireguard wireguard-tools qrencode nftables
  systemctl enable nftables.service
  systemctl start nftables.service || true

  # Ensure include directory is loaded by the main nftables config
  if [[ ! -f "${NFT_MAIN_CONF}" ]]; then
    echo "include \"${NFT_INCLUDE_DIR}/*.nft\"" > "${NFT_MAIN_CONF}"
  else
    if ! grep -q "^include \\"${NFT_INCLUDE_DIR}/\*.nft\\\"" "${NFT_MAIN_CONF}" 2>/dev/null; then
      echo "" >> "${NFT_MAIN_CONF}"
      echo "include \"${NFT_INCLUDE_DIR}/*.nft\"" >> "${NFT_MAIN_CONF}"
    fi
  fi

  enable_ip_forward
  print_header "Installation complete."
}

enable_ip_forward() {
  require_root
  print_header "Enabling IPv4 forwarding"
  sed -i -E 's/^#?\s*net.ipv4.ip_forward\s*=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf || true
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sysctl -p /etc/sysctl.conf >/dev/null || true
}

prompt_init_values() {
  local default_subnet="10.8.0.0/24"
  local default_server_ip="10.8.0.1/24"
  local default_dns="1.1.1.1, 9.9.9.9"
  local default_port="51820"
  local detected_endpoint=""

  if command -v curl >/dev/null 2>&1; then
    detected_endpoint=$(curl -4s --max-time 3 https://ifconfig.me || true)
  fi

  echo -n "Choose VPN subnet [${default_subnet}]: "
  read -r SUBNET
  SUBNET=${SUBNET:-$default_subnet}

  # Server address defaults to first host of the subnet
  if [[ "$SUBNET" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\. ]]; then
    default_server_ip="${BASH_REMATCH[1]}.1/$(echo "$SUBNET" | cut -d'/' -f2)"
  fi

  echo -n "Server interface address [${default_server_ip}]: "
  read -r SERVER_ADDR
  SERVER_ADDR=${SERVER_ADDR:-$default_server_ip}

  echo -n "DNS servers for clients (comma-separated) [${default_dns}]: "
  read -r DNS_SERVERS
  DNS_SERVERS=${DNS_SERVERS:-$default_dns}

  echo -n "WireGuard UDP port [${default_port}]: "
  read -r WG_PORT
  WG_PORT=${WG_PORT:-$default_port}

  echo -n "Public endpoint (IP or DNS[:port]) [${detected_endpoint}]: "
  read -r ENDPOINT
  ENDPOINT=${ENDPOINT:-$detected_endpoint}

  echo -n "Egress interfaces (comma-separated), blank for ALL non-wg interfaces: "
  read -r EGRESS_IFS
  EGRESS_IFS=${EGRESS_IFS:-}

  export SUBNET SERVER_ADDR DNS_SERVERS WG_PORT ENDPOINT EGRESS_IFS
}

save_meta() {
  mkdir -p "${WG_STATE_DIR}"
  cat > "${WG_META_FILE}" <<META
SUBNET="${SUBNET}"
SERVER_ADDR="${SERVER_ADDR}"
DNS_SERVERS="${DNS_SERVERS}"
WG_PORT="${WG_PORT}"
ENDPOINT="${ENDPOINT}"
EGRESS_IFS="${EGRESS_IFS}"
META
}

load_meta() {
  if [[ -f "${WG_META_FILE}" ]]; then
    # shellcheck disable=SC1090
    . "${WG_META_FILE}"
  else
    echo "Server is not initialized. Run: $0 init" >&2
    exit 1
  fi
}

generate_server_keys() {
  if [[ -f "${WG_SERVER_PRIVKEY_FILE}" && -f "${WG_SERVER_PUBKEY_FILE}" ]]; then
    return
  fi
  umask 077
  wg genkey | tee "${WG_SERVER_PRIVKEY_FILE}" | wg pubkey > "${WG_SERVER_PUBKEY_FILE}"
}

write_server_conf() {
  local server_priv
  server_priv=$(cat "${WG_SERVER_PRIVKEY_FILE}")
  cat > "${WG_CONF}" <<CONF
[Interface]
Address = ${SERVER_ADDR}
ListenPort = ${WG_PORT}
PrivateKey = ${server_priv}
SaveConfig = false
CONF
  chmod 600 "${WG_CONF}"
}

render_nftables_conf() {
  local subnet_no_mask
  subnet_no_mask=$(echo "$SUBNET" | cut -d'/' -f1)
  local v4_subnet="$SUBNET"
  local egress_set_stmt=""
  local masquerade_rule="ip saddr ${v4_subnet} oifname != \"${WG_INTERFACE}\" masquerade"

  if [[ -n "${EGRESS_IFS}" ]]; then
    # Normalize interfaces list and build a set
    local ifs_csv="$EGRESS_IFS"
    local elements=()
    IFS=',' read -ra parts <<< "$ifs_csv"
    for p in "${parts[@]}"; do
      p=$(echo "$p" | xargs)
      [[ -z "$p" ]] && continue
      elements+=("\"$p\"")
    done
    if (( ${#elements[@]} > 0 )); then
      egress_set_stmt="set wg_egress_ifaces { type ifname; flags interval; elements = { ${elements[*]} } }"
      masquerade_rule="ip saddr ${v4_subnet} oifname @wg_egress_ifaces masquerade"
    fi
  fi

  cat > "${NFT_CONF_FILE}" <<NFT
table inet ${NFT_TABLE_NAME} {
  ${egress_set_stmt}

  chain input {
    type filter hook input priority filter; policy accept;
    udp dport ${WG_PORT} accept
  }

  chain forward {
    type filter hook forward priority filter; policy accept;
    iifname "${WG_INTERFACE}" accept
    oifname "${WG_INTERFACE}" accept
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ${masquerade_rule}
  }
}
NFT
}

reload_nftables() {
  print_header "Reloading nftables"
  nft -f "${NFT_MAIN_CONF}"
}

systemd_enable_wg() {
  systemctl enable "wg-quick@${WG_INTERFACE}.service"
  systemctl restart "wg-quick@${WG_INTERFACE}.service"
}

init_server() {
  require_root
  ensure_dirs
  ensure_commands || true
  if [[ -f "${WG_CONF}" ]]; then
    echo "${WG_CONF} already exists. Aborting to avoid overwrite." >&2
    exit 1
  fi

  prompt_init_values
  save_meta
  generate_server_keys
  write_server_conf
  render_nftables_conf
  reload_nftables
  systemd_enable_wg

  print_header "Server initialized"
  echo "Public key: $(cat "${WG_SERVER_PUBKEY_FILE}")"
}

allocate_next_ip() {
  # Finds the next free host IP in the subnet (IPv4 /x). Starts from .2
  local base mask base_prefix
  base=$(echo "$SUBNET" | cut -d'/' -f1)
  mask=$(echo "$SUBNET" | cut -d'/' -f2)
  base_prefix=$(echo "$base" | awk -F'.' '{print $1"."$2"."$3}')

  # Collect used last octets from server and peers
  local used last_oct
  used=$(awk -F'[ ./]' '/^Address\s*=/{print $4} /^AllowedIPs\s*=/{print $4}' "${WG_CONF}" | sort -n | uniq)

  for last_oct in $(seq 2 254); do
    if ! echo "$used" | grep -qx "$last_oct"; then
      echo "${base_prefix}.${last_oct}"
      return 0
    fi
  done
  echo "No available IPs in subnet ${SUBNET}" >&2
  return 1
}

add_client() {
  require_root
  ensure_dirs
  load_meta
  generate_server_keys
  local client_name="$1"
  if [[ -z "${client_name}" ]]; then
    echo "Usage: $0 add <client_name>" >&2
    exit 1
  fi
  if [[ -f "${WG_CLIENTS_DIR}/${client_name}.conf" ]]; then
    echo "Client ${client_name} already exists" >&2
    exit 1
  fi

  local client_ip
  client_ip=$(allocate_next_ip)

  umask 077
  local client_priv client_pub
  client_priv=$(wg genkey)
  client_pub=$(echo "$client_priv" | wg pubkey)
  local server_pub
  server_pub=$(cat "${WG_SERVER_PUBKEY_FILE}")

  # Update server config with peer block
  {
    echo "# BEGIN_PEER ${client_name}"
    echo "[Peer]"
    echo "# Name = ${client_name}"
    echo "PublicKey = ${client_pub}"
    echo "AllowedIPs = ${client_ip}/32"
    echo "# END_PEER ${client_name}"
  } >> "${WG_CONF}"

  # Create client config
  local endpoint_str="${ENDPOINT}"
  if [[ -n "${ENDPOINT}" && ! "${ENDPOINT}" =~ :[0-9]+$ ]]; then
    endpoint_str="${ENDPOINT}:${WG_PORT}"
  fi

  cat > "${WG_CLIENTS_DIR}/${client_name}.conf" <<CLI
[Interface]
PrivateKey = ${client_priv}
Address = ${client_ip}/32
DNS = ${DNS_SERVERS}

[Peer]
PublicKey = ${server_pub}
AllowedIPs = 0.0.0.0/0
Endpoint = ${endpoint_str}
PersistentKeepalive = 25
CLI
  chmod 600 "${WG_CLIENTS_DIR}/${client_name}.conf"

  # Apply changes without full restart
  if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}.service"; then
    wg syncconf "${WG_INTERFACE}" <(wg-quick strip "${WG_CONF}")
  else
    systemctl start "wg-quick@${WG_INTERFACE}.service"
  fi

  print_header "Client '${client_name}' added"
  echo "Config: ${WG_CLIENTS_DIR}/${client_name}.conf"
}

remove_client() {
  require_root
  ensure_dirs
  load_meta
  local client_name="$1"
  if [[ -z "${client_name}" ]]; then
    echo "Usage: $0 remove <client_name>" >&2
    exit 1
  fi

  if ! grep -q "# BEGIN_PEER ${client_name}" "${WG_CONF}"; then
    echo "Client ${client_name} not found in server config" >&2
    exit 1
  fi

  # Extract client public key to remove from running wg instance
  local client_pub
  client_pub=$(awk "/# BEGIN_PEER ${client_name}/{flag=1} flag && /^PublicKey/ {print \$3; exit} /# END_PEER ${client_name}/{flag=0}" "${WG_CONF}")

  # Remove peer block from server config
  awk "/# BEGIN_PEER ${client_name}/{flag=1; next} /# END_PEER ${client_name}/{flag=0; next} !flag" "${WG_CONF}" > "${WG_CONF}.tmp"
  mv "${WG_CONF}.tmp" "${WG_CONF}"

  # Remove from live config
  if [[ -n "${client_pub}" ]] && systemctl is-active --quiet "wg-quick@${WG_INTERFACE}.service"; then
    wg set "${WG_INTERFACE}" peer "${client_pub}" remove || true
  fi

  rm -f "${WG_CLIENTS_DIR}/${client_name}.conf"
  print_header "Client '${client_name}' removed"
}

list_clients() {
  ensure_dirs
  if [[ ! -f "${WG_CONF}" ]]; then
    echo "Server not initialized." >&2
    exit 1
  fi
  awk '
    /^# BEGIN_PEER / {name=$3}
    /^AllowedIPs/ {split($3, a, "/"); ip=a[1]; printf("%s\t%s\n", name, ip)}
  ' "${WG_CONF}" | sort
}

show_client() {
  local client_name="$1"
  if [[ -z "${client_name}" ]]; then
    echo "Usage: $0 show <client_name>" >&2
    exit 1
  fi
  local cfg="${WG_CLIENTS_DIR}/${client_name}.conf"
  if [[ ! -f "$cfg" ]]; then
    echo "Client config not found: $cfg" >&2
    exit 1
  fi
  cat "$cfg"
}

qrcode_client() {
  local client_name="$1"
  if ! command -v qrencode >/dev/null 2>&1; then
    echo "qrencode is not installed. Run: $0 install" >&2
    exit 1
  fi
  local cfg="${WG_CLIENTS_DIR}/${client_name}.conf"
  if [[ ! -f "$cfg" ]]; then
    echo "Client config not found: $cfg" >&2
    exit 1
  fi
  qrencode -t ansiutf8 < "$cfg"
}

regen_nft() {
  require_root
  load_meta
  render_nftables_conf
  reload_nftables
  print_header "nftables rules regenerated"
}

usage() {
  cat <<USAGE
WireGuard Ubuntu setup and manager (nftables-based NAT; multi- or all-interfaces)

Usage: $0 <command> [args]

Commands:
  install                 Install dependencies (wireguard, qrencode, nftables) and enable sysctl
  init                    Initialize server (choose subnet, server IP, DNS, port, endpoint, egress-ifaces)
  add <name>              Add a client and generate config
  remove <name>           Remove a client
  list                    List clients and assigned IPs
  show <name>             Show client config
  qrcode <name>           Print QR code for client config
  regen-nft               Re-render and reload nftables rules from saved meta

Notes:
  - NAT applies to ALL non-WireGuard interfaces by default (no single NIC selection).
  - To restrict NAT to specific egress interfaces, provide them during 'init' as a comma list.
  - Client configs are stored in ${WG_CLIENTS_DIR}.
USAGE
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    install)
      shift
      apt_install
      ;;
    init)
      shift
      apt_install
      init_server
      ;;
    add)
      shift
      [[ $# -ge 1 ]] || { usage; exit 1; }
      add_client "$1"
      ;;
    remove)
      shift
      [[ $# -ge 1 ]] || { usage; exit 1; }
      remove_client "$1"
      ;;
    list)
      shift
      list_clients
      ;;
    show)
      shift
      [[ $# -ge 1 ]] || { usage; exit 1; }
      show_client "$1"
      ;;
    qrcode)
      shift
      [[ $# -ge 1 ]] || { usage; exit 1; }
      qrcode_client "$1"
      ;;
    regen-nft)
      shift
      regen_nft
      ;;
    -h|--help|help|"")
      usage
      ;;
    *)
      echo "Unknown command: $cmd" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"

