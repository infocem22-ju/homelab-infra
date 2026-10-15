#!/usr/bin/env python3
"""IPsec site à site d'OPNsense (site A) vers fw-debian (site B), posé par l'API.

Idempotent : paires de clés et connexion sont retrouvées par leur nom ou leur
description et mises à jour, pas recréées. Authentification par clés publiques :
la paire du site A est générée par OPNsense (ipsec/key_pairs/gen_key_pair) à la
création, et sa clé privée ne transite qu'en mémoire dans ce script (jamais écrite
ni affichée, jamais renvoyée lors d'une mise à jour). Celle du site B reste sur
fw-debian (rôle Ansible ipsec_site, qui affiche la clé publique à recopier ici).
Les règles de filtrage (WAN et interface IPsec) sont dans tools/opnsense_rules.py.

Usage : tools/opnsense_ipsec.py [--dry-run]
"""
import sys

from opnsense_api import api, check

LOCAL = dict(name="site-a", addr="192.168.122.119", ts="10.10.10.0/24")

# Clé publique affichée par le rôle ipsec_site (tâche « Show public key »).
# None : premier passage, seule la paire du site A est créée et sa clé publique affichée.
REMOTE = dict(name="site-b", addr="192.168.122.120", ts="10.10.20.0/24",
              pubkey=None)

# Mêmes valeurs que dans le rôle ipsec_site (defaults), sinon NO_PROPOSAL_CHOSEN.
IKE_PROPOSALS = "aes256gcm16-sha256-ecp256"
ESP_PROPOSALS = "aes256gcm16-ecp256"

DESCRIPTION = "site-b (fw-debian)"


def find(path, field, value):
    return next((r["uuid"] for r in api(path)["rows"] if r[field] == value), None)


def upsert_key_pair(name, pubkey, dry):
    """Paire de clés retrouvée par son nom. pubkey None : générée par OPNsense (site A)."""
    uuid = find("ipsec/key_pairs/search_item", "name", name)
    print(f"{'mise à jour' if uuid else 'création  '} paire de clés {name}")
    if dry or (uuid and pubkey is None):
        return uuid  # la paire locale n'est jamais régénérée
    item = dict(name=name, keyType="rsa")
    if pubkey is None:
        keys = api("ipsec/key_pairs/gen_key_pair/rsa/3072")
        item.update(publicKey=keys["pubkey"], privateKey=keys["privkey"])
    else:
        item.update(publicKey=pubkey.strip())
    path = f"ipsec/key_pairs/set_item/{uuid}" if uuid else "ipsec/key_pairs/add_item"
    result = api(path, {"keyPair": item})
    check(result, f"paire de clés {name}")
    return uuid or result["uuid"]


def upsert_child_object(kind, conn_uuid, item, dry):
    """local, remote ou child de la connexion (un seul de chaque), retrouvé par sa connexion."""
    uuid = find(f"ipsec/connections/search_{kind}", "connection", DESCRIPTION) if conn_uuid else None
    print(f"{'mise à jour' if uuid else 'création  '} {kind}")
    if dry:
        return
    body = {kind: {"enabled": "1", "connection": conn_uuid, **item}}
    path = f"ipsec/connections/set_{kind}/{uuid}" if uuid else f"ipsec/connections/add_{kind}"
    check(api(path, body), kind)


def main(dry):
    local_key = upsert_key_pair(LOCAL["name"], None, dry)
    if not dry and REMOTE["pubkey"] is None:
        print("Clé publique du site A (à recopier dans le rôle ipsec_site, host_vars de fw-debian) :")
        print(api(f"ipsec/key_pairs/get_item/{local_key}")["keyPair"]["publicKey"])
        print("Puis passer lab-site pour obtenir celle du site B, la mettre dans REMOTE et relancer.")
        return
    remote_key = upsert_key_pair(REMOTE["name"], REMOTE["pubkey"], dry)

    conn_uuid = find("ipsec/connections/search_connection", "description", DESCRIPTION)
    print(f"{'mise à jour' if conn_uuid else 'création  '} connexion {DESCRIPTION}")
    if not dry:
        conn = dict(enabled="1", description=DESCRIPTION, version="2",
                    proposals=IKE_PROPOSALS, local_addrs=LOCAL["addr"],
                    remote_addrs=REMOTE["addr"], dpd_delay="30")
        path = (f"ipsec/connections/set_connection/{conn_uuid}" if conn_uuid
                else "ipsec/connections/add_connection")
        result = api(path, {"connection": conn})
        check(result, "connexion")
        conn_uuid = conn_uuid or result["uuid"]

    upsert_child_object("local", conn_uuid, dict(
        auth="pubkey", id=LOCAL["addr"], pubkeys=local_key or ""), dry)
    upsert_child_object("remote", conn_uuid, dict(
        auth="pubkey", id=REMOTE["addr"], pubkeys=remote_key or ""), dry)
    # OPNsense monte le tunnel dès le démarrage (start) ; fw-debian attend (trap).
    upsert_child_object("child", conn_uuid, dict(
        description=f"{LOCAL['ts']} <-> {REMOTE['ts']}", mode="tunnel",
        local_ts=LOCAL["ts"], remote_ts=REMOTE["ts"], esp_proposals=ESP_PROPOSALS,
        start_action="trap|start", dpd_action="start"), dry)
    if dry:
        return
    check(api("ipsec/connections/toggle/1", {}), "activation d'IPsec")
    check(api("ipsec/service/reconfigure", {}), "reconfigure")
    print("appliqué")


if __name__ == "__main__":
    main("--dry-run" in sys.argv)
