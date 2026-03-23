#!/usr/bin/env bash
set -euo pipefail

# Détecte l'utilisateur réel même sous sudo
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

PROJECT="${PROJECT:-lab}"
BASE_IMAGE="${BASE_IMAGE:-/var/lib/libvirt/images/debian-12-generic-amd64.qcow2}"
IMAGE_DIR="${IMAGE_DIR:-/var/lib/libvirt/images}"
SSH_KEY="${SSH_KEY:-$REAL_HOME/.ssh/homelab_ansible_ed25519}"
USER_NAME="${USER_NAME:-ansible}"
RAM="${RAM:-2048}"
VCPUS="${VCPUS:-2}"
DISK_SIZE="${DISK_SIZE:-20G}"
NETWORK="${NETWORK:-default}"
VIRSH="virsh --connect qemu:///system"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Manque: $1" >&2; exit 1; }; }
need virsh
need virt-install
need qemu-img
need cloud-localds

log() { printf "\n[%s] %s\n" "$PROJECT" "$*"; }

vm_list() {
  $VIRSH list --all --name | grep "^${PROJECT}-vm-" || true
}

vm_exists() {
  $VIRSH dominfo "$1" >/dev/null 2>&1
}

get_ip() {
  local name="$1"
  local mac
  mac=$($VIRSH dumpxml "$name" 2>/dev/null \
    | grep -o "address='[0-9a-f:]*'" \
    | head -1 \
    | cut -d"'" -f2)
  $VIRSH net-dhcp-leases "$NETWORK" 2>/dev/null \
    | awk -v mac="$mac" '$3 == mac {print $5}' \
    | cut -d/ -f1
}

cloud_init_iso() {
  local name="$1"
  local pubkey
  pubkey="$(cat "${SSH_KEY}.pub")"
  local tmpfile
  tmpfile="$(mktemp /tmp/cloud-init-XXXXXX.yml)"

  cat > "$tmpfile" <<CLOUDINIT
#cloud-config
hostname: ${name}
users:
  - name: ${USER_NAME}
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${pubkey}
CLOUDINIT

  cloud-localds "${IMAGE_DIR}/${name}-cidata.iso" "$tmpfile"
  rm -f "$tmpfile"
}

up() {
  local n="${1:-1}"

  if [ ! -f "$BASE_IMAGE" ]; then
    echo "Image de base introuvable : $BASE_IMAGE" >&2
    exit 1
  fi

  if [ ! -f "${SSH_KEY}.pub" ]; then
    echo "Clé SSH introuvable : ${SSH_KEY}.pub" >&2
    exit 1
  fi

  log "Création de $n VM(s)"

  for i in $(seq 1 "$n"); do
    local name="${PROJECT}-vm-${i}"

    if vm_exists "$name"; then
      log "$name existe déjà, skip"
      continue
    fi

    local disk="${IMAGE_DIR}/${name}.qcow2"

    log "Création disque $name"
    qemu-img create -f qcow2 -b "$BASE_IMAGE" -F qcow2 "$disk" "$DISK_SIZE" >/dev/null

    log "Génération cloud-init $name"
    cloud_init_iso "$name"

    log "Démarrage $name"
    virt-install \
      --connect qemu:///system \
      --name "$name" \
      --ram "$RAM" \
      --vcpus "$VCPUS" \
      --disk "path=${disk},format=qcow2" \
      --disk "path=${IMAGE_DIR}/${name}-cidata.iso,device=cdrom" \
      --os-variant debian12 \
      --network "network=${NETWORK}" \
      --graphics none \
      --noautoconsole \
      --import >/dev/null

    log "$name démarré"
  done

  log "Attente DHCP (15s)..."
  sleep 15
  status
}

down() {
  log "Suppression des VM du projet"
  vm_list | while read -r name; do
    [ -z "$name" ] && continue
    log "Suppression $name"
    $VIRSH destroy "$name" 2>/dev/null || true
    $VIRSH undefine "$name" --remove-all-storage 2>/dev/null || true
    rm -f "${IMAGE_DIR}/${name}-cidata.iso"
  done
}

status() {
  log "Status VMs"
  vm_list | while read -r name; do
    [ -z "$name" ] && continue
    local state ip
    state=$($VIRSH domstate "$name" 2>/dev/null || echo "inconnu")
    ip=$(get_ip "$name")
    printf " - %-20s state=%-20s ip=%s\n" "$name" "$state" "${ip:-en attente...}"
  done || true
}

case "${1:-}" in
  up)     up "${2:-1}" ;;
  down)   down ;;
  status) status ;;
  *)
    echo "Usage: $0 {up [N]|status|down}"
    echo "Env: PROJECT=$PROJECT RAM=$RAM VCPUS=$VCPUS DISK_SIZE=$DISK_SIZE"
    exit 1
    ;;
esac
