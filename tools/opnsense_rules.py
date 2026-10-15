#!/usr/bin/env python3
"""Règles de la DMZ, du VLAN invités, du WireGuard et de l'IPsec d'OPNsense (site A), posées par l'API.

Idempotent : chaque règle est retrouvée par sa description et mise à jour,
pas recréée. Pas de retour arrière automatique : l'API d'OPNsense 26.7 n'a pas
de savepoint pour ces règles (404). Le script n'ajoute que des règles DMZ, INVITES,
WireGuard, IPsec et des Pass WAN → DMZ, WireGuard ou IPsec. Il ne touche pas à l'accès
d'administration du pare-feu (GUI, SSH).

Clé API : ~/.config/opnsense/apikey.txt (lignes key=… et secret=…, hors repo).
Usage : tools/opnsense_rules.py [--dry-run]
"""
import sys

from opnsense_api import api, check

ALIAS = {
    "name": "reseaux_prives",
    "type": "network",
    "content": "10.0.0.0/8\n172.16.0.0/12\n192.168.0.0/16",
    "description": "RFC 1918 (DMZ, INVITES : tout le privé est interdit sauf exceptions)",
}

# Lues de haut en bas (sequence), la première qui correspond décide.
# opt1 = DMZ (vtnet2, 10.10.30.1/24).
# opt2 = INVITES (VLAN 40 sur vtnet1, 10.10.40.1/24) : Internet seulement.
# wireguard = groupe des tunnels WireGuard (instance teletravail, wg0, 10.10.99.0/24),
# voir tools/opnsense_wireguard.py.
# enc0 = interface IPsec (tunnel vers fw-debian, voir tools/opnsense_ipsec.py).
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
    # --- INVITES (VLAN 40) ---
    dict(sequence=700, interface="opt2", action="pass", protocol="TCP/UDP",
         source_net="opt2", destination_net="opt2ip", destination_port="53",
         description="INVITES: DNS via OPNsense"),
    dict(sequence=710, interface="opt2", action="block", protocol="any",
         source_net="opt2", destination_net="reseaux_prives", log="1",
         description="INVITES: interdit vers les réseaux privés"),
    dict(sequence=720, interface="opt2", action="pass", protocol="TCP",
         source_net="opt2", destination_net="any", destination_port="80",
         description="INVITES: sortie HTTP"),
    dict(sequence=721, interface="opt2", action="pass", protocol="TCP",
         source_net="opt2", destination_net="any", destination_port="443",
         description="INVITES: sortie HTTPS"),
    dict(sequence=730, interface="opt2", action="pass", protocol="UDP",
         source_net="opt2", destination_net="any", destination_port="123",
         description="INVITES: NTP"),
    dict(sequence=740, interface="opt2", action="pass", protocol="ICMP",
         source_net="opt2", destination_net="any",
         description="INVITES: ping vers Internet"),
    # --- WireGuard (télétravail) ---
    dict(sequence=620, interface="wan", action="pass", protocol="UDP",
         source_net="any", destination_net="wanip", destination_port="51820",
         description="WireGuard: entrée du tunnel teletravail"),
    dict(sequence=800, interface="wireguard", action="pass", protocol="any",
         source_net="10.10.99.0/24", destination_net="lan",
         description="TELETRAVAIL: accès au LAN"),
    # Tunnel partagé (split tunnel) : le client ne doit rien y envoyer d'autre.
    dict(sequence=810, interface="wireguard", action="block", protocol="any",
         source_net="any", destination_net="any", log="1",
         description="TELETRAVAIL: interdit ailleurs"),
    # --- IPsec site à site avec fw-debian (site B), voir tools/opnsense_ipsec.py ---
    # OPNsense ajoute des règles automatiques équivalentes ; celles-ci les rendent explicites
    # et limitées au pair, comme sur fw-debian.
    dict(sequence=630, interface="wan", action="pass", protocol="UDP",
         source_net="192.168.122.120/32", destination_net="wanip", destination_port="500",
         description="IPsec: IKE depuis le site B"),
    dict(sequence=631, interface="wan", action="pass", protocol="UDP",
         source_net="192.168.122.120/32", destination_net="wanip", destination_port="4500",
         description="IPsec: IKE NAT-T depuis le site B"),
    dict(sequence=632, interface="wan", action="pass", protocol="ESP",
         source_net="192.168.122.120/32", destination_net="wanip",
         description="IPsec: ESP depuis le site B"),
    # enc0 = trafic déchiffré. Le LAN du site A ouvre vers le site B par sa règle par défaut.
    dict(sequence=900, interface="enc0", action="pass", protocol="any",
         source_net="10.10.20.0/24", destination_net="lan",
         description="SITE B: accès au LAN"),
    dict(sequence=910, interface="enc0", action="block", protocol="any",
         source_net="any", destination_net="any", log="1",
         description="SITE B: interdit ailleurs"),
]

DEFAULTS = dict(enabled="1", quick="1", direction="in", ipprotocol="inet",
                source_port="", destination_port="", log="0")


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
