#!/usr/bin/env bash

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
OLLAMA_COMPOSE=$BASE/ollama/docker-compose.yml
ZABBIX_COMPOSE=$BASE/zabbix/docker-compose.yml
LAB_SCRIPT=$BASE/bootstrap/lab.sh
NODES_COUNT=2

# ---------------------------------------------------------------------------
# Utilitaires
# ---------------------------------------------------------------------------

pause_end() {
    echo
    read -rp "Appuie sur Entrée pour continuer..."
}

compose_exists() {
    local compose_file=$1
    [[ -f "$compose_file" ]]
}

# ---------------------------------------------------------------------------
# Fonctions compose
# ---------------------------------------------------------------------------

compose_running_count() {
    local compose_file=$1

    if ! compose_exists "$compose_file"; then
        echo 0
        return 1
    fi

    docker compose -f "$compose_file" ps --format '{{.State}}' 2>/dev/null \
        | grep -c '^running$' || echo 0
}

compose_total_count() {
    local compose_file=$1

    if ! compose_exists "$compose_file"; then
        echo 0
        return 1
    fi

    local total
    total=$(docker compose -f "$compose_file" ps --format '{{.Name}}' 2>/dev/null | grep -c '.')
    echo "$total"
}

compose_status() {
    local name=$1
    local compose_file=$2

    if ! compose_exists "$compose_file"; then
        echo "[KO] $name : compose introuvable ($compose_file)"
        return
    fi

    local total running
    total=$(compose_total_count "$compose_file")
    running=$(compose_running_count "$compose_file")

    if [[ "$total" -eq 0 ]]; then
        echo "[--] $name : arrêté"
    elif [[ "$running" -gt 0 ]]; then
        echo "[OK] $name : $running/$total container(s) actif(s)"
    else
        echo "[--] $name : présent mais arrêté ($total container(s))"
    fi
}

compose_up() {
    local name=$1
    local compose_file=$2

    if ! compose_exists "$compose_file"; then
        echo "Compose introuvable pour $name : $compose_file"
        return 1
    fi

    echo "Démarrage de $name..."
    docker compose -f "$compose_file" up -d
}

compose_down() {
    local name=$1
    local compose_file=$2

    if ! compose_exists "$compose_file"; then
        echo "Compose introuvable pour $name : $compose_file"
        return 1
    fi

    echo "Arrêt de $name..."
    docker compose -f "$compose_file" down
}

compose_restart() {
    local name=$1
    local compose_file=$2

    if ! compose_exists "$compose_file"; then
        echo "Compose introuvable pour $name : $compose_file"
        return 1
    fi

    echo "Redémarrage de $name..."
    docker compose -f "$compose_file" down
    docker compose -f "$compose_file" up -d
}

# ---------------------------------------------------------------------------
# Fonctions nodes
# ---------------------------------------------------------------------------

nodes_status() {
    if [[ ! -f "$LAB_SCRIPT" ]]; then
        echo "[KO] Nodes lab : script introuvable ($LAB_SCRIPT)"
        return 1
    fi

    echo "Statut des nodes :"
    bash "$LAB_SCRIPT" status
}

nodes_up() {
    if [[ ! -f "$LAB_SCRIPT" ]]; then
        echo "Script nodes introuvable : $LAB_SCRIPT"
        return 1
    fi

    echo "Démarrage de $NODES_COUNT node(s)..."
    bash "$LAB_SCRIPT" up "$NODES_COUNT"
}

nodes_down() {
    if [[ ! -f "$LAB_SCRIPT" ]]; then
        echo "Script nodes introuvable : $LAB_SCRIPT"
        return 1
    fi

    echo "Arrêt / suppression des nodes..."
    bash "$LAB_SCRIPT" down
}

# ---------------------------------------------------------------------------
# Affichage global
# ---------------------------------------------------------------------------

show_global_status() {
    echo
    echo "===== État du homelab ====="
    compose_status "Ollama" "$OLLAMA_COMPOSE"
    compose_status "Zabbix" "$ZABBIX_COMPOSE"
    echo
    nodes_status
    echo "==========================="
    echo
}

# ---------------------------------------------------------------------------
# Boucle principale
# ---------------------------------------------------------------------------

while true; do
    clear
    show_global_status

    echo "Menu :"
    echo "  1) Démarrer Ollama"
    echo "  2) Arrêter Ollama"
    echo "  3) Redémarrer Ollama"
    echo
    echo "  4) Démarrer Zabbix"
    echo "  5) Arrêter Zabbix"
    echo "  6) Redémarrer Zabbix"
    echo
    echo "  7) Démarrer les nodes ($NODES_COUNT)"
    echo "  8) Voir le statut des nodes"
    echo "  9) Arrêter les nodes"
    echo
    echo "  s) Rafraîchir l'état"
    echo "  q) Quitter"
    echo

    read -rp "Choix : " choice

    case "$choice" in
        1) compose_up      "Ollama" "$OLLAMA_COMPOSE" ; pause_end ;;
        2) compose_down    "Ollama" "$OLLAMA_COMPOSE" ; pause_end ;;
        3) compose_restart "Ollama" "$OLLAMA_COMPOSE" ; pause_end ;;
        4) compose_up      "Zabbix" "$ZABBIX_COMPOSE" ; pause_end ;;
        5) compose_down    "Zabbix" "$ZABBIX_COMPOSE" ; pause_end ;;
        6) compose_restart "Zabbix" "$ZABBIX_COMPOSE" ; pause_end ;;
        7) nodes_up   ; pause_end ;;
        8) nodes_status ; pause_end ;;
        9) nodes_down ; pause_end ;;
        s|S) continue ;;
        q|Q) exit 0 ;;
        *) echo "Choix invalide." ; pause_end ;;
    esac
done
