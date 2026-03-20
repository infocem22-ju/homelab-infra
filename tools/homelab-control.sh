#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
OLLAMA_COMPOSE="$BASE/ollama/docker-compose.yml"
ZABBIX_COMPOSE="$BASE/zabbix/docker-compose.yml"
LAB_SCRIPT="$BASE/bootstrap/lab.sh"
PLAYBOOK_SITE="$BASE/ansible/playbooks/lab_site.yml"
NODES_COUNT=2

TITLE="Homelab Control"

# ---------------------------------------------------------------------------
# Statut
# ---------------------------------------------------------------------------
cd "$BASE"  


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

build_status() {
    echo "Ollama  : $(compose_running "$OLLAMA_COMPOSE")"
    echo "Zabbix  : $(compose_running "$ZABBIX_COMPOSE")"
    echo "Nodes   : $(nodes_running)"
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

run_action() {
    local label="$1"; shift
    local cmd=("$@")

    zenity --info \
        --title="$TITLE" \
        --text="⏳ $label en cours…" \
        --no-wrap \
        --timeout=1 2>/dev/null || true

    "${cmd[@]}" >/dev/null 2>&1 && \
        zenity --info --title="$TITLE" --text="✅ $label : succès" --no-wrap 2>/dev/null || \
        zenity --error --title="$TITLE" --text="❌ $label : échec" --no-wrap 2>/dev/null
    true
}

run_ansible() {
    local label="$1"
    local playbook="$2"

    run_action "$label" \
        ansible-playbook -i "$BASE/ansible/inventory/inventory.yml" "$playbook"
}

stop_all() {
    zenity --question \
        --title="$TITLE" \
        --text="Arrêter Ollama, Zabbix et les nodes ?" \
        --no-wrap 2>/dev/null || return

    docker compose -f "$OLLAMA_COMPOSE" down >/dev/null 2>&1 || true
    docker compose -f "$ZABBIX_COMPOSE" down >/dev/null 2>&1 || true
    bash "$LAB_SCRIPT" down >/dev/null 2>&1 || true

    zenity --info --title="$TITLE" --text="✅ Tout arrêté" --no-wrap 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Menu principal
# ---------------------------------------------------------------------------

while true; do
    STATUS="$(build_status)"

    CHOICE=$(zenity --list \
        --title="$TITLE" \
        --text="$STATUS\n\nChoisir une action :" \
        --column="Action" \
        --width=380 --height=460 \
        --hide-header \
        2>/dev/null \
        "▶  Démarrer Ollama" \
        "■  Arrêter Ollama" \
        "▶  Démarrer Zabbix" \
        "■  Arrêter Zabbix" \
        "▶  Démarrer les nodes" \
        "■  Arrêter les nodes" \
        "🚀 Déployer site Hugo" \
        "⏹  Tout arrêter" \
        "⏻  Quitter" \
    ) || break

    case "$CHOICE" in
        "▶  Démarrer Ollama")    run_action "Ollama start"  docker compose -f "$OLLAMA_COMPOSE" up -d ;;
        "■  Arrêter Ollama")     run_action "Ollama stop"   docker compose -f "$OLLAMA_COMPOSE" down ;;
        "▶  Démarrer Zabbix")    run_action "Zabbix start"  docker compose -f "$ZABBIX_COMPOSE" up -d ;;
        "■  Arrêter Zabbix")     run_action "Zabbix stop"   docker compose -f "$ZABBIX_COMPOSE" down ;;
        "▶  Démarrer les nodes") run_action "Nodes up"      bash "$LAB_SCRIPT" up "$NODES_COUNT" ;;
        "■  Arrêter les nodes")  run_action "Nodes down"    bash "$LAB_SCRIPT" down ;;
        "🚀 Déployer site Hugo") run_ansible "Déploiement Hugo" "$PLAYBOOK_SITE" ;;
        "⏹  Tout arrêter") stop_all ;;
        "⏻  Quitter")           break ;;
    esac
done
