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

## Prévention

- Aucune règle à la main sur les machines : tout passe par le rôle `host_firewall`
- Le rôle recharge `/etc/nftables.conf` à chaque passage et signale un `changed` s'il a corrigé une dérive. Avant cette correction, il ne comparait que le modèle au fichier : le pipeline sortait en succès sans toucher à la règle parasite
- Superviser le service depuis l'extérieur de la machine (test HTTP Zabbix), pas seulement le processus : ici nginx tournait parfaitement

---

## Références

- Testé en lab le 30/09/2026 sur `lab-vm-2` (VM Proxmox, Debian 12, nftables)
- Scénario simulé : `nft insert rule inet filter input tcp dport 80 drop` ajouté à la main en tête de chaîne
