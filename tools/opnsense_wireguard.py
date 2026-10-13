#!/usr/bin/env python3
"""WireGuard d'OPNsense (site A) : instance « teletravail » et ses pairs, posés par l'API.

Idempotent : instance et pairs sont retrouvés par leur nom et mis à jour, pas recréés.
Clés : celle du serveur est générée par OPNsense (wireguard/server/key_pair) à la
création de l'instance, et ne transite qu'en mémoire dans ce script (jamais écrite ni
affichée, jamais renvoyée lors d'une mise à jour). Celles des clients restent sur les
clients (rôle Ansible wireguard_client, qui affiche la clé publique à recopier ici).
Les règles de filtrage du tunnel sont dans tools/opnsense_rules.py.

Usage : tools/opnsense_wireguard.py [--dry-run]
"""
import sys

from opnsense_api import api, check

SERVER = dict(
    name="teletravail",
    port="51820",
    tunneladdress="10.10.99.1/24",
    instance="0",  # interface wg0
)

# Un pair par client. tunneladdress = son adresse dans le tunnel, en /32 :
# c'est aussi le filtre d'entrée (AllowedIPs côté serveur).
PEERS = [
    dict(name="lab-vm-2", pubkey="Qk4nVF0KOUWuWjy3tviUczRRNGURi/TI6rn4IVuAnQU=",
         tunneladdress="10.10.99.2/32"),
]


def upsert(kind, item, body_key, dry):
    """Crée ou met à jour un objet WireGuard (server ou client) retrouvé par son nom."""
    rows = api(f"wireguard/{kind}/search_{kind}")["rows"]
    uuid = next((r["uuid"] for r in rows if r["name"] == item["name"]), None)
    print(f"{'mise à jour' if uuid else 'création  '} {kind} {item['name']}")
    if dry:
        return uuid
    if kind == "server" and not uuid:
        keys = api("wireguard/server/key_pair")
        item = {**item, "privkey": keys["privkey"], "pubkey": keys["pubkey"]}
    path = f"wireguard/{kind}/set_{kind}/{uuid}" if uuid else f"wireguard/{kind}/add_{kind}"
    result = api(path, {body_key: {"enabled": "1", **item}})
    check(result, f"{kind} {item['name']}")
    return uuid or result["uuid"]


def main(dry):
    peer_uuids = [upsert("client", peer, "client", dry) for peer in PEERS]
    server_uuid = upsert("server", {**SERVER, "peers": ",".join(filter(None, peer_uuids))},
                         "server", dry)
    if dry:
        return
    server = api(f"wireguard/server/get_server/{server_uuid}")["server"]
    check(api("wireguard/general/set", {"general": {"enabled": "1"}}), "activation")
    check(api("wireguard/service/reconfigure", {}), "reconfigure")
    print(f"appliqué. Clé publique du serveur (pour le client) : {server['pubkey']}")


if __name__ == "__main__":
    main("--dry-run" in sys.argv)
