#!/usr/bin/env python3
"""Règles de la DMZ d'OPNsense (site A), posées par l'API.

Idempotent : chaque règle est retrouvée par sa description et mise à jour,
pas recréée. Pas de retour arrière automatique : l'API d'OPNsense 26.7 n'a pas
de savepoint pour ces règles (404). Le script n'ajoute que des règles DMZ et
des Pass WAN → DMZ, il ne touche pas à l'accès au pare-feu lui-même.

Clé API : ~/.config/opnsense/apikey.txt (lignes key=… et secret=…, hors repo).
Usage : tools/opnsense_dmz_rules.py [--dry-run]
"""
import base64
import json
import ssl
import sys
import urllib.request
from pathlib import Path

OPNSENSE = "https://192.168.122.119"
KEYFILE = Path.home() / ".config/opnsense/apikey.txt"

ALIAS = {
    "name": "reseaux_prives",
    "type": "network",
    "content": "10.0.0.0/8\n172.16.0.0/12\n192.168.0.0/16",
    "description": "RFC 1918 (DMZ : tout le privé est interdit sauf exceptions)",
}

# Lues de haut en bas (sequence), la première qui correspond décide.
# opt1 = DMZ (vtnet2, 10.10.30.1/24).
RULES = [
    # --- DMZ ---
    dict(sequence=500, interface="opt1", action="pass", protocol="TCP/UDP",
         source_net="opt1", destination_net="opt1ip", destination_port="53",
         description="DMZ: DNS via OPNsense"),
    dict(sequence=510, interface="opt1", action="pass", protocol="TCP",
         source_net="opt1", destination_net="192.168.50.6", destination_port="10051",
         description="DMZ: agent Zabbix actif"),
    dict(sequence=520, interface="opt1", action="block", protocol="any",
         source_net="opt1", destination_net="lan", log="1",
         description="DMZ: interdit vers le LAN"),
    dict(sequence=530, interface="opt1", action="block", protocol="any",
         source_net="opt1", destination_net="reseaux_prives", log="1",
         description="DMZ: interdit vers les réseaux privés"),
    dict(sequence=540, interface="opt1", action="pass", protocol="TCP",
         source_net="opt1", destination_net="any", destination_port="80",
         description="DMZ: sortie HTTP (apt)"),
    dict(sequence=541, interface="opt1", action="pass", protocol="TCP",
         source_net="opt1", destination_net="any", destination_port="443",
         description="DMZ: sortie HTTPS (apt)"),
    dict(sequence=550, interface="opt1", action="pass", protocol="UDP",
         source_net="opt1", destination_net="any", destination_port="123",
         description="DMZ: NTP"),
    # --- WAN → DMZ (administration) ---
    dict(sequence=600, interface="wan", action="pass", protocol="TCP",
         source_net="192.168.122.148/32", destination_net="opt1", destination_port="22",
         description="DMZ: SSH depuis AWX"),
    dict(sequence=610, interface="wan", action="pass", protocol="ICMP",
         source_net="192.168.122.0/24", destination_net="opt1",
         description="DMZ: ping depuis le WAN (tests)"),
]

DEFAULTS = dict(enabled="1", quick="1", direction="in", ipprotocol="inet",
                source_port="", destination_port="", log="0")


def load_key():
    kv = dict(line.split("=", 1) for line in KEYFILE.read_text().split() if "=" in line)
    return base64.b64encode(f"{kv['key']}:{kv['secret']}".encode()).decode()


AUTH = load_key()
CTX = ssl._create_unverified_context()  # certificat auto-signé du lab


def api(path, body=None, timeout=10):
    headers = {"Authorization": f"Basic {AUTH}"}
    if body is not None:
        # Pas sur un GET : OPNsense répond 400 à un Content-Type JSON sans corps.
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(
        f"{OPNSENSE}/api/{path}",
        data=None if body is None else json.dumps(body).encode(),
        headers=headers,
        method="GET" if body is None else "POST",
    )
    with urllib.request.urlopen(req, context=CTX, timeout=timeout) as r:
        return json.load(r)


def check(result, what):
    if result.get("result") not in ("saved", "ok", "deleted") and result.get("status") != "ok":
        sys.exit(f"Échec {what} : {result}")


def upsert_alias(dry):
    rows = api("firewall/alias/search_item")["rows"]
    uuid = next((r["uuid"] for r in rows if r["name"] == ALIAS["name"]), None)
    print(f"alias {ALIAS['name']} : {'mise à jour' if uuid else 'création'}")
    if dry:
        return
    body = {"alias": {"enabled": "1", **ALIAS}}
    check(api(f"firewall/alias/set_item/{uuid}" if uuid else "firewall/alias/add_item", body),
          f"alias {ALIAS['name']}")
    check(api("firewall/alias/reconfigure", {}), "reconfigure des alias")


def upsert_rules(dry):
    rows = api("firewall/filter/search_rule")["rows"]
    existing = {r["description"]: r["uuid"] for r in rows}
    for rule in RULES:
        uuid = existing.get(rule["description"])
        print(f"{'mise à jour' if uuid else 'création  '} [{rule['sequence']}] {rule['description']}")
        if dry:
            continue
        body = {"rule": {**DEFAULTS, **rule}}
        path = f"firewall/filter/set_rule/{uuid}" if uuid else "firewall/filter/add_rule"
        check(api(path, body), rule["description"])


def apply():
    result = api("firewall/filter/apply", {})
    if result.get("status", "").strip() != "OK":
        sys.exit(f"Échec de l'application : {result}")
    api("firewall/filter/search_rule", timeout=15)  # l'API répond toujours
    print("appliqué")


if __name__ == "__main__":
    dry = "--dry-run" in sys.argv
    upsert_alias(dry)
    upsert_rules(dry)
    if not dry:
        apply()
