#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
OLLAMA_COMPOSE="$BASE/ollama/docker-compose.yml"
ZABBIX_COMPOSE="$BASE/zabbix/docker-compose.yml"
LAB_SCRIPT="$BASE/bootstrap/lab.sh"
PLAYBOOK_SITE="$BASE/ansible/playbooks/lab_site.yml"
PLAYBOOK_VMS_UP="$BASE/ansible/playbooks/proxmox_provision_vms.yml"
PLAYBOOK_VMS_DOWN="$BASE/ansible/playbooks/shutdown_lab_vms.yml"
INV_VMS_STATIC="$BASE/ansible/inventory/lab_vms_static.yml"
NODES_COUNT=2
RUNNER_DIR="$HOME/actions-runner"
PROXMOX_VM="proxmox-lab"
VIRSH="virsh -c qemu:///system"

TITLE="Homelab Control"

cd "$BASE"

# ---------------------------------------------------------------------------
# Statut
# ---------------------------------------------------------------------------

compose_running() {
    local f="$1"
    [[ -f "$f" ]] || { echo "introuvable"; return; }
    local n
    n=$(docker compose -f "$f" ps --format '{{.State}}' 2>/dev/null | grep -c '^running$' || true)
    [[ "$n" -gt 0 ]] && echo "✅ actif ($n)" || echo "⛔ arrêté"
}

nodes_running() {
    local n
    n=$(podman ps --filter "label=homelab.project=demo" --format '{{.Names}}' 2>/dev/null | wc -l)
    [[ "$n" -gt 0 ]] && echo "✅ $n node(s)" || echo "⛔ arrêté"
}

proxmox_state() {
    $VIRSH domstate "$PROXMOX_VM" 2>/dev/null || echo "inconnu"
}

proxmox_running() {
    local state
    state=$(LANG=C virsh -c qemu:///system domstate "$PROXMOX_VM" 2>/dev/null)
    [[ "$state" == *"running"* ]] && echo "✅ actif" || echo "⛔ arrêté"
}

lab_vms_running() {
    local state
    state=$(LANG=C virsh -c qemu:///system domstate "$PROXMOX_VM" 2>/dev/null)
    if [[ "$state" != *"running"* ]]; then
        echo "⛔ Proxmox arrêté"
        return
    fi
    local n
    n=$(ssh -i ~/.ssh/homelab_ansible_ed25519 -o ConnectTimeout=3 -o BatchMode=yes \
        root@192.168.122.106 "qm list" 2>/dev/null | grep -c "running" || true)
    [[ "$n" -gt 0 ]] && echo "✅ $n VM(s)" || echo "⛔ arrêtées"
}

zabbix_up() {
    local n
    n=$(docker compose -f "$ZABBIX_COMPOSE" ps --format '{{.State}}' 2>/dev/null | grep -c '^running$' || true)
    [[ "$n" -gt 0 ]]
}

build_status() {
    echo "Zabbix  : $(compose_running "$ZABBIX_COMPOSE")"
    echo "Proxmox : $(proxmox_running)"
    echo "VMs Lab : $(lab_vms_running)"
    echo "Nodes   : $(nodes_running)"
    echo "Ollama  : $(compose_running "$OLLAMA_COMPOSE")"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

run_action() {
    local label="$1"; shift
    local cmd=("$@")

    zenity --info \
        --title="$TITLE" \
        --text="⏳ $label en cours…" \
        --no-wrap \
        --timeout=1 2>/dev/null || true

    if "${cmd[@]}" >/dev/null 2>&1; then
        zenity --info --title="$TITLE" --text="✅ $label : succès" --no-wrap 2>/dev/null || true
    else
        zenity --error --title="$TITLE" --text="❌ $label : échec" --no-wrap 2>/dev/null || true
    fi
}

require_zabbix() {
    if ! zabbix_up; then
        zenity --error \
            --title="$TITLE" \
            --text="⚠️ Zabbix requis pour cette action.\nDémarre Zabbix d'abord." \
            --no-wrap 2>/dev/null || true
        return 1
    fi
}

submenu() {
    local title="$1"; shift
    local items=("$@")

    zenity --list \
        --title="$TITLE — $title" \
        --text="$title" \
        --column="Action" \
        --width=340 --height=280 \
        --hide-header \
        2>/dev/null \
        "${items[@]}" || true
}

# ---------------------------------------------------------------------------
# Sous-menus
# ---------------------------------------------------------------------------

menu_zabbix() {
    local choice
    choice=$(submenu "Zabbix" \
        "▶  Démarrer" \
        "■  Arrêter" \
    ) || return
    case "$choice" in
        "▶  Démarrer") run_action "Zabbix start" docker compose -f "$ZABBIX_COMPOSE" up -d ;;
        "■  Arrêter")  run_action "Zabbix stop"  docker compose -f "$ZABBIX_COMPOSE" down ;;
    esac
}

menu_proxmox() {
    local choice
    choice=$(submenu "Proxmox" \
        "▶  Démarrer $PROXMOX_VM" \
        "■  Arrêter $PROXMOX_VM" \
    ) || return
    case "$choice" in
        "▶  Démarrer $PROXMOX_VM") run_action "Proxmox start" $VIRSH start "$PROXMOX_VM" ;;
        "■  Arrêter $PROXMOX_VM")  run_action "Proxmox stop"  $VIRSH shutdown "$PROXMOX_VM" ;;
    esac
}

menu_vms() {
    local choice
    choice=$(submenu "VMs Lab  (⚠ Zabbix requis)" \
        "▶  Démarrer les VMs" \
        "■  Arrêter les VMs" \
    ) || return
    case "$choice" in
        "▶  Démarrer les VMs")
    require_zabbix || return
    run_action "VMs up" bash -c "cd '$BASE' && ansible-playbook ansible/playbooks/proxmox_provision_vms.yml"
    ;;
        "■  Arrêter les VMs")
    run_action "VMs down" bash -c "cd '$BASE' && ansible-playbook -i ansible/inventory/lab_vms_static.yml ansible/playbooks/shutdown_lab_vms.yml"
    ;;
    esac
}

menu_nodes() {
    local choice
    choice=$(submenu "Nodes (containers Podman)" \
        "▶  Démarrer les nodes" \
        "■  Arrêter les nodes" \
        "🚀 Déployer site Hugo" \
    ) || return
    case "$choice" in
        "▶  Démarrer les nodes") run_action "Nodes up"   bash "$LAB_SCRIPT" up "$NODES_COUNT" ;;
        "■  Arrêter les nodes")  run_action "Nodes down" bash "$LAB_SCRIPT" down ;;
        "🚀 Déployer site Hugo") run_action "Hugo deploy" \
            ansible-playbook -i "$BASE/ansible/inventory/inventory.yml" "$PLAYBOOK_SITE" ;;
    esac
}

menu_ollama() {
    local choice
    choice=$(submenu "Ollama" \
        "▶  Démarrer" \
        "■  Arrêter" \
    ) || return
    case "$choice" in
        "▶  Démarrer") run_action "Ollama start" docker compose -f "$OLLAMA_COMPOSE" up -d ;;
        "■  Arrêter")  run_action "Ollama stop"  docker compose -f "$OLLAMA_COMPOSE" down ;;
    esac
}

menu_runner() {
    local choice
    choice=$(submenu "Runner GitHub" \
        "▶  Démarrer le runner" \
        "■  Arrêter le runner" \
    ) || return
    case "$choice" in
        "▶  Démarrer le runner")
            bash -c "cd '$RUNNER_DIR' && nohup ./run.sh >/tmp/runner.log 2>&1 &"
            zenity --info --title="$TITLE" --text="✅ Runner démarré" --no-wrap 2>/dev/null || true
            ;;
        "■  Arrêter le runner")
            pkill -f 'Runner.Listener' >/dev/null 2>&1 || true
            zenity --info --title="$TITLE" --text="✅ Runner arrêté" --no-wrap 2>/dev/null || true
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Tout arrêter
# ---------------------------------------------------------------------------

stop_all() {
    zenity --question \
        --title="$TITLE" \
        --text="Arrêter toute la stack ?\n\nOrdre : VMs guests → Proxmox → Zabbix → Ollama → Nodes → Runner" \
        --no-wrap 2>/dev/null || return

    # 1. VMs guests (inventory statique, pas de dépendance Zabbix)
    ansible-playbook -i "$INV_VMS_STATIC" "$PLAYBOOK_VMS_DOWN" >/dev/null 2>&1 || true

    # 2. VM Proxmox
    $VIRSH shutdown "$PROXMOX_VM" >/dev/null 2>&1 || true

    # 3. Reste de la stack
    docker compose -f "$ZABBIX_COMPOSE" down >/dev/null 2>&1 || true
    docker compose -f "$OLLAMA_COMPOSE" down >/dev/null 2>&1 || true
    bash "$LAB_SCRIPT" down >/dev/null 2>&1 || true
    pkill -f 'Runner.Listener' >/dev/null 2>&1 || true

    zenity --info --title="$TITLE" --text="✅ Stack arrêtée" --no-wrap 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Menu principal
# ---------------------------------------------------------------------------

while true; do
    STATUS="$(build_status)"

    CHOICE=$(zenity --list \
        --title="$TITLE" \
        --text="$STATUS\n\nChoisir une catégorie :" \
        --column="Action" \
        --width=380 --height=420 \
        --hide-header \
        2>/dev/null \
        "🔍 Zabbix" \
        "🖥  Proxmox" \
        "💻 VMs Lab" \
        "📦 Nodes (containers)" \
        "🤖 Ollama" \
        "🏃 Runner GitHub" \
        "⏹  Tout arrêter" \
        "⏻  Quitter" \
    ) || break

    case "$CHOICE" in
        "🔍 Zabbix")            menu_zabbix ;;
        "🖥  Proxmox")          menu_proxmox ;;
        "💻 VMs Lab")           menu_vms ;;
        "📦 Nodes (containers)") menu_nodes ;;
        "🤖 Ollama")            menu_ollama ;;
        "🏃 Runner GitHub")     menu_runner ;;
        "⏹  Tout arrêter")     stop_all ;;
        "⏻  Quitter")          break ;;
    esac
done