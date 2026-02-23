#!/usr/bin/env fish
cd (dirname (status --current-filename))
docker compose -p zabbix $argv
#!/usr/bin/env fish
set -l script_dir (cd (dirname (status --current-filename)); and pwd)

# Bloque les commandes destructrices par défaut
if test (count $argv) -ge 2
    if test "$argv[1]" = "down"; and test "$argv[2]" = "-v"
        echo "Refus: 'down -v' supprime les volumes (DB). Utilise 'docker compose down' sans -v."
        exit 1
    end
end

docker compose -p homelab-infra -f "$script_dir/docker-compose.yml" $argv
