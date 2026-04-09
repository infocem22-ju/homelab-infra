# Procédure : Disque plein

## Contexte

Un disque saturé est une cause fréquente de panne applicative. Les symptômes varient selon le service :

- **nginx** : tient tant qu'il n'a pas besoin d'écrire, mais les logs sont perdus
- **MySQL/MariaDB** : crash garanti dès que les tablespaces ne peuvent plus grossir
- **PHP/GLPI** : sessions cassées, uploads impossibles, logs perdus
- **apt** : installations et mises à jour bloquées

Cas vécu : module OCS Inventory qui remplit `/var/log/ocsinventory-server/` sur plusieurs semaines sans rotation configurée.

---

## Détection

### Via Zabbix

Alerte : `FS [/]: Space is critically low (used > 90%)`

Zabbix remonte cette alerte avant la panne — le seuil par défaut est 80% (warning) et 90% (critical). C'est le premier signal à surveiller.

### Symptômes côté service

- Le service web ne répond plus ou répond partiellement
- Les logs applicatifs s'arrêtent brutalement
- Les écritures échouent (uploads, sessions, base de données)

---

## Diagnostic

### 1. Vérifier l'espace disque

```bash
df -h
```

Chercher une partition à 100% ou proche. Exemple :

```
/dev/sda1       2.8G  2.8G     0 100% /
```

### 2. Identifier le coupable

```bash
sudo du -sh /var/log/* | sort -rh | head -10
```

Répéter sur les répertoires suspects :

```bash
sudo du -sh /var/lib/* | sort -rh | head -10
sudo du -sh /tmp/* | sort -rh | head -10
```

### 3. Confirmer l'état du service

```bash
systemctl status nginx
systemctl status mariadb
```

---

## Résolution

### Libérer l'espace

Supprimer le fichier coupable :

```bash
sudo rm /var/log/bigfile
```

Si le fichier est encore ouvert par un process (cas fréquent avec les logs applicatifs) :

```bash
# Vider le fichier sans le supprimer
sudo truncate -s 0 /var/log/application.log
```

Vérifier que l'espace est libéré :

```bash
df -h /
```

### Relancer le service si nécessaire

```bash
sudo systemctl restart nginx
```

---

## Prévention

### Configurer logrotate

Exemple pour OCS Inventory :

```
/var/log/ocsinventory-server/*.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
```

Tester la configuration :

```bash
sudo logrotate -d /etc/logrotate.d/ocsinventory
```

### Zabbix

- Seuil warning : 80%
- Seuil critical : 90%
- Action : notification immédiate

Avec Zabbix correctement configuré, l'alerte arrive plusieurs jours avant la panne — suffisant pour intervenir sans urgence.

---

## Références

- Testé en lab le 08/04/2026 sur VM Debian 12 (Proxmox)
- Scénario simulé : `dd if=/dev/zero of=/var/log/bigfile bs=1M`
