#!/usr/bin/env fish

set -l BASE BASE_PATH
set -l OLLAMA_DIR $BASE/ollama
set -l ZABBIX_DIR $BASE/zabbix
set -l LAB_SCRIPT $BASE/bootstrap/lab.sh

function pause_end
    echo
    read -P "Appuie sur Entrée pour continuer..."
end

function compose_is_up
    set -l dir $argv[1]

    if not test -d $dir
        return 1
    end

    set -l count (command docker compose -f $dir/docker-compose.yml ps -q 2>/dev/null | wc -l | string trim)
    test "$count" != "0"
end

function compose_status
    set -l name $argv[1]
    set -l dir $argv[2]

    if not test -f $dir/docker-compose.yml
        echo "[KO] $name : docker-compose.yml introuvable"
        return
    end

    if compose_is_up $dir
        echo "[OK] $name : actif"
    else
        echo "[--] $name : arrêté"
    end
end

function compose_up
    set -l name $argv[1]
    set -l dir $argv[2]

    echo "Démarrage de $name..."
    command docker compose -f $dir/docker-compose.yml up -d
end

function compose_down
    set -l name $argv[1]
    set -l dir $argv[2]

    echo "Arrêt de $name..."
    command docker compose -f $dir/docker-compose.yml down
end

function compose_restart
    set -l name $argv[1]
    set -l dir $argv[2]

    echo "Redémarrage de $name..."
    command docker compose -f $dir/docker-compose.yml down
    command docker compose -f $dir/docker-compose.yml up -d
end

function nodes_status
    echo "Statut des nodes :"
    bash $LAB_SCRIPT status
end

function nodes_up
    echo "Démarrage des nodes..."
    bash $LAB_SCRIPT up 2
end

function nodes_down
    echo "Arrêt / suppression des nodes..."
    bash $LAB_SCRIPT down
end

function show_global_status
    echo
    echo "===== État du homelab ====="
    compose_status "Ollama" $OLLAMA_DIR
    compose_status "Zabbix" $ZABBIX_DIR
    echo
    nodes_status
    echo "==========================="
    echo
end

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
    echo "  7) Démarrer les nodes"
    echo "  8) Voir le statut des nodes"
    echo "  9) Arrêter les nodes"
    echo
    echo "  s) Rafraîchir l'état"
    echo "  q) Quitter"
    echo

    read -P "Choix : " choice

    switch $choice
        case 1
            compose_up "Ollama" $OLLAMA_DIR
            pause_end
        case 2
            compose_down "Ollama" $OLLAMA_DIR
            pause_end
        case 3
            compose_restart "Ollama" $OLLAMA_DIR
            pause_end
        case 4
            compose_up "Zabbix" $ZABBIX_DIR
            pause_end
        case 5
            compose_down "Zabbix" $ZABBIX_DIR
            pause_end
        case 6
            compose_restart "Zabbix" $ZABBIX_DIR
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