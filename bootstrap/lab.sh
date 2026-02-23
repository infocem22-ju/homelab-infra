#!/usr/bin/env bash
set -euo pipefail

PROJECT="${PROJECT:-demo}"
IMAGE="${IMAGE:-debian:12}"
USER_NAME="${USER_NAME:-ansible}"
ANSIBLE_DIR="${ANSIBLE_DIR:-./ansible}"
INV_FILE="${INV_FILE:-$ANSIBLE_DIR/inventory.yml}"
NET_NAME="${NET_NAME:-${PROJECT}-net}"
SSH_PORT_BASE="${SSH_PORT_BASE:-2220}"   # node-1 => 2221, node-2 => 2222, ...
SSH_KEY="${SSH_KEY:-$HOME/.ssh/homelab_ansible_ed25519}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Manque: $1" >&2; exit 1; }; }
need podman
need ssh-keygen

log() { printf "\n[%s] %s\n" "$PROJECT" "$*"; }

lab_containers() {
  podman ps -a --filter "label=homelab.project=${PROJECT}" --format '{{.Names}}'
}

ensure_net() {
  if ! podman network exists "$NET_NAME" >/dev/null 2>&1; then
    log "Création réseau $NET_NAME"
    podman network create "$NET_NAME" >/dev/null
  fi
}

container_ip() {
  podman inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$v.IPAddress}}{{end}}' "$1"
}

ensure_ssh_key() {
  mkdir -p "$(dirname "$SSH_KEY")"
  chmod 700 "$(dirname "$SSH_KEY")"
  if [ ! -f "$SSH_KEY" ]; then
    log "Génération clé SSH lab ($SSH_KEY)"
    umask 077
    ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" -C "homelab-ansible" >/dev/null
  fi
}

bootstrap_container() {
  local name="$1"
  local pubkey
pubkey="$(cat "$SSH_KEY.pub")"

  podman exec -i "$name" bash -s -- "$USER_NAME" "$pubkey" <<'BASH'

set -euo pipefail
USER_NAME="$1"
PUBKEY="$2"

export DEBIAN_FRONTEND=noninteractive

# Wait apt/dpkg locks (defensive)
while fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
  sleep 0.2
done

apt-get update -y >/dev/null
apt-get install -y openssh-server sudo python3 ca-certificates iproute2 >/dev/null

# Create user
if ! id "$USER_NAME" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$USER_NAME"
fi

# Passwordless sudo
mkdir -p /etc/sudoers.d
echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USER_NAME"
chmod 440 "/etc/sudoers.d/$USER_NAME"

# SSH key

install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "/home/$USER_NAME/.ssh"
printf "%s\n" "$PUBKEY" > "/home/$USER_NAME/.ssh/authorized_keys"
chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.ssh/authorized_keys"
chmod 600 "/home/$USER_NAME/.ssh/authorized_keys"

# Start sshd (no systemd)
mkdir -p /run/sshd
ssh-keygen -A >/dev/null 2>&1 || true
pgrep -x sshd >/dev/null 2>&1 || /usr/sbin/sshd
BASH
}

node_port() {
  local idx="$1"
  echo $((SSH_PORT_BASE + idx))
}

inventory() {
  mkdir -p "$ANSIBLE_DIR"
  log "Génération inventaire Ansible: $INV_FILE"

  {
    echo "all:"
    echo "  hosts:"

    while read -r c; do
      [ -z "$c" ] && continue
      idx="${c##*-node-}"
      echo "    ${c}:"
      echo "      ansible_host: 127.0.0.1"
      echo "      ansible_port: $((SSH_PORT_BASE + idx))"
    done < <(lab_containers | sort)
  } > "$INV_FILE"
}

status() {
  log "Status nœuds"
  lab_containers | sort | while read -r c; do
    [ -z "$c" ] && continue
    ip="$(container_ip "$c")"
    idx="${c##*-node-}"
    port="$((SSH_PORT_BASE + idx))"
    printf " - %-20s ip=%-15s ssh=127.0.0.1:%s\n" "$c" "${ip:-?}" "$port"
    podman port "$c" || true
  done || true
}

up() {
  local n="${1:-2}"
  ensure_net
  ensure_ssh_key
  log "Création de $n nœud(s) (image: $IMAGE) + ports SSH localhost"

  for i in $(seq 1 "$n"); do
    local name="${PROJECT}-node-${i}"
    local ssh_port
    ssh_port="$(node_port "$i")"

    if podman container exists "$name" >/dev/null 2>&1; then
      log "$name existe déjà, skip"
      continue
    fi

    log "Création $name (ssh 127.0.0.1:${ssh_port} -> 22)"
    podman run -d \
      --name "$name" \
      --label "homelab.project=${PROJECT}" \
      --network "$NET_NAME" \
      -p "127.0.0.1:${ssh_port}:22" \
      "$IMAGE" \
      bash -lc "sleep infinity" >/dev/null

    bootstrap_container "$name"
    log "$name prêt"
  done

  inventory
  status
}

down() {
  log "Suppression des conteneurs du projet"
  lab_containers | while read -r c; do
    [ -z "$c" ] && continue
    log "rm $c"
    podman rm -f "$c" >/dev/null || true
  done || true

  if podman network exists "$NET_NAME" >/dev/null 2>&1; then
    log "Suppression réseau $NET_NAME"
    podman network rm "$NET_NAME" >/dev/null || true
  fi
}

case "${1:-}" in
  up) up "${2:-2}" ;;
  inventory) inventory ;;
  status) status ;;
  down) down ;;
  *)
    echo "Usage: $0 {up [N]|inventory|status|down}"
    echo "Env: PROJECT=$PROJECT IMAGE=$IMAGE USER_NAME=$USER_NAME SSH_PORT_BASE=$SSH_PORT_BASE"
    exit 1
    ;;
esac
