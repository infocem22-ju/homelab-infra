# Procédure : Service nginx down

## Contexte

nginx peut tomber pour plusieurs raisons. Les plus fréquentes :

- **Config invalide** : une modification de `nginx.conf` introduit une erreur de syntaxe
- **Kill brutal** : arrêt en `kill -9` sans shutdown propre → processus zombies
- **Disque plein** : nginx ne peut plus écrire ses logs
- **Port déjà utilisé** : un autre process occupe le port 80/443

---

## Détection

### Via Zabbix

Alerte : `nginx: Service is down`

### Symptôme côté client

```
curl: (56) Recv failure: Connexion ré-initialisée par le correspondant
```

ou

```
curl: (7) Failed to connect to ... port 80: Connection refused
```

La distinction est importante :
- **Connection refused** → rien n'écoute sur le port
- **Connection reset** → quelque chose écoute mais crash immédiatement

---

## Diagnostic

### 1. Tester le service

```bash
curl -v http://localhost
```

### 2. Vérifier les processus

```bash
ps aux | grep nginx
```

Cas possibles :
- **Processus actifs** → nginx tourne, problème applicatif en amont
- **Processus defunct (zombies)** → crash brutal, pas de shutdown propre
- **Aucun processus** → nginx complètement arrêté

### 3. Vérifier les logs

```bash
sudo tail -50 /var/log/nginx/error.log
sudo tail -50 /var/log/nginx/access.log
```

Les dernières entrées d'access.log donnent la timeline — quand le service a cessé de répondre.

### 4. Vérifier le port

```bash
ss -tlnp | grep ':80\|:443'
```

### 5. Tester la configuration

```bash
sudo nginx -t
```

C'est souvent ici que le problème se révèle.

---

## Résolution

### Config invalide

```bash
# Identifier la ligne en erreur
sudo nginx -t

# Corriger le fichier
sudo nano /etc/nginx/nginx.conf

# Vérifier puis relancer
sudo nginx -t && sudo systemctl start nginx
```

### Processus zombies après kill brutal

```bash
# Tuer les processus restants
sudo kill -9 $(pgrep nginx)

# Relancer
sudo systemctl start nginx
# ou sans systemd :
sudo nginx
```

### Directive dupliquée

Cas vécu : `worker_processes` ajouté en fin de fichier alors qu'il existe déjà en début de fichier.

```bash
# Voir la fin du fichier
sudo tail -10 /etc/nginx/nginx.conf

# Supprimer la dernière ligne si c'est le doublon
sudo sed -i '$ d' /etc/nginx/nginx.conf

# Vérifier
sudo nginx -t
```

---

## Prévention

- Ne jamais modifier `nginx.conf` sans tester avec `nginx -t` avant de recharger
- Utiliser `systemctl reload nginx` plutôt que `kill` — rechargement gracieux sans coupure
- Zabbix surveille le port 80 et le processus nginx — alerte immédiate si le service tombe

---

## Références

- Testé en lab le 08/04/2026 sur container Podman Debian 12
- Scénario simulé : directive dupliquée + `kill -9`
