# Procédure : Service inaccessible, cause côté pare-feu

## Contexte

Un service ne répond plus alors qu'il tourne. Le pare-feu local (nftables) jette les paquets avant qu'ils n'atteignent le service. Les causes les plus fréquentes :

- **Règle ajoutée à la main** sur la machine, en dehors d'Ansible (test oublié, blocage « temporaire »)
- **Ordre des règles** : un `drop` placé avant le `accept` du même port
- **Port jamais ouvert** : nouveau service déployé sans règle correspondante
- **Source non autorisée** : la règle existe, mais pas pour l'adresse du client

Dans le lab, `lab-vm-2` (`192.168.122.102`) est protégée par le rôle Ansible `host_firewall` : entrée bloquée par défaut, règles dans `/etc/nftables.conf`.

---

## Détection

### Symptôme côté client

```
curl: (28) Connection timed out after 5005 milliseconds
```

alors que le ping répond.

La forme de l'échec oriente tout le diagnostic :

- **Connection refused** (immédiat) → la machine a répondu que rien n'écoute : le service est arrêté, voir [nginx down](./nginx-down.md)
- **Connection timed out** (après attente) → le paquet n'a reçu aucune réponse : il a été jeté, penser au pare-feu

Toujours lancer `curl` avec un délai (`-m 5`) pour distinguer les deux.

---

## Diagnostic

### 1. Constater le symptôme depuis le client

```bash
ping -c 2 192.168.122.102
curl -v -m 5 http://192.168.122.102/
```

Ping correct et port en délai dépassé : la machine et le réseau vont bien, le problème est sur le port.

### 2. Écarter le service

Sur la machine :

```bash
systemctl status nginx --no-pager
sudo ss -tlnp | grep ':80'
```

Service actif et à l'écoute sur `0.0.0.0:80` : il n'est pas en cause.

Attention au test `curl http://localhost/` : il traverse aussi la chaîne `input` du pare-feu (interface `lo`). S'il échoue alors que `ss` montre le service à l'écoute, c'est un indice de plus contre le pare-feu, pas contre le service.

### 3. Comparer ce qui est prévu et ce qui est chargé

```bash
# Configuration voulue (écrite par Ansible, rechargée au démarrage)
grep -n '80' /etc/nftables.conf

# Règles réellement appliquées par le noyau
sudo nft list ruleset
```

Les règles sont lues de haut en bas et la première qui correspond décide. Chercher dans la chaîne `input` :

- une ligne absente de `/etc/nftables.conf`
- un `drop` placé avant le `accept` du même port
- une restriction de source (`ip saddr`) qui exclut le client

### 4. Consulter les refus journalisés

```bash
sudo journalctl -k --no-pager | grep nft-drop | tail
```

Seuls les paquets arrivés en fin de chaîne (politique par défaut) sont journalisés. Un `drop` explicite placé plus haut ne laisse aucune trace : l'absence de ligne ne prouve rien.

---

## Résolution

### Règle parasite ou dérive par rapport au fichier

Recharger la configuration voulue. Le fichier commence par `flush ruleset` et nft l'applique en une seule opération, sans instant sans protection :

```bash
sudo nft -f /etc/nftables.conf
```

Ne pas lancer `sudo nft flush ruleset` seul : il supprime toutes les règles, la machine n'a plus de pare-feu du tout.

### Port ou source manquant dans la configuration

Ne pas corriger à la main sur la machine. Ajouter la règle dans `host_firewall_rules` (rôle `host_firewall`) et pousser : le pipeline l'applique, avec retour arrière automatique si la connexion SSH est perdue.

### Vérifier

```bash
# Sur la machine : plus de ligne en trop
sudo nft list ruleset

# Depuis le client
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.122.102/
```

Vérifier aussi qu'un port censé rester fermé l'est toujours (`nc -zv 192.168.122.102 10050`) : le service qui répond à nouveau ne prouve pas que le pare-feu est revenu à l'état prévu.

---

## Cas d'un serveur derrière OPNsense (redirection de port)

Dans le lab, le site de `lab-vm-1` (`10.10.10.101`, LAN) est publié par une règle Destination NAT d'OPNsense : `192.168.122.119:80` → `10.10.10.101:80`. Le client ne voit que l'adresse WAN du pare-feu.

### Ce qui change dans la lecture du symptôme

- **Le ping ne teste que le pare-feu** : c'est OPNsense qui répond sur `.119`, pas le serveur
- **Un refus ne prouve pas que le service est arrêté** : le paquet a été redirigé et livré quelque part où rien n'écoute (mauvais port ou mauvaise IP cible), et le refus du serveur revient au client à travers le NAT
- **Un délai dépassé** oriente plutôt vers un filtrage (règle de blocage, règle associée absente) ou vers une IP cible qui n'existe pas

### Diagnostic

1. Depuis le client : `ping -c 2 192.168.122.119` puis `curl -v -m 5 http://192.168.122.119/`
2. Écarter le service, sans passer par le NAT. Le poste n'a pas de SSH vers le LAN : commande ad hoc AWX (Inventaires → `homelab-zabbix` → Hôtes → `lab-vm-1` → Exécuter une commande, module `shell`) :

   ```bash
   systemctl is-active nginx; ss -ltn | grep ':80 '; curl -sI -m3 http://localhost/ | head -1
   ```

   Service actif, à l'écoute et en `200` en local : il n'est pas en cause.
3. Comparer la redirection avec ce que montre `ss` : Pare-feu → NAT → Destination NAT, champs **Redirect Target IP** et **Redirect Target Port**. Dans le shell d'OPNsense, la redirection réellement chargée :

   ```bash
   pfctl -s nat    # redirections (rdr) ; pfctl -sr ne montre que le filtrage
   ```

   Avec l'option Firewall rule = Pass, la ligne commence par `rdr pass` et aucune règle n'apparaît dans Règles → WAN : ne pas conclure trop vite qu'il manque une règle.

### Résolution

Corriger la règle Destination NAT dans l'interface, **Appliquer**, puis vérifier depuis le client :

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.122.119/
```

---

## Prévention

- Aucune règle à la main sur les machines : tout passe par le rôle `host_firewall`
- Le rôle recharge `/etc/nftables.conf` à chaque passage et signale un `changed` s'il a corrigé une dérive. Avant cette correction, il ne comparait que le modèle au fichier : le pipeline sortait en succès sans toucher à la règle parasite
- Superviser le service depuis l'extérieur de la machine (test HTTP Zabbix), pas seulement le processus : ici nginx tournait parfaitement

---

## Références

- Testé en lab le 30/09/2026 sur `lab-vm-2` (VM Proxmox, Debian 12, nftables)
- Scénario simulé : `nft insert rule inet filter input tcp dport 80 drop` ajouté à la main en tête de chaîne
- Testé en lab le 05/10/2026 sur `lab-vm-1` derrière OPNsense 26.7 : port cible de la redirection passé de `80` à `8080` (refus immédiat alors que nginx tournait)
