#!/usr/bin/env fish

set -l BASE BASE_PATH
set -l OLLAMA_COMPOSE $BASE/ollama/docker-compose.yml
set -l ZABBIX_COMPOSE $BASE/zabbix/docker-compose.yml
set -l LAB_SCRIPT $BASE/bootstrap/lab.sh
set -l NODES_COUNT 2

# ---------------------------------------------------------------------------
# Utilitaires
# ---------------------------------------------------------------------------

function pause_end
    echo
    read -P "Appuie sur Entrée pour continuer..."
end

function compose_exists
    test -f $argv[1]
end

# ---------------------------------------------------------------------------
# Fonctions compose
# ---------------------------------------------------------------------------

function compose_container_ids
    set -l compose_file $argv[1]

    if not compose_exists $compose_file
        return 1
    end

    set -l fmt '{{.ID}}'
    set -l raw (docker compose -f $compose_file ps --format $fmt 2>/dev/null)
    echo "DEBUG fmt raw: '$raw'" >&2
    echo $raw
end

function compose_running_count
    set -l compose_file $argv[1]

    if not compose_exists $compose_file
        echo 0
        return 1
    end

    set -l ids (compose_container_ids $compose_file)

    if test (count $ids) -eq 0
        echo 0
        return 0
    end

    set -l running_count 0

    for id in $ids
        set -l state (command docker inspect -f '{{.State.Status}}' $id 2>/dev/null | string trim | string replace -r '\r' '')
        if test "$state" = "running"
            set running_count (math $running_count + 1)
        end
    end

    echo $running_count
end

function compose_total_count
    set -l compose_file $argv[1]

    if not compose_exists $compose_file
        echo 0
        return 1
    end

    set -l ids (compose_container_ids $compose_file)
    echo (count $ids)
end

function compose_status
    set -l name $argv[1]
    set -l compose_file $argv[2]

    if not compose_exists $compose_file
        echo "[KO] $name : compose introuvable ($compose_file)"
        return
    end

    set -l total (compose_total_count $compose_file)
    set -l running (compose_running_count $compose_file)

    echo "DEBUG $name : total='$total' running='$running'"  # ← ajoute ça
    ...
end

function compose_up
    set -l name $argv[1]
    set -l compose_file $argv[2]

    if not compose_exists $compose_file
        echo "Compose introuvable pour $name : $compose_file"
        return 1
    end

    echo "Démarrage de $name..."
    command docker compose -f $compose_file up -d
end

function compose_down
    set -l name $argv[1]
    set -l compose_file $argv[2]

    if not compose_exists $compose_file
        echo "Compose introuvable pour $name : $compose_file"
        return 1
    end

    echo "Arrêt de $name..."
    command docker compose -f $compose_file down
end

function compose_restart
    set -l name $argv[1]
    set -l compose_file $argv[2]

    if not compose_exists $compose_file
        echo "Compose introuvable pour $name : $compose_file"
        return 1
    end

    echo "Redémarrage de $name..."
    command docker compose -f $compose_file down
    command docker compose -f $compose_file up -d
end

# ---------------------------------------------------------------------------
# Fonctions nodes
# ---------------------------------------------------------------------------

function nodes_status
    if not test -f $LAB_SCRIPT
        echo "[KO] Nodes lab : script introuvable ($LAB_SCRIPT)"
        return 1
    end

    echo "Statut des nodes :"
    bash $LAB_SCRIPT status
end

function nodes_up
    if not test -f $LAB_SCRIPT
        echo "Script nodes introuvable : $LAB_SCRIPT"
        return 1
    end

    echo "Démarrage de $NODES_COUNT node(s)..."
    bash $LAB_SCRIPT up $NODES_COUNT
end

function nodes_down
    if not test -f $LAB_SCRIPT
        echo "Script nodes introuvable : $LAB_SCRIPT"
        return 1
    end

    echo "Arrêt / suppression des nodes..."
    bash $LAB_SCRIPT down
end

# ---------------------------------------------------------------------------
# Affichage global
# ---------------------------------------------------------------------------

function show_global_status
    echo
    echo "===== État du homelab ====="
    compose_status "Ollama" $OLLAMA_COMPOSE
    compose_status "Zabbix" $ZABBIX_COMPOSE
    echo
    nodes_status
    echo "==========================="
    echo
end

# ---------------------------------------------------------------------------
# Boucle principale
# ---------------------------------------------------------------------------

while true
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
    set -l out (command docker compose -f BASE_PATH/zabbix/docker-compose.yml ps -q 2>/dev/null)
    echo "out='$out'"
    read -P "Choix : " choice

    switch $choice
        case 1
            compose_up "Ollama" $OLLAMA_COMPOSE
            pause_end
        case 2
            compose_down "Ollama" $OLLAMA_COMPOSE
            pause_end
        case 3
            compose_restart "Ollama" $OLLAMA_COMPOSE
            pause_end
        case 4
            compose_up "Zabbix" $ZABBIX_COMPOSE
            pause_end
        case 5
            compose_down "Zabbix" $ZABBIX_COMPOSE
            pause_end
        case 6
            compose_restart "Zabbix" $ZABBIX_COMPOSE
            pause_end
        case 7
            nodes_up
            pause_end
        case 8
            nodes_status
            pause_end
        case 9
            nodes_down
            pause_end
        case s S
            continue
        case q Q
            exit 0
        case '*'
            echo "Choix invalide."
            pause_end
    end
end