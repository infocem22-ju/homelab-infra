#!/usr/bin/env python3
"""Supervision des deux pare-feu dans Zabbix, posée par l'API.

Importe le modèle zabbix/templates/pare-feu.yaml (« Pare-feu by Zabbix agent active »)
et le lie aux deux pare-feu :
- opnsense : hôte en agent actif seul, sans interface (l'agent est configuré par
  tools/opnsense_zabbix_agent.py). Groupe « Network Devices » et pas « Lab VMs » :
  ce groupe-là alimente l'inventaire AWX, qui tenterait du SSH.
- fw-debian : hôte existant (inscrit le 06/10), le modèle s'ajoute à ceux déjà liés.
Idempotent : import en création/mise à jour, hôtes retrouvés par leur nom.

Usage : tools/zabbix_firewalls.py [--dry-run]
"""
import json
import sys
import urllib.request
from pathlib import Path

# Mêmes identifiants que ansible/inventory/zabbix_inventory.yml (Zabbix de lab non exposé).
ZABBIX = "http://localhost:8081/api_jsonrpc.php"
LOGIN = ("Admin", "zabbix")
TEMPLATE_FILE = Path(__file__).resolve().parent.parent / "zabbix/templates/pare-feu.yaml"
TEMPLATE = "Pare-feu by Zabbix agent active"

OPNSENSE = dict(host="opnsense", group="Network Devices")
# Modèle essayé puis abandonné le 16/10 : Net-SNMP n'a pas la MIB pf (voir docs/pare-feu.md).
OLD_TEMPLATES = ["OPNsense by SNMP"]
LINUX_HOSTS = ["fw-debian"]

TOKEN = None


def call(method, params):
    headers = {"Content-Type": "application/json-rpc"}
    if TOKEN:
        headers["Authorization"] = f"Bearer {TOKEN}"
    body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1})
    req = urllib.request.Request(ZABBIX, data=body.encode(), headers=headers)
    with urllib.request.urlopen(req, timeout=20) as r:
        result = json.load(r)
    if "error" in result:
        sys.exit(f"Échec {method} : {result['error']}")
    return result["result"]


def templateid(name):
    found = call("template.get", {"filter": {"host": [name]}, "output": ["templateid"]})
    return found[0]["templateid"] if found else None


def import_template(dry):
    print(f"import du modèle {TEMPLATE} ({TEMPLATE_FILE.name})")
    if dry:
        return
    rules = {
        "template_groups": {"createMissing": True},
        "templates": {"createMissing": True, "updateExisting": True},
        "items": {"createMissing": True, "updateExisting": True, "deleteMissing": True},
        "triggers": {"createMissing": True, "updateExisting": True, "deleteMissing": True},
    }
    call("configuration.import", {"format": "yaml", "source": TEMPLATE_FILE.read_text(),
                                  "rules": rules})


def upsert_opnsense(fw_tid, dry):
    group = call("hostgroup.get", {"filter": {"name": [OPNSENSE["group"]]}, "output": ["groupid"]})[0]
    host = call("host.get", {"filter": {"host": [OPNSENSE["host"]]}, "output": ["hostid"],
                             "selectParentTemplates": ["templateid", "host"]})
    print(f"{'mise à jour' if host else 'création  '} hôte {OPNSENSE['host']} (agent actif, sans interface)")
    if dry:
        return
    params = dict(host=OPNSENSE["host"], groups=[group], templates=[{"templateid": fw_tid}],
                  interfaces=[], macros=[])
    if host:
        # templates_clear : retire aussi les éléments du modèle SNMP, pas seulement le lien.
        old = [{"templateid": t["templateid"]} for t in host[0]["parentTemplates"]
               if t["host"] in OLD_TEMPLATES]
        # En deux temps : l'interface SNMP ne se retire qu'une fois ses éléments supprimés.
        if old:
            call("host.update", {"hostid": host[0]["hostid"], "templates_clear": old})
        call("host.update", {**params, "hostid": host[0]["hostid"]})
    else:
        call("host.create", params)


def link_linux(fw_tid, dry):
    for name in LINUX_HOSTS:
        host = call("host.get", {"filter": {"host": [name]}, "output": ["hostid"],
                                 "selectParentTemplates": ["templateid"]})[0]
        linked = [t["templateid"] for t in host["parentTemplates"]]
        print(f"{name} : modèle {'déjà lié' if fw_tid in linked else 'à lier'}")
        if dry or fw_tid in linked:
            continue
        call("host.update", {"hostid": host["hostid"],
                             "templates": [{"templateid": t} for t in linked + [fw_tid]]})


def main(dry):
    global TOKEN
    TOKEN = call("user.login", {"username": LOGIN[0], "password": LOGIN[1]})
    import_template(dry)
    fw_tid = templateid(TEMPLATE) or "?"
    upsert_opnsense(fw_tid, dry)
    link_linux(fw_tid, dry)
    if not dry:
        print("appliqué")


if __name__ == "__main__":
    main("--dry-run" in sys.argv)
