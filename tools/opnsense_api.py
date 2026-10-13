"""Accès à l'API d'OPNsense (site A), partagé par les scripts tools/opnsense_*.py.

Clé API : ~/.config/opnsense/apikey.txt (lignes key=… et secret=…, hors repo).
"""
import base64
import json
import ssl
import sys
import urllib.request
from pathlib import Path

OPNSENSE = "https://192.168.122.119"
KEYFILE = Path.home() / ".config/opnsense/apikey.txt"


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
