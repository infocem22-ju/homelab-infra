#!/usr/bin/env python3
"""Agent Zabbix d'OPNsense (site A, plugin os-zabbix-agent), posé par l'API.

Agent actif seulement : il se connecte au serveur Zabbix (192.168.50.6, comme les VMs
du lab), et le mode passif n'écoute que sur 127.0.0.1. Les UserParameters donnent les
clés du modèle « Pare-feu by Zabbix agent active » (zabbix/templates/pare-feu.yaml),
les mêmes que sur fw-debian. pfctl et swanctl demandent root : option sudoRoot du
plugin, avec en garde-fous pas de commandes à distance et des UserParameters figés,
sans paramètres. Idempotent : les UserParameters sont retrouvés par leur clé.

Usage : tools/opnsense_zabbix_agent.py [--dry-run]
"""
import sys

from opnsense_api import api, check

SETTINGS = {
    "local": {"hostname": "opnsense"},  # nom de l'hôte dans Zabbix
    "settings": {
        "main": {
            "enabled": "1",
            "serverList": "127.0.0.1",  # passif : rien depuis le réseau
            "listenIP": "127.0.0.1",
            "sudoRoot": "1",
        },
        "features": {
            "enableActiveChecks": "1",
            "activeCheckServers": "192.168.50.6",
            "enableRemoteCommands": "0",
        },
    },
}

# Mêmes clés que zbx_userparameters dans host_vars/fw-debian.yml.
USERPARAMETERS = {
    "fw.states.count": "sudo pfctl -si | awk '/current entries/ {print $3}'",
    "fw.states.limit": "sudo pfctl -sm | awk '/^states/ {print $4}'",
    "fw.rules.count": "sudo pfctl -sr | wc -l | tr -d ' '",
    "fw.ipsec.sa": "sudo swanctl --list-sas 2>/dev/null | grep -c INSTALLED || true",
    "fw.wg.peers": ("sudo wg show all latest-handshakes | awk -v now=$(date +%s) "
                    "'$3 > 0 && now - $3 < 180 {n++} END {print n+0}'"),
}


def main(dry):
    print("réglages : actif vers 192.168.50.6, passif sur 127.0.0.1, sudoRoot")
    rows = api("zabbixagent/settings/search_userparameters")["rows"]
    existing = {r["key"]: r["uuid"] for r in rows}
    for key, command in USERPARAMETERS.items():
        uuid = existing.get(key)
        print(f"{'mise à jour' if uuid else 'création  '} UserParameter {key}")
        if dry:
            continue
        body = {"userparameter": dict(enabled="1", key=key, command=command, acceptParams="0")}
        path = (f"zabbixagent/settings/set_userparameter/{uuid}" if uuid
                else "zabbixagent/settings/add_userparameter")
        check(api(path, body), f"UserParameter {key}")
    if dry:
        return
    check(api("zabbixagent/settings/set", {"zabbixagent": SETTINGS}), "réglages")
    check(api("zabbixagent/service/reconfigure", {}), "reconfigure")
    print(f"appliqué, service : {api('zabbixagent/service/status')['status']}")


if __name__ == "__main__":
    main("--dry-run" in sys.argv)
