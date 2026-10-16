# VM pare-feu — rapport de travail

Journal tenu au fil de l'eau pendant la mise en place d'un pare-feu dans le lab.
Démarré le 28/09/2026.

## Objectif

Placer les VMs du lab derrière un pare-feu, comme sur un réseau de PME :

- WAN sur le réseau actuel `192.168.122.0/24` (réseau `default` de libvirt)
- LAN sur un bridge interne dédié à Proxmox (`vmbr1`)
- Filtrage, NAT sortant, DHCP/DNS côté LAN
- Supervision du pare-feu dans Zabbix (SNMP prévu au départ, fait finalement par l'agent Zabbix : voir 16/10)

On monte deux solutions l'une après l'autre pour les comparer :

| | OPNsense | Debian + nftables |
|---|---|---|
| Type | Appliance avec interface web | Routeur construit à la main |
| Configuration | Stockée dans l'appliance, API partielle | Rôle Ansible versionné, déployé via AWX |
| Ce qu'on retrouve | Très présent en PME | Cohérent avec le reste du lab (tout en code) |
| À construire | Peu de choses | NAT, DHCP/DNS (dnsmasq), logs |

## État de départ (28/09/2026)

| Composant | Adresse | État |
|---|---|---|
| Zabbix (Docker Compose) | hôte | up |
| Proxmox VE (VM KVM `proxmox-lab`) | `192.168.122.106:8006` | up — 4 vCPU, 10 Gio de RAM, une seule carte réseau (`default`) |
| AWX 24.6.1 (VM KVM `Awx`) | `192.168.122.148:30080` | up |
| `lab-vm-1` / `lab-vm-2` | `.101` / `.102` | éteintes, dans Proxmox |

Points notés au démarrage :

- Proxmox est lui-même une VM KVM avec une seule interface sur `default`. Le bridge `vmbr1` du LAN peut rester interne à Proxmox (sans carte physique) : le pare-feu fait le lien entre `vmbr0` (WAN) et `vmbr1` (LAN).
- Pas d'accès SSH root par clé depuis le poste vers Proxmox. Le repo passe par l'API (token, variables `PROXMOX_*`, voir `ansible/playbooks/proxmox_provision_vms.yml`).
- La RAM est limitée à 10 Gio pour le pare-feu et les VMs du lab : à surveiller.

## Journal

### 28/09/2026

- Stack relancée (Zabbix, Proxmox, AWX). VMs du lab laissées éteintes.
- Rapport créé.
- Réseau Proxmox relevé : `vmbr0` = `192.168.122.106/24`, passerelle `192.168.122.1`, port `nic0`. Ce sera le WAN d'OPNsense.
- Création de `vmbr1` (bridge LAN) dans Système → Réseau : sans IP, sans passerelle, sans port, autostart coché, puis « Appliquer la configuration ».
- Image OPNsense 26.7 (dvd, amd64) téléchargée depuis `pkg.opnsense.org` et décompressée (`.iso.bz2` → `.iso`, 2,0 Gio). À envoyer dans `local → ISO Images → Upload` : Proxmox ne voit un ISO qu'une fois qu'il est dans ce stockage.
- ISO envoyé dans `local`. VM `105 (opnsense)` créée :
  - 2 Gio de RAM, 2 vCPU (x86-64-v2-AES), SeaBIOS, i440fx, VirtIO SCSI single
  - disque de 16 Gio sur `local-lvm`
  - `net0` VirtIO sur `vmbr0` (WAN), `net1` VirtIO sur `vmbr1` (LAN)
- Affectation des interfaces corrigée en mode live (console, option 1), puis installation en UFS sur `da0`. ISO retiré avant le reboot. `firewall=1` retiré des deux cartes. Après le reboot, l'affectation est conservée : `WAN (vtnet0)` en DHCP, `192.168.122.119/24` ; `LAN (vtnet1)` en `192.168.1.1/24`.
- Interface web d'OPNsense accessible depuis l'hôte (`https://192.168.122.119`), passée en français.
- SSH activé pour l'administration, parce que la console noVNC est pénible (clavier, pas de copier-coller) :
  - connexion root par clé uniquement (`~/.ssh/id_ecdsa` de l'hôte), connexion par mot de passe désactivée ; vérifié depuis l'hôte, OPNsense ne propose plus que `publickey`
  - règle WAN : Pass TCP `192.168.122.1/32` → This Firewall:22
  - piège : une clé collée avec du texte avant `ecdsa-sha2-…` est ignorée
- LAN configuré par l'option 2 de la console : `LAN (vtnet1)` en `10.10.10.1/24`, serveur DHCP `10.10.10.200`–`.249`, réglages d'accès web non réinitialisés. Le WAN reste en `192.168.122.119`.
- À la relecture du matériel : `firewall=1` sur les deux cartes, à décocher. Réglages mineurs : sockets/cœurs à inverser (1 socket, 2 cœurs), `discard` absent du disque.

### 29/09/2026

- Stack relancée (Zabbix, Proxmox, AWX), puis VM 105 (OPNsense) et VM 103 démarrées.
- VM 103 = `lab-crash-1` (déjà exclue du Job Template `lab-site`, donc sans effet sur la CI/CD). `net0` passé sur `vmbr1`, pare-feu Proxmox décoché.
- Premier test raté : la VM gardait son IP fixe cloud-init `192.168.122.50` / passerelle `192.168.122.1` (`proto static`), d'où « Destination Host Unreachable ». Correction : Cloud-Init → Config IP (net0) en DHCP, « Régénérer l'image », puis arrêt/démarrage depuis Proxmox (un `reboot` interne ne relit pas le disque cloud-init).
- **LAN validé de bout en bout** depuis `lab-crash-1` :
  - bail DHCP `10.10.10.220/24`, passerelle `10.10.10.1`
  - ping de `10.10.10.1` : OK
  - ping de `1.1.1.1` : OK (NAT sortant fonctionnel)
  - résolution DNS de `debian.org` : OK (via `10.10.10.1`)

- Accès d'AWX au LAN, option retenue : route plutôt que déplacer AWX (voir Décisions).
  - IP WAN d'OPNsense figée par une réservation DHCP libvirt (`bc:24:11:4c:44:30` → `192.168.122.119`) : la route en dépend.
  - Route `10.10.10.0/24 via 192.168.122.119` ajoutée à chaud sur l'hôte et sur AWX (`homelab-awx`, Debian 12). Persistante sur l'hôte : `<route address='10.10.10.0' prefix='24' gateway='192.168.122.119'/>` dans le réseau libvirt `default` (`net-edit`, prise en compte au prochain démarrage du réseau). Persistante sur AWX : ifupdown, lignes `up ip route replace …` / `down ip route del … || true` dans la section `enp1s0` de `/etc/network/interfaces` (vérifié avec `ifquery enp1s0`).
  - Règles WAN : Pass TCP `192.168.122.148/32` → LAN net:22 (AWX → LAN SSH), Pass ICMP `192.168.122.0/24` → LAN net (tests).
  - Ping AWX → `lab-crash-1` OK, mais SSH en timeout. Cause : `reply-to` (voir Problèmes rencontrés). Corrigé par **Disable reply-to on WAN rules**.
  - **SSH AWX → `10.10.10.220:22` : open.**

- `lab-vm-1` (VM 101) passée derrière le pare-feu : `net0` sur `vmbr1`, cloud-init `10.10.10.101/24`, passerelle et DNS `10.10.10.1`. Repo aligné : `proxmox_provision_vms.yml` (bridge, passerelle et DNS par VM ; `net0` n'est réécrit que sur un clone neuf, sinon la MAC change à chaque passage) et `lab_vms_static.yml`.
- Interface Zabbix de `lab-vm-1` passée en `10.10.10.101` (API `hostinterface.update`).
- Premier `lab-site` : `lab-vm-1` `unreachable`. L'inventaire AWX `homelab-zabbix` gardait l'ancienne IP en cache. Synchro de la source, puis « Mettre à jour au lancement » coché.
- **`lab-site` relancé : `lab-vm-1` ok=22, `lab-vm-2` ok=23, aucun échec.** Sur `lab-vm-1`, le téléchargement du paquet Zabbix confirme la sortie Internet (NAT) et le DNS via OPNsense ; `Configure zabbix-agent2` passe en `changed` car le modèle contient `ListenIP={{ ansible_host }}`.
- Supervision : l'agent est en mode actif (`ServerActive=192.168.50.6`), il sort par le NAT. `agent.ping` et `system.uptime` de `lab-vm-1` remontent dans Zabbix : pas besoin d'ouvrir le 10050 sur le WAN.
- `lab-vm-2` reste côté WAN (voir Décisions).

### 30/09/2026

- Rôle Ansible `host_firewall` (nftables) écrit pour `lab-vm-2` :
  - activé par hôte (`host_firewall_enabled`, dans `ansible/inventory/host_vars/lab-vm-2.yml`) ; sur les autres VMs le rôle ne fait rien
  - entrée bloquée par défaut ; ouverts : SSH depuis AWX (`.148`) et l'hôte (`.1`), HTTP pour tous, ping ; les refus sont journalisés (`nft-drop:`, 5 par minute au plus)
  - le 10050 (Zabbix) reste fermé : l'agent est en mode actif, il sort de lui-même
  - retour arrière automatique : un minuteur systemd (`host-firewall-rollback`, 60 s) remet l'ancien `/etc/nftables.conf` ; il n'est désarmé que si Ansible réussit une nouvelle connexion SSH après l'application des règles
  - ajouté en dernier dans `lab_site.yml` (`40_host_firewall.yml`)
- Vérifié sur le poste : syntaxe du playbook, et règles générées acceptées par `nft -c`.

- **Déployé par le pipeline** (push → GitHub Actions → AWX, job `lab-site` 87) : `lab-vm-2` ok=33, aucun échec ; `lab-vm-1` ignorée par le rôle. La nouvelle connexion SSH d'AWX est passée, le minuteur de retour arrière a été désarmé. Second passage (job 91) : rien à changer sur le pare-feu.
- Vérifié depuis l'hôte : 22 et 80 ouverts (HTTP `200`), ping OK, **10050 fermé** (il était ouvert avant). Sur la VM : `nft list ruleset` conforme, service `nftables` activé au démarrage, refus visibles dans `journalctl -k` (`nft-drop:`).
- La synchro du projet AWX a pris 7 minutes au lieu de quelques secondes : collections Galaxy retéléchargées après le redémarrage de la VM AWX.
- Le runner GitHub doit être lancé à la main (`~/actions-runner/run.sh`) : les runs de la veille étaient restés en file d'attente et sont partis en même temps.

- **Retour arrière testé** depuis le poste (`ansible-playbook … 40_host_firewall.yml -l lab-vm-2 -e` avec une règle SSH qui oublie l'hôte `.1`) :
  - le play échoue au bout de 30 s sur « Check that Ansible can still connect », le 22 est bien fermé depuis l'hôte
  - 60 s après l'application, le 22 se rouvre seul ; `/etc/nftables.conf` et les règles chargées sont revenus à la version précédente
  - le premier essai a montré deux défauts, corrigés dans `apply.yml` (voir Problèmes rencontrés)
- Chemin normal revérifié après correction (changement de règles sans coupure, minuteur désarmé, sauvegarde supprimée), puis règles du repo remises : 22 et 80 ouverts, 10050 fermé.

- **Étude de cas : site de `lab-vm-2` inaccessible.** Panne injectée à la main (`nft insert rule inet filter input tcp dport 80 drop`), diagnostic mené de bout en bout :
  - ping correct, `curl` en délai dépassé (et non en refus) : paquet jeté, pas service arrêté
  - nginx actif et à l'écoute sur `0.0.0.0:80` ; le `curl` local échouait aussi, car la règle était placée avant `iif "lo" accept`
  - `/etc/nftables.conf` correct, mais `nft list ruleset` montrait le `drop` en tête de chaîne : dérive entre la configuration versionnée et les règles chargées
  - corrigé par `sudo nft -f /etc/nftables.conf` (et non `nft flush ruleset`, qui aurait retiré tout le pare-feu)
  - procédure rédigée : `procedures/service-inaccessible-pare-feu.md`
- **Faiblesse du rôle trouvée grâce à l'étude de cas** : il ne comparait que le modèle au fichier, donc le pipeline serait sorti en succès sans retirer la règle parasite. Corrigé : le rôle recharge `/etc/nftables.conf` à chaque passage et passe en `changed` s'il a corrigé une dérive. Vérifié depuis le poste : panne réinjectée, un passage du rôle la répare (`changed`), le suivant ne change rien.

- **Source d'inventaire `homelab-zabbix` versionnée** (01/10/2026) : `zabbix-source` décrite dans `ansible/awx/job_templates.yml` (`awx.awx.inventory_source`, `update_on_launch: true`), reprise à l'identique de la configuration lue dans l'API AWX. `--check` passe sans aucun changement : le réglage fait à la main le 29/09 est maintenant dans le code.

- **`lab-crash-1` en adresse fixe `10.10.10.50`** (01/10/2026). Réservation Dnsmasq dans OPNsense (Services → Dnsmasq DNS & DHCP → Hosts, MAC de la VM → `10.10.10.50`) : la VM garde son numéro, comme prévu par le plan d'adressage, hors plage DHCP. Après redémarrage, elle répond en `.50` et `.220` est libéré.
  - Zabbix : IP de l'interface passée de `192.168.122.50` à `10.10.10.50` (API, `hostinterface.update`)
  - l'agent ne remontait toujours rien : `ListenIP` pointait encore sur l'ancienne IP (voir Problèmes rencontrés). Diagnostic par une commande ad hoc AWX, puisque seul AWX a droit au SSH vers le LAN ; réparé en relançant `lab-vms-bootstrap` (configuration réécrite sur `lab-crash-1` seule)
  - vérifié dans Zabbix : `agent.ping` à 1, agent actif disponible

### 05/10/2026

- Stack relancée (Zabbix, Proxmox, AWX). OPNsense, `lab-vm-1` et `lab-vm-2` démarrent seules avec Proxmox.
- **Site de `lab-vm-1` publié par redirection de port** (Pare-feu → NAT → Destination NAT, l'ancien « Port Forward ») : WAN, TCP, destination `WAN address:80` → `10.10.10.101:80`, Firewall rule = **Pass**. Avant, le 80 n'était ouvert nulle part du WAN vers le LAN (seuls SSH depuis AWX et ping passaient). Vérifié depuis l'hôte : `http://192.168.122.119/` renvoie la page de `lab-vm-1` (`200`).
  - Premier essai du formulaire : destination laissée sur « Hôte unique ou réseau », port `any`, Firewall rule « Manuel ». Avec le port `any`, tout le TCP arrivant sur le WAN (y compris l'interface web en 443) serait parti vers `lab-vm-1`. Avec « Manuel », aucune règle de filtrage n'est créée et le trafic redirigé reste bloqué.
- **Clé API OPNsense** : utilisateur `api-lab`, privilèges limités au pare-feu (règles, NAT, alias), clé rangée sur le poste dans `~/.config/opnsense/apikey.txt` (droits 600, hors du repo). Testée avec `curl` sur `/api/firewall/d_nat/search_rule` et `/api/firewall/filter/search_rule`. Elle servira pour passer OPNsense en Ansible.

- **Étude de cas : site de `lab-vm-1` inaccessible, cause dans OPNsense.** Panne injectée par l'API (port cible de la redirection passé de `80` à `8080`), diagnostic mené de bout en bout :
  - ping de `.119` correct, `curl` en **refus immédiat** (`Connexion refusée`, 0 ms), pas en délai dépassé. Seul, ce symptôme fait penser à « nginx arrêté ». Mais derrière un NAT, le refus peut venir de la VM, renvoyé à travers la redirection, et le ping, lui, ne teste que le pare-feu
  - service écarté par une commande ad hoc AWX sur `lab-vm-1` (le poste n'a pas de SSH vers le LAN) : nginx `active`, à l'écoute sur `0.0.0.0:80`, `curl localhost` en `200`
  - un refus veut dire que le paquet a été livré là où rien n'écoute : la cause est dans la redirection, pas dans une règle de filtrage (un blocage aurait donné un délai dépassé). Dans la règle Destination NAT, **Redirect Target Port = 8080** alors que nginx écoute sur le 80
  - corrigé dans l'interface (port cible remis sur HTTP, Appliquer), vérifié depuis l'hôte : `200`
  - procédure complétée : `procedures/service-inaccessible-pare-feu.md`, cas d'un serveur derrière OPNsense

### 06/10/2026

- Stack relancée (Zabbix, Proxmox, AWX). OPNsense, `lab-vm-1` et `lab-vm-2` démarrent seules avec Proxmox ; `lab-crash-1` reste éteinte.
- **Pare-feu Debian + nftables monté en site B, à côté d'OPNsense** (voir Décisions) :

  ```
              hôte 192.168.122.1 / AWX .148
                       │ vmbr0 (WAN)
          ┌────────────┴────────────┐
     OPNsense .119             fw-debian .120
     10.10.10.1                10.10.20.1
          │ vmbr1                   │ vmbr2
     lab-vm-1 .101             lab-vm-3 .101
     lab-crash-1 .50
  ```

  - bridge `vmbr2` créé à la main dans Proxmox (sans IP ni port)
  - VMs `fw-debian` (VM 120, deux cartes : `vmbr0` en `192.168.122.120`, `vmbr2` en `10.10.20.1`) et `lab-vm-3` (VM 121, `10.10.20.101`, passerelle `10.10.20.1`, DNS de libvirt `192.168.122.1` joint à travers le NAT) créées par `proxmox_provision_vms.yml` (Job Template `lab-vms-provision`)
  - **mode routeur du rôle `host_firewall`**, activé dans `inventory/host_vars/fw-debian.yml`. Le même rôle sert au pare-feu d'hôte de `lab-vm-2`, avec le même retour arrière automatique. Il ajoute le routage IP (`net.ipv4.ip_forward`), une chaîne `forward` en `policy drop` et une table `ip nat`
  - premier passage depuis le poste (`ansible-playbook -i ansible/inventory/lab_vms_static.yml ansible/playbooks/40_host_firewall.yml -l fw-debian`), puis par le pipeline : aucun changement, la configuration versionnée et la configuration en place sont identiques
- **Correspondance OPNsense → nftables** :

  | Fonction | OPNsense (site A) | `fw-debian` (site B) |
  |---|---|---|
  | Politique par défaut | blocage implicite en fin de règles | `policy drop` sur `input` et `forward` |
  | Filtrage stateful | table d'états de `pf`, implicite | `ct state established,related accept`, `ct state invalid drop`, en tête de chaîne |
  | NAT sortant | Outbound NAT automatique | `oifname "eth0" ip saddr 10.10.20.0/24 masquerade` |
  | Redirection de port | Destination NAT, Firewall rule = Pass | `dnat to 10.10.20.101:80` en `prerouting`, puis `ct status dnat accept` dans `forward` |
  | Admin du LAN depuis AWX | règle WAN SSH depuis `.148` | règles `forward` SSH et ping depuis `.148` et `.1` |
  | Accès au pare-feu | GUI et SSH depuis `.1` | SSH depuis `.148` et `.1` (`input`) |
  | DHCP/DNS du LAN | Dnsmasq intégré | dnsmasq, rôle `dnsmasq_lan` (ajouté le même jour, voir plus bas) |
  | Où vit la config | dans l'appliance (`config.xml`) | dans le repo, déployée par AWX |

  Différence importante pour la redirection : dans `pf`, `rdr pass` crée la règle de filtrage en même temps. Dans nftables, la traduction (table `nat`) et le filtrage (chaîne `forward`) sont deux étapes séparées. Sans `ct status dnat accept`, le paquet redirigé est bloqué par la `policy drop` de `forward`.
- Routes vers `10.10.20.0/24` via `192.168.122.120`, comme pour le site A : sur l'hôte (à chaud, et `<route>` ajoutée au réseau libvirt `default` par `net-dumpxml`/`net-define`, sans éditeur) et sur AWX (lignes `up`/`down` dans la section `enp1s0`, vérifié avec `sudo ifquery enp1s0`)
- `fw-debian` et `lab-vm-3` inscrites dans Zabbix (groupe 27, modèle Linux by Zabbix agent active, API `host.create`) : elles entrent ainsi dans l'inventaire AWX et dans le pipeline. Le groupe `routers` (`fw-*`, `inventory/zabbix_inventory.yml`) les exclut de nginx.
- **Vérifié** :
  - `lab-vm-3` → Internet : ping `1.1.1.1`, résolution DNS, `http://deb.debian.org/` en `200`
  - poste → `lab-vm-3` : ping et SSH (règles `forward` d'administration)
  - avant nginx, `curl http://192.168.122.120/` est refusé en 0 ms : la redirection livre bien le paquet à `lab-vm-3`, où rien n'écoute (même lecture que l'étude de cas du 05/10)
  - `lab-site` (job 125) : `fw-debian`, `lab-vm-1`, `lab-vm-2`, `lab-vm-3` sans échec. `http://192.168.122.120/` renvoie la page de `lab-vm-3`, et `http://192.168.122.119/` celle de `lab-vm-1`
  - Zabbix : agent actif disponible sur `fw-debian` et `lab-vm-3`

- **DHCP/DNS du LAN sur `fw-debian` (dnsmasq)**, comme le Dnsmasq d'OPNsense sur le site A :
  - rôle `dnsmasq_lan` (playbook `35_dnsmasq_lan.yml`, groupe `routers`, dans `lab_site.yml` avant le pare-feu). DHCP `10.10.20.200`–`.249` (bail 12 h), passerelle et DNS = `10.10.20.1`. Domaine local `siteb.lab`, noms déclarés en `host-record`, le reste transmis à libvirt (`192.168.122.1`)
  - dnsmasq n'écoute que sur `eth1` (`interface`, `except-interface=lo`, `bind-interfaces`). systemd-resolved garde `127.0.0.53`, et rien n'est exposé côté WAN. La configuration est posée avant le paquet : sans `bind-interfaces`, dnsmasq écouterait sur toutes les adresses et son premier démarrage échouerait sur le port 53 déjà pris
  - `host_firewall` : les règles `input` acceptent un `iif`. DNS (UDP/TCP 53) et DHCP (UDP 67) sont ouverts seulement depuis `eth1`
  - `lab-vm-3` garde son IP fixe, mais son DNS passe sur `10.10.20.1` (cloud-init, `proxmox_provision_vms.yml`)
  - **vérifié** :
    - échange DHCP complet depuis `lab-vm-3` avec `udhcpc` en mode test (`-s /bin/true`, l'IP fixe n'est pas touchée) : bail `10.10.20.234` donné par `10.10.20.1`. `udhcpc` a été désinstallé ensuite
    - depuis `lab-vm-3` : `fw-debian.siteb.lab` → `10.10.20.1`, `lab-vm-3.siteb.lab` → `10.10.20.101`, `deb.debian.org` résolu et en `200`
    - depuis le poste (WAN) : DNS sur `192.168.122.120` en délai dépassé (bloqué)
    - `lab-site` (job 141) sans échec sur les 4 VMs

### 09/10/2026

- Stack relancée (Zabbix, Proxmox, AWX). OPNsense, `lab-vm-1` et `lab-vm-2` démarrent seules. `fw-debian` et `lab-vm-3`, non : démarrées par `lab-vms-provision` (job 169, aucun échec).
- Runner GitHub relancé (`~/actions-runner/run.sh`, détaché avec `setsid nohup`). Plus aucun run en file : ceux du 06/10 étaient déjà terminés. Le contrôle `pgrep -f Runner.Listener` a encore donné un faux positif (voir Problèmes rencontrés).
- **Étude de cas : site B inaccessible, routage IP coupé sur `fw-debian`.** Panne injectée à la main (`sysctl -w net.ipv4.ip_forward=0`), diagnostic mené de bout en bout :
  - `curl http://192.168.122.120/` en délai dépassé, ping du pare-feu correct : paquet jeté, pas service arrêté (un refus serait revenu à travers le DNAT)
  - chemin coupé en deux : depuis `fw-debian`, `curl http://10.10.20.101/` en `200`. `lab-vm-3` et nginx vont bien, la panne est dans le pare-feu
  - `nft list ruleset` conforme au fichier : `dnat` et `ct status dnat accept` présents
  - `sysctl net.ipv4.ip_forward` = `0`, alors que `99-host-firewall-router.conf` dit `1`. Le noyau jette le trafic routé avant la chaîne `forward`. Ping, SSH et `curl` depuis le pare-feu passent quand même, car ils ne sont pas routés
  - corrigé par `sudo sysctl -p /etc/sysctl.d/99-host-firewall-router.conf`, vérifié depuis le poste : `200`
  - procédure complétée : `procedures/service-inaccessible-pare-feu.md`, cas d'un routeur Debian
- **Même faiblesse du rôle que le 30/09, sur un autre réglage** : la tâche `Apply IPv4 forwarding` ne jouait que si le fichier `sysctl.d` changeait. Le pipeline serait donc sorti en succès, sans réparer le routage. Corrigé : le rôle lit `net.ipv4.ip_forward` dans le noyau et le réapplique s'il n'est pas à `1`. Vérifié depuis le poste : panne réinjectée, un passage du rôle la répare (`changed`), le suivant ne change rien.

- **Proxmox bloqué puis planté par l'*async page fault* de KVM** (voir Problèmes rencontrés) : DNS du site A mort depuis le matin, VM 105 impossible à redémarrer, puis `KERNEL PANIC` de `proxmox-lab`. Corrigé par `no-kvmapf` dans la ligne de commande du noyau de Proxmox (`/etc/default/grub`, `update-grub`, vérifié dans `/proc/cmdline`).

- **DMZ du site A sur OPNsense**, `lab-vm-1` déplacée dedans (voir Décisions) :

  ```
                 hôte 192.168.122.1 / AWX .148
                          │ vmbr0 (WAN)
                     OPNsense .119
            10.10.10.1 │        │ 10.10.30.1
               vmbr1 (LAN)    vmbr3 (DMZ)
            lab-crash-1 .50   lab-vm-1 .101
  ```

  - `vmbr3` créé à la main dans Proxmox, troisième carte VirtIO sur la VM 105 (`vtnet2`, pare-feu Proxmox décoché), affectée en `DMZ` (`opt1`) en `10.10.30.1/24`, sans passerelle ni DHCP
  - règles posées par l'API avec `tools/opnsense_dmz_rules.py` (idempotent, chaque règle est retrouvée par sa description). Elles apparaissent avec les autres dans Pare-feu → Règles, comme celles créées dans l'interface :

    | # | Interface | Action | Flux |
    |---|---|---|---|
    | 500 | DMZ | Pass | DNS (TCP/UDP 53) vers `10.10.30.1` |
    | 510 | DMZ | Pass | agent Zabbix actif vers `192.168.50.6:10051` |
    | 520 | DMZ | Block, journalisé | DMZ → LAN |
    | 530 | DMZ | Block, journalisé | DMZ → alias `reseaux_prives` (RFC 1918) |
    | 540–550 | DMZ | Pass | sortie 80, 443 (apt) et UDP 123 (NTP) |
    | 600 | WAN | Pass | SSH depuis AWX (`.148`) vers la DMZ |
    | 610 | WAN | Pass | ping depuis `192.168.122.0/24` vers la DMZ |

  - repo : `lab-vm-1` sur `vmbr3` en `10.10.30.101`, passerelle et DNS `10.10.30.1` (`proxmox_provision_vms.yml`, `lab_vms_static.yml`), passé par `lab-vms-provision` (job 186) puis arrêt/démarrage de la VM 101
  - redirection de port repointée par l'API : `.119:80` → `10.10.30.101:80` (règle `lab-vm-1 web (DMZ)`)
  - routes `10.10.30.0/24 via 192.168.122.119` sur l'hôte (à chaud, et `<route>` dans le réseau libvirt `default`) et sur AWX (lignes `up`/`down` dans `enp1s0`)
  - Zabbix : interface de `lab-vm-1` passée en `10.10.30.101` (`hostinterface.update`), inventaire AWX resynchronisé
- **Vérifié** :
  - depuis le poste : ping `10.10.30.101` OK, `http://192.168.122.119/` en `200`. Accès direct `10.10.30.101:80` et SSH bloqués : le site n'est joignable que par la redirection, et SSH est réservé à AWX
  - depuis `lab-vm-1` (commande ad hoc AWX, `/dev/tcp` de bash) : DNS, HTTP, HTTPS et Zabbix `10051` passent. LAN (`10.10.10.1:443`, `10.10.10.50:22`), site B (`10.10.20.101:80`), WAN du lab (AWX `:22`, `lab-vm-2:80`) et l'interface web d'OPNsense côté DMZ (`10.10.30.1:443`) sont tous en délai dépassé
  - `lab-site` (job 196) : `fw-debian`, `lab-vm-1`, `lab-vm-2`, `lab-vm-3` sans échec

### 12/10/2026

- Stack relancée (Zabbix, Proxmox, AWX), `fw-debian` et `lab-vm-3` démarrées par `lab-vms-provision` (job 200, aucun échec), runner GitHub relancé.
- **VLAN 40 « INVITES » sur le LAN du site A** (voir Décisions) :

  ```
                     OPNsense
                 vtnet1 (trunk) ── vmbr1, VLAN aware
               non étiqueté │      │ VLAN 40 (vlan01)
           LAN 10.10.10.0/24      INVITES 10.10.40.0/24
                                  lab-crash-1 .220 (DHCP)
  ```

  - Proxmox : « VLAN aware » coché sur `vmbr1`, puis Apply Configuration. Le LAN existant reste non étiqueté, donc aucune coupure. Carte de `lab-crash-1` (VM 103) en VLAN Tag `40`
  - OPNsense, dans l'interface (la clé API n'a que les droits pare-feu, `403` sur VLAN, interfaces et DHCP) : VLAN `40` sur `vtnet1` (périphérique `vlan01`), affecté en `INVITES` (`opt2`) en `10.10.40.1/24`, plage Dnsmasq `.200`–`.249`
  - règles posées par l'API. Le script de la DMZ est renommé `tools/opnsense_rules.py`, puisqu'il couvre maintenant les deux zones :

    | # | Interface | Action | Flux |
    |---|---|---|---|
    | 700 | INVITES | Pass | DNS (TCP/UDP 53) vers `10.10.40.1` |
    | 710 | INVITES | Block, journalisé | INVITES → alias `reseaux_prives` (LAN, DMZ, site B, WAN du lab, OPNsense lui-même) |
    | 720–730 | INVITES | Pass | sortie 80, 443 et UDP 123 |
    | 740 | INVITES | Pass | ping (vers Internet seulement, le privé est bloqué juste avant) |

  - le chemin a été suivi bout à bout : `bridge vlan show` sur Proxmox (`tap103i0` en `40 PVID Egress Untagged`, `tap105i1` en `1` non étiqueté plus `2`–`4094`), `tcpdump -eni vtnet1 vlan 40` sur OPNsense (demande DHCP étiquetée `vlan 40`, réponse de `10.10.40.1` dans le même VLAN)
- **Vérifié** depuis la console de `lab-crash-1` (`/dev/tcp` de bash) : adresse `10.10.40.220/24`, passerelle `10.10.40.1`, `deb.debian.org` résolu, `1.1.1.1:443` ouvert. L'interface web d'OPNsense (`10.10.40.1:443`), le LAN (`10.10.10.1:443`), la DMZ (`10.10.30.101:80`), le site B (`10.10.20.101:80`) et AWX (`192.168.122.148:22`) sont en délai dépassé. Site publié toujours en `200`, règles de la DMZ inchangées. Après un redémarrage, le bail DHCP arrive seul (voir Problèmes rencontrés).
- **Le même VLAN invités sur `fw-debian` (site B)**, pour comparer avec OPNsense. Seul geste à la main : « VLAN aware » sur `vmbr2`. Tout le reste est en Ansible, joué depuis le poste avec l'inventaire statique, puis rejoué sans aucun `changed` :
  - nouveau rôle `lan_vlans` (playbook `34_lan_vlans.yml`, ajouté à `lab-site` avant dnsmasq) : sous-interface `eth1.40` en `10.10.41.1/24`, dans `/etc/netplan/60-lan-vlans.yaml`. Ce fichier est séparé, car cloud-init réécrit `50-cloud-init.yaml`. L'application passe par `netplan generate` puis `networkctl reload`, et non par `netplan apply`, qui relancerait aussi le WAN par lequel passe Ansible
  - `dnsmasq_lan` : liste `dnsmasq_lan_vlans`, une plage `.200`–`.249` par VLAN. Les options DHCP sont étiquetées par réseau (`set:lan`, `set:invites`) : sans étiquette, les invités auraient reçu la passerelle du LAN
  - `host_firewall`, mode routeur : liste `guests`. Un invité ne sort que vers `eth0`, jamais vers `PRIVATE_NETS` (RFC 1918), et seulement en 80, 443, UDP 123 et ping. Il a son propre NAT sortant. DNS et DHCP sont ouverts en entrée sur `eth1.40` seulement
  - `lab-crash-1` passée de `vmbr1` à `vmbr2` (tag `40` inchangé). Elle a obtenu `10.10.41.220` après la correction du trunk (voir Problèmes rencontrés)
- **Vérifié** depuis la console de `lab-crash-1` : passerelle `10.10.41.1`, DNS résolu, `1.1.1.1:443` ouvert. SSH du pare-feu (`10.10.41.1` et `10.10.20.1`), LAN du site B (`10.10.20.101:80`), site A (`10.10.10.1`, `10.10.30.101`), AWX et l'hôte sont bloqués. Les rejets sont dans le journal du noyau de `fw-debian` : `nft-drop` pour ce qui vise le pare-feu, `nft-fwd-drop` pour ce qui le traverse (dont l'agent Zabbix de `lab-crash-1`, resté configuré vers `192.168.50.6:10051`). Le site B répond toujours `200`.
- **Comparaison OPNsense / nftables sur ce cas** :

  | | OPNsense (site A) | `fw-debian` (site B) |
  |---|---|---|
  | VLAN | Interfaces → Devices → VLAN, puis Assignments (interface web) | `lan_vlans` (netplan), versionné |
  | DHCP | Dnsmasq, une plage par interface | dnsmasq, une plage par VLAN, options étiquetées |
  | Règles | API (`tools/opnsense_rules.py`), alias `reseaux_prives` | `guests` dans `host_vars`, `define PRIVATE_NETS` |
  | Ce qui reste à la main | VLAN, interface, DHCP (la clé API reçoit `403`) | « VLAN aware » sur le bridge Proxmox |
  | Rejets visibles | journal du pare-feu (règle 710 journalisée) | `journalctl -k`, préfixes `nft-drop` / `nft-fwd-drop`, limités à 5 par minute |


### 13/10/2026

- Stack relancée. `lab-vms-provision` (job 206) est resté en attente 14 minutes derrière la mise à jour du projet AWX (voir Points ouverts).
- Clé API `api-lab` : privilège « VPN: WireGuard » ajouté, pour poser WireGuard par l'API comme les règles.
- **Faille trouvée en préparant WireGuard : toute VM du WAN du lab passait pour l'hôte.** Sans aucun tunnel, `lab-vm-2` atteignait l'interface web d'OPNsense (`10.10.10.1:443`) et le SSH du site B (`fw-debian`, `lab-vm-3`). Ces accès ne sont pourtant autorisés qu'à AWX et à l'hôte `192.168.122.1`. Diagnostic et correction : voir Problèmes rencontrés et Décisions.
  - vérifié après correction, depuis `lab-vm-2` : GUI d'OPNsense, SSH du site B et DMZ bloqués, rejets journalisés sur `fw-debian` avec la vraie source `192.168.122.102`. Sites publiés A et B en `200`, Internet joignable
  - vérifié depuis le poste : GUI d'OPNsense et SSH vers `lab-vm-3` toujours accessibles. La correction tient après un `systemctl restart libvirtd`
- **WireGuard, site A : `lab-vm-2` en télétravailleur vers OPNsense** (voir Décisions) :

  ```
     lab-vm-2 192.168.122.102 ── UDP 51820 ──► OPNsense .119 (WAN)
     wg-sitea 10.10.99.2               wg0 « teletravail » 10.10.99.1/24
        AllowedIPs 10.10.99.0/24, 10.10.10.0/24   │
                                                   └─► LAN 10.10.10.0/24
  ```

  - serveur posé par l'API avec `tools/opnsense_wireguard.py` : instance `teletravail` (`wg0`, port `51820`, `10.10.99.1/24`) et pair `lab-vm-2` (`10.10.99.2/32`). Les fonctions d'accès à l'API sont maintenant dans `tools/opnsense_api.py`, partagées avec `tools/opnsense_rules.py`
  - clé du serveur : OPNsense refuse une instance sans clé privée (`server.privkey: A value is required`). Elle est générée par OPNsense (`wireguard/server/key_pair`) à la création, et ne transite qu'en mémoire dans le script
  - client : nouveau rôle `wireguard_client` (playbook `36_wireguard_client.yml`, dans `lab-site`). La clé privée est générée sur la VM et n'en sort jamais : la configuration la lit par `PostUp = wg set %i private-key …`. Le rôle affiche la clé publique, à recopier dans le script. Un tunnel n'est monté qu'une fois `server_pubkey` renseignée
  - règles (`tools/opnsense_rules.py`) :

    | # | Interface | Action | Flux |
    |---|---|---|---|
    | 620 | WAN | Pass | UDP 51820 vers l'adresse WAN (entrée du tunnel) |
    | 800 | WireGuard (groupe) | Pass | `10.10.99.0/24` → LAN |
    | 810 | WireGuard (groupe) | Block, journalisé | tout le reste, y compris OPNsense par son adresse de tunnel |

- **Vérifié** depuis `lab-vm-2` : handshake établi, routes `10.10.10.0/24` et `10.10.99.0/24` sur `wg-sitea`. Tunnel monté : GUI (`10.10.10.1:443`) et DNS du LAN ouverts, `10.10.99.1:443`, DMZ et site B bloqués. Tunnel coupé (`systemctl stop`) : le LAN est bloqué. Le rôle remonte le tunnel (`changed`), puis un nouveau passage ne change rien.
- **WireGuard, site B : `fw-debian` en serveur, en Ansible**, deuxième tunnel sur `lab-vm-2` :
  - nouveau rôle `wireguard_server` (playbook `37_wireguard_server.yml`, groupe `routers`, avant nftables) : clé générée sur place, `wg0` en `10.10.98.1/24`, port `51820`, un `[Peer]` par entrée de `wireguard_server_peers`
  - `host_firewall`, mode routeur : liste `tunnels`. Un réseau de tunnel n'atteint que les réseaux de `to` (ici le LAN `10.10.20.0/24`), et tout le reste tombe sur la politique `drop`, journalisée. Entrée UDP 51820 ouverte sur `eth0` seulement
  - client : tunnel `wg-siteb` (`10.10.98.2`) ajouté dans `host_vars/lab-vm-2.yml`, à côté de `wg-sitea`. Même clé privée pour les deux tunnels, un pair par serveur
- **Vérifié** depuis `lab-vm-2`, les deux tunnels montés : handshake sur les deux. `lab-vm-3` ouvert en HTTP et en SSH ; SSH du pare-feu (`10.10.20.1`, `10.10.98.1`) bloqué et journalisé (`nft-drop`, `in=wg0`). Site A toujours joignable par `wg-sitea`, DMZ bloquée. `wg-siteb` coupé : le site B est bloqué. Les rôles rejoués ne changent rien (`changed=0`). **Revérifié le 14/10/2026**, après le redéploiement de `f286b53` par `lab-site` (réussi) : handshakes récents sur les deux tunnels, mêmes routes, mêmes ouvertures et blocages, et les SSH vers `10.10.20.1` et `10.10.98.1` sont bien journalisés `nft-drop` avec `IN=wg0`.
- **Comparaison OPNsense / nftables sur WireGuard** :

  | | OPNsense (site A) | `fw-debian` (site B) |
  |---|---|---|
  | Serveur | API, `tools/opnsense_wireguard.py` (instance + pairs) | rôle `wireguard_server`, `wg-quick@wg0` |
  | Clé privée du serveur | générée par OPNsense, passe en mémoire par le script à la création | générée sur la VM, ne la quitte jamais |
  | Filtrage du tunnel | règles sur le groupe d'interfaces `WireGuard`, Block final explicite | liste `tunnels` dans `host_vars`, la politique `drop` fait le reste |
  | Ajouter un client | un pair dans `PEERS` (script) + la clé publique côté serveur dans `host_vars` | une entrée dans `wireguard_server_peers` |
  | État du tunnel | `wireguard/service/show` (API) ou Diagnostics | `wg show` |

### 14/10/2026

- Stack relancée après le plantage de Proxmox du 13/10. Journal de Proxmox lu, et RAM de `proxmox-lab` verrouillée dans libvirt pour que l'hôte ne puisse plus la mettre en swap (voir Problèmes rencontrés).
- `lab-vms-provision`, puis `lab-site` : `f286b53` redéployé avec succès, WireGuard du site B revérifié (voir 13/10).
- **Mises à jour du projet AWX accélérées : collections prises dans l'EE, plus téléchargées** (voir Décisions et le README, partie AWX).
  - mesure de départ, sur le projet `homelab-infra` (id 8) : une mise à jour simple (`sync`, git seul) prend environ 4 s. Une mise à jour avec dépendances (`dependency`, sur un nouveau commit, avec installation de `requirements.yml` depuis Galaxy) a pris 49 s, 123 s, 584 s, 838 s et 1095 s. Toute la lenteur vient de Galaxy, et elle varie beaucoup d'un jour à l'autre
  - le plan noté le 13/10 (délai de cache, puis versions exactes) a été abandonné. Le délai de cache ne fait rien pour la première mise à jour après le démarrage d'AWX, justement celle qui bloque. Et un push arrivé pendant le délai aurait déployé l'ancien commit. Les versions exactes, seules, ne suppriment pas le téléchargement
  - constat : l'image `homelab-ee:1.0` contient déjà les collections de `requirements.yml` (`community.zabbix 4.2.0`, `community.proxmox 2.0.0`, `awx.awx 24.6.1`, relevé avec `ansible-galaxy collection list` dans l'image). Seul `lab-vms-provision` l'utilisait. Les autres Job Templates tournaient dans l'EE par défaut (`awx-ee:latest`), d'où le besoin de télécharger
  - changements, tous dans `ansible/awx/job_templates.yml` : réglage global `AWX_COLLECTIONS_ENABLED: false`. Le projet `homelab-infra`, jusque-là configuré à la main, est maintenant décrit dans le code, avec `default_environment: homelab-ee`, ce qui couvre tous ses Job Templates, y compris `test-connectivity` qui n'est pas dans le code. La source `zabbix-source` reçoit `execution_environment: homelab-ee`, parce que le réglage du projet ne vaut pas pour les sources d'inventaire. Mise à jour à chaque lancement et cache à 0 conservés
  - `requirements.yml` : versions exactes, identiques à l'image 1.0. Il ne sert plus qu'à construire l'EE
  - `--check --diff` avant l'application : 3 changements (le réglage, le projet, la source), rien d'autre. Le journal d'activité du projet ne montre que `default_environment: null → homelab-ee`. Second passage : `changed=0`
  - vérifié avec `lab-site` lancé à la main (job 222) : réussi en 32 s dans `homelab-ee`. Mise à jour du projet avec dépendances en **2,9 s** (update 223), synchro de `zabbix-source` en 6 s dans `homelab-ee`. Les 4 tâches `changed` par hôte (fichier `trace` du jour, `zabbix-agent2`) l'étaient déjà dans l'ancienne EE (job 218) : pas de régression
  - au passage : le README annonçait le credential `homelab-token` pour la synchro du dépôt. En réalité, le projet n'a jamais eu de credential (dépôt public, `credential: null` depuis sa création). README corrigé
  - nouvelle contrainte : ajouter ou changer une collection demande de reconstruire l'image et de changer son tag (procédure dans le README)
  - vérifié de bout en bout par la CI, en poussant `ae440c6` : le runner a lancé `lab-site` (job 226), avec la mise à jour du projet sur le nouveau commit en **3,1 s** (update 227, au lieu de minutes). Job réussi en 31 s dans `homelab-ee`, même récapitulatif que le job 222

### 15/10/2026

- Stack relancée (Zabbix, Proxmox, AWX) sur un poste qui sortait d'un arrêt complet. OPNsense et `lab-vm-2` démarrent seules, `fw-debian` reste éteinte.
- **Gain sur les mises à jour du projet AWX confirmé sur un vrai premier démarrage.** API d'AWX disponible 34 s après le démarrage de la VM. Première mise à jour du projet 8 (update 230, lancée à la main) : **4,1 s** dans `homelab-ee`, avec les trois tâches Galaxy sautées (`skipped=4`). Avant le passage des collections dans l'EE, il fallait compter 4 à 14 minutes.
- `lab-vms-provision` (job 231) : `fw-debian` et `lab-vm-3` démarrées.
- **Bascule réseau de `lab-crash-1` en code** : Job Template `lab-crash-net` (`lab_crash_net.yml`), questionnaire `lan-a` / `invites-a` / `lan-b` / `invites-b`. Il change le bridge et le tag de `net0` en gardant la MAC (donc la réservation `10.10.10.50` sur le site A), puis redémarre la VM pour qu'elle reprenne un bail. Le LAN du site A n'avait plus aucune VM pour tester l'IPsec, et une VM de plus aurait pesé sur la RAM de Proxmox. Première version fausse : elle ne changeait que le tag, en supposant `vmbr1`, alors que `lab-crash-1` est sur `vmbr2` depuis le 12/10. Sans tag, elle s'est retrouvée sur le LAN du site B (`10.10.20.220`, vu dans sa console). Corrigé (`d62bb66`), puis passée en `lan-a` (job 248) : elle répond en `10.10.10.50`.
- **IPsec site à site entre OPNsense (site A) et `fw-debian` (site B)**, LAN à LAN (`10.10.10.0/24` ↔ `10.10.20.0/24`) :
  - IKEv2, authentification par clés publiques RSA 3072 : chaque pare-feu génère sa paire, seules les clés publiques sont dans le repo. Propositions `aes256gcm16-sha256-ecp256` (IKE) et `aes256gcm16-ecp256` (ESP), identiques des deux côtés
  - `fw-debian` : nouveau rôle `ipsec_site` (playbook `38_ipsec_site.yml`, groupe `routers`, avant nftables). strongSwan en `charon-systemd` + `swanctl`, clé générée sur place dans `/etc/swanctl/private`, clé publique du pair dans `host_vars`. Tant que la clé du pair manque, le rôle crée seulement sa clé et l'affiche, comme le client WireGuard
  - `host_firewall`, mode routeur : liste `ipsec` (`peer`, `remote_net`). Elle ouvre IKE (UDP 500/4500) et ESP depuis le pair seulement, laisse entrer dans le LAN le réseau distant à condition qu'il sorte du déchiffrement (`meta ipsec exists` : une adresse du site A usurpée en clair sur le WAN ne passe pas), et exclut du masquage le trafic LAN → réseau distant. Sans cette exception, la source serait réécrite en `192.168.122.120` et ne correspondrait plus à la politique IPsec
  - au passage, les redirections de ports de `fw-debian` sont limitées à son adresse (`fib daddr type local`). Avant, tout TCP/80 arrivant par le WAN était redirigé vers `lab-vm-3`, y compris vers une autre machine du LAN jointe directement (route d'administration, et maintenant tunnel)
  - OPNsense : `tools/opnsense_ipsec.py` (paires de clés, connexion, local, remote, child), même principe que `opnsense_wireguard.py`. La paire du site A est générée par `ipsec/key_pairs/gen_key_pair` et sa clé privée ne passe qu'en mémoire. OPNsense monte le tunnel (`trap|start`), `fw-debian` attend (`trap`)
  - règles (`tools/opnsense_rules.py`) :

    | # | Interface | Action | Flux |
    |---|---|---|---|
    | 630–632 | WAN | Pass | UDP 500, UDP 4500 et ESP depuis `192.168.122.120` vers l'adresse WAN |
    | 900 | IPsec (`enc0`) | Pass | `10.10.20.0/24` → LAN |
    | 910 | IPsec (`enc0`) | Block, journalisé | tout le reste |

    OPNsense pose déjà des règles automatiques pour IKE et ESP sur le WAN (c'est ce qui a laissé passer la première négociation). Les règles 630–632 rendent ce flux explicite, versionné et limité au pair
  - déployé par la CI (`lab-site`, job 243, aucun échec). Phase 1 et CHILD_SA `site-a-lan` établies dès le premier essai
- **Vérifié** :
  - site B → site A, depuis `lab-vm-3` : ping et HTTPS de `10.10.10.1`, ping et SSH de `lab-crash-1` (`10.10.10.50`). Un balayage de `10.10.10.0/24` par le tunnel a aussi servi à constater que `lab-crash-1` n'était pas sur le LAN A
  - site A → site B, depuis `lab-crash-1` (commande ad hoc d'AWX) : `lab-vm-3` en ping, HTTP et SSH, route via `10.10.10.1`. SSH de `fw-debian` (`10.10.20.1`) bloqué et journalisé `nft-drop` avec `SRC=10.10.10.50`. Invités du site B (`10.10.41.1`) et WireGuard du site B (`10.10.98.1`) bloqués : ils ne sont pas dans la politique et partent en clair
  - hors tunnel depuis le site B : DMZ (`10.10.30.101`) et invités du site A (`10.10.40.1`) fermés, compteurs de la SA inchangés
  - sites publiés des deux côtés toujours en `200`, la redirection de `fw-debian` comprise
  - `swanctl --list-sas` sur `fw-debian` : compteurs `in` et `out` qui montent pendant les tests. Côté OPNsense, `ipsec/sessions/search_phase1` : `connected`, `public key` des deux côtés. `search_phase2` renvoie une liste vide en GET : il faut un POST avec l'`id` de la phase 1 (`{"id": "<uuid de la connexion>"}`). On y voit alors la CHILD_SA `INSTALLED`, avec les mêmes compteurs que sur `fw-debian`, inversés
- `lab-crash-1` reste sur le LAN du site A pour l'instant. Pour la remettre en invités du site B : `lab-crash-net` avec `invites-b`.

### 16/10/2026

- Stack relancée (Zabbix, Proxmox, AWX), `fw-debian` et `lab-vm-3` démarrées par `lab-vms-provision` (job 259), runner GitHub relancé.
- **SNMP sur OPNsense essayé, puis retiré.** Plugin `os-net-snmp` installé à la main (la clé API n'a pas les droits sur le firmware), configuré par l'API en SNMPv3 authPriv seul, avec une règle WAN UDP 161 depuis l'hôte, et l'hôte `opnsense` créé dans Zabbix avec le modèle « OPNsense by SNMP ». Le v3 répondait depuis l'hôte et le v2c (`public`) non. Mais deux obstacles (voir Problèmes rencontrés) : le modèle lit pf dans `BEGEMOT-PF-MIB`, que Net-SNMP n'a pas, et le serveur Zabbix, dans un conteneur Docker, ne peut pas ouvrir de connexion vers le WAN du lab. Service désactivé, utilisateur et règle supprimés, mots de passe effacés.
- **Supervision des deux pare-feu par l'agent Zabbix, avec un modèle commun** :
  - modèle `zabbix/templates/pare-feu.yaml`, « Pare-feu by Zabbix agent active », importé par `tools/zabbix_firewalls.py`. Mêmes clés sur les deux pare-feu, chacune avec sa commande :

    | Clé | OPNsense (pf) | `fw-debian` (nftables) |
    |---|---|---|
    | `fw.states.count` / `fw.states.limit` | `pfctl -si` / `pfctl -sm` | `nf_conntrack_count` / `nf_conntrack_max` (`/proc`, sans root) |
    | `fw.rules.count` | `pfctl -sr \| wc -l` (règles automatiques comprises) | lignes à `handle` de `nft -a list ruleset`, hors tables et chaînes |
    | `fw.ipsec.sa` | `swanctl --list-sas`, lignes `INSTALLED` | idem |
    | `fw.wg.peers` | `wg show all latest-handshakes`, handshake de moins de 3 min | idem |

    Déclencheurs : plus de données depuis 5 min (haute), table des états à plus de 80 % (moyenne), tunnel IPsec tombé depuis 5 min (moyenne), règles modifiées (information, fermeture manuelle). `fw.states.util` est calculé par Zabbix. Les nombres de règles ne se comparent pas entre les deux pare-feu, seulement dans le temps
  - OPNsense : plugin `os-zabbix-agent` installé à la main, configuré par `tools/opnsense_zabbix_agent.py`. Agent actif vers `192.168.50.6` (comme les VMs du lab), mode passif limité à `127.0.0.1`, pas de commandes à distance, UserParameters sans paramètres, et `sudoRoot` pour `pfctl` et `swanctl`. Hôte `opnsense` en agent actif seul, sans interface, dans « Network Devices »
  - `fw-debian` : rôle `zabbix_agent2` étendu (`zbx_userparameters`, `zbx_sudo_commands`), avec un `sudoers` limité aux trois commandes exactes et validé par `visudo`. Déployé par la CI (`lab-site`, job 261)
- **Vérifié** : les cinq clés remontent sur les deux hôtes. Sur `fw-debian`, avec le compte `zabbix` (`zabbix_agent2 -t`) : 130 états, limite 65536, 34 règles. Un `sudo` hors liste est refusé (`a password is required`). OPNsense : 171 états, limite 200500, 122 règles.
- **Premier constat de la supervision : tunnel IPsec tombé depuis le démarrage** (`fw.ipsec.sa = 0` des deux côtés). OPNsense avait démarré avant `fw-debian` et abandonné après un seul essai. Corrigé par `keyingtries = 0` (essais sans fin), et le tunnel est remonté dès le rechargement.
- **Test de coupure** : strongSwan arrêté 7 min sur `fw-debian`. L'alerte « tunnel IPsec site à site tombé » s'est levée sur les deux hôtes au bout de 5 min. Mais le tunnel n'est pas revenu au redémarrage (voir Problèmes rencontrés), d'où `close_action = start`. Nouveau test (2 min d'arrêt) : tunnel remonté seul en **46 s**, sans trafic.
- **Alerte « règles modifiées » sur OPNsense à 10:36** (122 → 123), à la suite du rechargement d'IPsec : pf régénère alors ses règles automatiques. Le déclencheur voit donc aussi ces règles-là, pas seulement celles qu'on écrit.

### Prochaine session

- Tableau comparatif OPNsense / nftables pour l'IPsec (comme pour les invités et WireGuard), puis bilan final de la comparaison
- Plus tard, peut-être : passer les règles OPNsense en Ansible (le script `tools/opnsense_rules.py` en est un premier pas)

## Décisions

- **28/09/2026 — OPNsense en premier.** C'est le moyen le plus rapide d'avoir un pare-feu qui marche, et il servira de référence pour la version nftables.
- **28/09/2026 — Mise en place à la main dans l'interface web de Proxmox.** Pas de token API sur le poste pour l'instant. Les étapes sont notées ici pour pouvoir les passer ensuite en Ansible.
- **28/09/2026 — LAN en `10.10.10.0/24`** au lieu du `192.168.1.0/24` par défaut, trop courant sur les box et donc exposé aux collisions. Plan d'adressage :
  - `10.10.10.1` : OPNsense, passerelle et DNS du LAN
  - `.10`–`.199` : adresses fixes (les VMs du lab gardent leur numéro, `lab-vm-1` → `10.10.10.101`)
  - `.200`–`.249` : plage DHCP
- **29/09/2026 — AWX reste sur le WAN et atteint le LAN par une route via OPNsense.** Route `10.10.10.0/24 via 192.168.122.119` sur AWX et sur l'hôte, règle WAN SSH limitée à la source AWX. C'est le schéma d'un réseau d'admin qui accède au LAN à travers un pare-feu filtrant. Mettre AWX derrière le pare-feu aurait obligé à router l'hôte et le runner GitHub vers AWX.
- **29/09/2026 — `lab-vm-2` reste devant le pare-feu, protégée par Ansible.** Deux modèles côte à côte : `lab-vm-1` derrière OPNsense (sécurité périmétrique, règles dans l'appliance) et `lab-vm-2` sur le WAN avec un pare-feu local nftables déployé par AWX (sécurité au niveau de l'hôte, règles versionnées). Le rôle servira aussi pour la version Debian + nftables. Limites assumées : le « WAN » est le réseau NAT de libvirt, pas Internet (menace simulée : une autre machine compromise sur `192.168.122.0/24`) ; en PME, un serveur exposé irait plutôt en DMZ (troisième interface d'OPNsense, `vmbr2`), piste pour plus tard.
- **05/10/2026 — Site de `lab-vm-1` publié par redirection de port, pas par une simple règle Pass.** Le client ne connaît que l'adresse WAN d'OPNsense, comme en PME avec une IP publique, et la route vers le LAN reste réservée à l'administration. Option Firewall rule = **Pass** (`rdr pass`) : la redirection laisse passer le trafic sans règle dans Règles → WAN. C'est plus simple, mais la règle n'apparaît pas avec les autres règles WAN : pour la retrouver, il faut regarder dans le NAT.

- **06/10/2026 — Debian + nftables en site B parallèle, pas à la place d'OPNsense.** Nouveau LAN `10.10.20.0/24` sur `vmbr2` : les deux pare-feu tournent côte à côte, ce qui permet de les comparer en direct sans couper `lab-vm-1`, et prépare un IPsec site-à-site entre les deux. La DMZ prévue sur `vmbr2` passe donc sur `vmbr3`.
- **09/10/2026 — DMZ sur OPNsense, et `lab-vm-1` (le site publié) déplacée dedans.** Le LAN n'héberge plus aucun serveur exposé : si le serveur web est compromis, l'attaquant reste enfermé en DMZ, sans accès au LAN, au site B ni au WAN du lab. Pas de nouvelle VM (la RAM de Proxmox est limitée à 10 Gio). Sorties de la DMZ limitées à ce dont le serveur a besoin (DNS, apt, NTP, Zabbix). Les blocages DMZ → LAN et DMZ → privé sont explicites et journalisés, pour qu'une tentative de rebond soit visible dans les logs.
- **09/10/2026 — Règles de la DMZ posées par l'API, pas dans l'interface.** Script versionné et idempotent : les règles sont relues dans le repo, et c'est un premier pas vers OPNsense en code. Pas de retour arrière automatique, parce que l'API de la 26.7 n'a pas de savepoint pour ces règles (`404`). Le script n'ajoute donc que des règles DMZ et des Pass WAN → DMZ, et ne touche jamais à l'accès au pare-feu.
- **06/10/2026 — Mode routeur ajouté au rôle `host_firewall`, pas de nouveau rôle.** Même gabarit, même retour arrière automatique : un hôte reste un pare-feu d'hôte tant que `host_firewall_router` est vide. Interfaces nommées dans `host_vars` (et vérifiées par une assertion) plutôt que devinées depuis les faits.
- **12/10/2026 — VLAN invités sur le trunk du LAN, pas une quatrième carte.** Un seul port physique pour plusieurs réseaux, comme sur un switch de PME : `vmbr1` devient un trunk, et chaque réseau supplémentaire ne coûte qu'un tag, sans carte ni bridge en plus. Le LAN reste non étiqueté, pour ne rien casser. Le réseau invités n'a droit qu'à Internet : aucune règle d'administration, car un poste invité n'est pas géré. `lab-crash-1` sort donc d'AWX et de Zabbix tant qu'elle y est, et se teste depuis sa console.
- **12/10/2026 — Invités du site B en `10.10.41.0/24`, pas `10.10.40.0/24`.** Le numéro de VLAN (40) est le même : un tag n'a de sens qu'à l'intérieur d'un site. Mais deux sites qui seront reliés par IPsec ne doivent pas avoir de sous-réseaux qui se chevauchent, même pour un réseau qui ne passera pas dans le tunnel. Sinon, une route ou une règle écrite pour l'un vise aussi l'autre.
- **12/10/2026 — Invités de `fw-debian` dans `host_firewall` (liste `guests`), pas dans `forward_rules`.** `forward_rules` décrit ce qui entre du WAN vers le LAN. Les invités vont dans l'autre sens et ont une règle de fond différente (« tout sauf le privé »). Une liste à part garde chaque règle lisible dans `host_vars`.
- **13/10/2026 — Pas de NAT entre le WAN du lab et les LAN `10.10.0.0/16`, plutôt que de retirer l'hôte des règles.** Le masquage cachait la vraie source : c'est la cause, et on la corrige sur l'hôte, par un hook réseau de libvirt versionné dans `bootstrap/libvirt-hooks/`. Les règles des pare-feu redeviennent justes sans y toucher. L'autre option (ne plus faire confiance à `192.168.122.1` et administrer depuis le poste par WireGuard) reste une piste « zéro confiance » pour plus tard.
- **13/10/2026 — WireGuard en accès distant (télétravail), tunnel partagé.** `lab-vm-2` sert de poste à distance : depuis la correction du NAT de libvirt, elle n'a plus aucun accès aux LAN sans tunnel, ce qui rend le test probant. Seuls le tunnel et le LAN du site A passent par WireGuard (`AllowedIPs`) : le reste du trafic du client sort normalement, et la règle 810 bloque tout autre usage du tunnel. Réseau de tunnel distinct (`10.10.99.0/24`), pour filtrer les télétravailleurs comme une zone à part.
- **14/10/2026 — Collections AWX dans l'image `homelab-ee`, plus téléchargées à la mise à jour du projet.** Le projet reste mis à jour à chaque lancement, sans cache, pour que la CI déploie toujours le dernier commit. C'est donc le téléchargement qui disparaît, pas la mise à jour. Avantages : une mise à jour du projet prend quelques secondes, sans dépendre de Galaxy, et tous les jobs tournent dans la même image épinglée, ce qui les rend reproductibles. Inconvénient accepté : une nouvelle collection demande de reconstruire l'image. C'est rare dans ce lab, et c'est la pratique recommandée pour AWX en production.
- **15/10/2026 — IPsec authentifié par clés publiques, pas par clé pré-partagée.** Une PSK est plus courante en PME, mais c'est un secret à garder hors d'un dépôt public et à recopier des deux côtés. Avec des clés publiques, c'est le même modèle que WireGuard : la clé privée ne quitte pas son pare-feu, et ce qui est versionné ne permet pas d'usurper un site.
- **15/10/2026 — Tunnel en mode politique, LAN à LAN seulement.** Pas d'interface de tunnel routée (VTI) : les deux pare-feu n'ont qu'une paire de réseaux à relier, et les sélecteurs de trafic suffisent. Les invités, la DMZ et les réseaux WireGuard restent hors du tunnel. Côté nftables, le transit est réservé aux paquets déchiffrés, pour que le tunnel ne devienne pas une porte d'entrée sur le WAN.
- **15/10/2026 — `lab-crash-1` sert de machine de test sur le LAN A, plutôt qu'une nouvelle VM.** La bascule passe par AWX (le token Proxmox n'est pas sur le poste) et ne change que le bridge et le tag : elle se défait en relançant le même Job Template.
- **16/10/2026 — Supervision des pare-feu par l'agent Zabbix, pas par SNMP.** SNMP était prévu au départ, parce que c'est l'usage pour un équipement réseau. Mais le modèle de Zabbix pour OPNsense suppose `bsnmpd`, qui ne se règle ni dans l'interface ni par l'API, et Net-SNMP n'a pas la MIB pf. L'agent donne exactement ce qu'on veut suivre, avec la même méthode sur les deux pare-feu. Il marche en mode actif, ce qui contourne le blocage de libvirt, et il est piloté par l'API d'un côté et par Ansible de l'autre.
- **16/10/2026 — Un modèle commun aux deux pare-feu, avec les mêmes clés.** Une alerte (tunnel tombé, table des états pleine) a le même nom et le même seuil sur les deux, ce qui rend la comparaison directe. Seule la commande derrière chaque clé change.
- **16/10/2026 — Root pour l'agent d'OPNsense, au plus juste sur `fw-debian`.** `pfctl` et `swanctl` demandent root des deux côtés. Sur Debian, le `sudoers` n'autorise que trois commandes avec leurs arguments exacts. Sur OPNsense, le plugin n'a qu'un interrupteur (`sudoRoot`), avec des droits larges : un agent compromis vaudrait root. Garde-fous : pas de commandes à distance, UserParameters figés et sans paramètres, pas d'écoute réseau. C'est un écart notable entre les deux solutions.
- **16/10/2026 — OPNsense seul initiateur du tunnel IPsec.** `fw-debian` reste en `trap`. OPNsense monte le tunnel au démarrage, après une panne détectée et après un `DELETE` du pair, avec des essais sans fin. Un seul initiateur évite deux négociations simultanées.

## Points ouverts

- **Première mise à jour du projet AWX après démarrage : 4 à 14 minutes** (projets 197, 201, 203, 207), presque tout dans le téléchargement des collections de `requirements.yml`. Les jobs lancés pendant ce temps restent en `pending`, y compris le pipeline. Pistes : garder les collections dans l'environnement d'exécution, ou ne plus mettre à jour le projet à chaque lancement. **Réglé le 14/10/2026 : collections dans l'EE (voir Journal et Décisions). Mise à jour avec dépendances en 2,9 s. Confirmé le 15/10 sur un premier démarrage d'AWX : 4,1 s.**
- **Accès d'AWX aux VMs du lab une fois derrière le pare-feu.** Le Job Template `lab-site` vise `lab-vm-1`/`lab-vm-2` en `192.168.122.101`/`.102` (`ansible/inventory/lab_vms_static.yml`), et `proxmox_provision_vms.yml` fixe leur IP et la passerelle `192.168.122.1` par cloud-init. En passant ces VMs sur `vmbr1`, AWX (`192.168.122.148`) ne les voit plus, et la CI/CD casse. Pistes : une route vers `10.10.10.0/24` via `192.168.122.119` sur AWX (et sur l'hôte) plus une règle WAN SSH depuis AWX, ou AWX lui-même derrière le pare-feu. À trancher avant de déplacer `lab-vm-1`/`lab-vm-2`. **Tranché le 29/09/2026 : route (voir Décisions).**

## Problèmes rencontrés

- **Net-SNMP d'OPNsense sans les statistiques de pf (16/10/2026).** Avec le modèle « OPNsense by SNMP », Zabbix signalait `cannot retrieve OID: '.1.3.6.1.4.1.12325.1.200.1.3.1.0'`. Depuis l'hôte, en SNMPv3 : `No Such Object available on this agent at this OID` pour toute la branche `.1.3.6.1.4.1.12325` (`BEGEMOT-PF-MIB`), alors que `IF-MIB` répondait. Cette MIB vient de `bsnmpd`, le démon SNMP de FreeBSD, pas de Net-SNMP. Résolu en passant par l'agent Zabbix (voir Décisions).
- **Le serveur Zabbix ne joint pas le WAN du lab (16/10/2026).** `snmpget` passait depuis l'hôte, mais Zabbix restait en `timed out`. Le conteneur (`172.20.0.3`) sort vers `virbr0`, et le réseau NAT de libvirt n'y laisse entrer que des réponses : une nouvelle connexion venant d'une autre interface est refusée, et seul l'hôte y échappe. Non vérifié dans les règles (lecture de nftables impossible sans `sudo`). Sans conséquence jusqu'ici : tous les agents du lab sont actifs, et c'est encore le cas pour les pare-feu.
- **Mots de passe SNMPv3 affichés dans une sortie de commande (16/10/2026).** Une commande `snmpget` mal découpée par zsh (variable non séparée en arguments) a fait afficher les mots de passe dans son message d'erreur. Ils ont été supprimés avec le reste de SNMP. À retenir : sous zsh, passer les options par un tableau sous bash, et masquer les secrets dans les sorties.
- **Tunnel IPsec pas remonté quand `fw-debian` démarre après OPNsense (16/10/2026).** Vu par la supervision : `fw.ipsec.sa = 0` des deux côtés dès la première collecte. OPNsense avait essayé de monter le tunnel à son démarrage, contre un pair encore éteint, et avait abandonné après un seul essai (`keyingtries` vide = 1). `fw-debian`, en `trap`, attendait du trafic. Correction : `keyingtries = 0`.
- **Tunnel IPsec pas remonté après un redémarrage propre de strongSwan sur `fw-debian` (16/10/2026).** À l'arrêt, `fw-debian` envoie un `DELETE` (`sending DELETE for IKE_SA site-a[1]`). Pour OPNsense, c'est une fermeture voulue et non une panne : `dpd_action` ne s'applique pas, et `close_action = none` ne fait rien, à part garder le piège (`routed`, mais pas `connected`). Correction : `close_action = start`. Après un arrêt de 2 min, le tunnel est remonté seul en 46 s. Au passage : l'horloge de `fw-debian` est en UTC, donc un `journalctl --since` en heure locale ne montre rien.
- **Éléments de `fw-debian` en « Unknown metric » après le déploiement (16/10/2026).** Le modèle avait été lié avant que les UserParameters soient déployés. Un élément non supporté n'est revérifié qu'à sa propre fréquence, et « Execute now » refuse les éléments d'agent actif (`wrong item type`). `fw.states.limit`, relevé toutes les heures, serait resté en erreur jusqu'à une heure. Fréquence passée à 10 min.

- **`lab-crash-1` sur le mauvais site après la bascule (15/10/2026).** Le premier `lab-crash-net` (job 234) n'enlevait que le tag de `net0`, en supposant la VM sur `vmbr1`. Elle était sur `vmbr2` depuis le 12/10 (Journal), et s'est donc retrouvée sur le LAN du site B. Symptômes : SSH d'AWX vers `10.10.10.50` en délai dépassé, aucune réponse dans tout `10.10.10.0/24` (balayage depuis `lab-vm-3` par le tunnel), puis `10.10.20.220 via 10.10.20.1` dans la console. Correction : le playbook fixe le bridge et le tag. À retenir : relire l'état réel (ou le dernier changement noté), pas seulement la première description de la VM.
- **Proxmox répond 500 au démarrage d'une VM qui redémarre (15/10/2026).** Job 248 : `starting of VM 103 failed with exception: 500 Internal Server Error: failed to open PSS memory-stat from process - No such process`. La tâche « Démarrer la VM » suivait immédiatement un `state: restarted`, pendant que l'ancien processus QEMU disparaissait. La VM a bien redémarré. Correction : pas de démarrage juste après un redémarrage.
- **Objets IPsec d'OPNsense recréés à chaque passage du script (15/10/2026).** Vu au `--dry-run` du deuxième passage, avant tout doublon : `local`, `remote` et `child` étaient cherchés par la description de la connexion, mais la colonne `connection` des listes contient son UUID (la description est dans `%connection`). Corrigé : recherche par UUID, puis un dry-run ne prévoit plus que des mises à jour.

- **Proxmox de nouveau en `KERNEL PANIC` (13/10/2026), malgré `no-kvmapf`.** Vers 09:30, après une matinée de travail : plus aucune VM du lab ne répond (« No route to host »), et le job `lab-site` 212 (déploiement de `f286b53`) échoue en `unreachable` sur les quatre hôtes. La VM `proxmox-lab` est toujours « en cours d'exécution » pour libvirt et consomme encore du CPU, mais sa console (`virsh screenshot`) affiche `KERNEL PANIC! Attempted to kill the idle task!`. Le message diffère de celui du 09/10 (`Host injected async #PF`), mais le contexte est le même : sur le poste, 25 Gio de RAM utilisés sur 31 et 7 Gio en swap (Proxmox 10 Gio, AWX, Zabbix sous Docker, bureau). La cause n'est pas prouvée. Piste principale : la pression mémoire sur l'hôte en virtualisation imbriquée, que `no-kvmapf` ne couvre qu'en partie. À vérifier au prochain démarrage : `journalctl -k -b -1` dans Proxmox, et réduire la mémoire totale des VMs, ou au moins le swap de l'hôte.
  **Vérifié le 14/10/2026.** Dans Proxmox, `journalctl -k -b -1` ne montre rien d'utile : le boot du 13/10 commence à 10:21 et le journal s'arrête à 11:17:01, sans aucune trace de la panique (un noyau en panique n'écrit plus sur le disque). Seuls des avertissements de démarrage sans rapport (`unstable TSC`, dépendance de fonctionnalités CPU). Le poste, lui, apporte un indice : à l'arrêt forcé de la VM (11:34), systemd indique pour `proxmox-lab` **6,3 Gio de mémoire au plus haut et 2,3 Gio de mémoire de la VM passés en swap par l'hôte** (AWX : 5,7 Gio et 915 Mio en swap). C'est exactement la situation que `no-kvmapf` devait rendre sans danger. L'hypothèse de la pression mémoire est renforcée, sans être prouvée. Piste de correction : verrouiller la RAM de `proxmox-lab` dans libvirt (`<memoryBacking><locked/></memoryBacking>`), pour que l'hôte ne puisse plus du tout la mettre en swap.
  **Appliqué le 14/10/2026** avec `virt-xml proxmox-lab --edit --memorybacking locked=on`, après un arrêt propre de la VM. Vérifié après redémarrage : `VmLck` à 10,9 Gio et `VmSwap` à 0 pour le processus QEMU. Le verrouillage ne vaut que pendant que la VM tourne : quand elle est éteinte, rien n'est réservé. En contrepartie, les autres processus du poste se partagent ce qui reste, et ce sont eux qui partent en swap s'il en manque. Pendant une session lab, mieux vaut donc ne pas lancer d'autre gros consommateur de RAM (un jeu avec `-Xmx8192m` a suffi à faire tomber le poste à 1,8 Gio disponible).
- **Toute VM du WAN du lab vue comme l'hôte `192.168.122.1` par les pare-feu (13/10/2026).** Constaté depuis `lab-vm-2` sans tunnel : `10.10.10.1:443` et `10.10.20.101:22` ouverts. `tcpdump` sur `eth0` de `fw-debian` : le SYN de `lab-vm-2` arrive avec la source `192.168.122.1`. Chemin : `lab-vm-2` → passerelle = l'hôte → route `10.10.20.0/24 via .120`. Au passage, la règle de libvirt `ip saddr 192.168.122.0/24 ip daddr != 192.168.122.0/24 masquerade` (chaîne `guest_nat` de la table `ip libvirt_network`) masque aussi ce trafic, qui ne quitte pourtant pas le lab. Toutes les règles qui autorisent l'hôte autorisaient donc toute VM du WAN : la menace prévue le 29/09 passait.
  - correction : un hook `/etc/libvirt/hooks/network` pose `ip saddr 192.168.122.0/24 ip daddr 10.10.0.0/16 return` en tête de `guest_nat`
  - premier piège, la position : au démarrage, `libvirtd` repose ses propres règles au-dessus de celle du hook, qui ne sert alors plus à rien (vérifié par `nft list chain`, règle en ligne 9 sous les trois `masquerade`). Le hook supprime puis repose sa règle en tête, et un drop-in systemd (`ExecStartPost`) le relance une fois `libvirtd` prêt
  - second piège, le diagnostic : un `grep` qui ne gardait que `masquerade|snat` cachait la ligne `return`, et la règle a semblé disparue alors qu'elle était seulement mal placée
  - il n'y avait pas d'autre masquage en jeu : les règles iptables-nft de Docker (`172.17–20.0.0/16`) et de Tailscale (`ts-postrouting`, par marque) ne visent pas le lab
  - rien ne dépendait de ce masquage : AWX joint les LAN directement par `.119` et `.120`, le trafic de l'hôte part déjà en `192.168.122.1`, et les sites publiés se joignent par l'adresse WAN des pare-feu
- **Aucun DHCP sur le VLAN 40 du site B : le port de `fw-debian` restait dans le VLAN 1 (12/10/2026).** `lab-crash-1` sans adresse, et `tcpdump -eni eth1 "vlan 40 or port 67 or port 68"` sur `fw-debian` ne voyait rien en 45 s. Le problème était donc dans Proxmox. `bridge vlan show` : `tap103i0` en `40 PVID`, mais `tap120i1` (LAN de `fw-debian`) en `1 PVID` seul. `fw-debian` tournait quand `vmbr2` est passé en « VLAN aware », et Proxmox ne pose la liste des VLAN d'un port (`2-4094`) qu'au démarrage de la VM. Correction à chaud : `bridge vlan add dev tap120i1 vid 2-4094` ; au prochain démarrage de la VM, Proxmox le fait lui-même. OPNsense n'a pas eu le souci sur `vmbr1`. À retenir : après avoir coché « VLAN aware », redémarrer (ou corriger à chaud) les VMs déjà branchées en trunk.
- **`lab-crash-1` sans adresse au premier démarrage dans le VLAN 40 (12/10/2026).** `ip -4 -br a` ne montrait que `lo`. Le chemin a été coupé en deux : `tcpdump -ni vlan01 port 67 or port 68` sur OPNsense ne voyait rien passer, mais le bridge était bon (`bridge vlan show`). Un `dhclient` lancé à la main pendant un `tcpdump -eni vtnet1 vlan 40` a eu son bail tout de suite, et `systemd-networkd` a aussi fini par obtenir le sien (deux routes par défaut). Après un redémarrage, l'adresse arrive seule. Cause non prouvée : probablement l'ancien bail `10.10.10.50` gardé par la VM, ou un test lancé avant la fin du DHCP. Le premier réflexe à avoir : `networkctl status eth0` avant de soupçonner le réseau.
- **Proxmox figé puis en `KERNEL PANIC` : *async page fault* de KVM en virtualisation imbriquée (09/10/2026).** Trois symptômes dans la même journée, avec une seule cause :
  - le DNS d'OPNsense ne répondait plus au LAN depuis le démarrage, alors que le ping, le NAT et la redirection marchaient. `apt-get update` restait bloqué sur `lab-vm-1` et gardait le verrou apt, d'où l'échec de `lab-site` sur cette VM (`Could not get lock /var/lib/apt/lists/lock`)
  - la VM 105 refusait de redémarrer : `timeout waiting on systemd`. Le cgroup `105.scope` contenait encore l'ancien QEMU (PID en `Z`, invisible dans `ps -ef | grep 'kvm -id 105'` car sans ligne de commande), dont un thread restait en `D` dans `kvm_async_pf_task_wait_schedule`. Aucun signal ne le débloque : `proxmox-lab` a été redémarrée (`virsh shutdown`, sans effet au bout de 2 minutes, puis `destroy`/`start`)
  - quelques minutes après, l'écran de `proxmox-lab` affichait `KERNEL PANIC! Host injected async #PF in kernel mode`
  
  Explication : quand l'hôte met en swap une page mémoire de la VM Proxmox, KVM le signale au noyau invité par un *async page fault*, et ce noyau met le thread concerné en attente. Avec la virtualisation imbriquée, la notification « page prête » peut ne jamais arriver (blocage), ou le défaut tombe pendant que le noyau lui-même s'exécute (panique). Le poste utilisait 6 Gio de swap (32 Gio de RAM, dont Proxmox 10 Gio, AWX, Zabbix et d'autres conteneurs). Correction : paramètre `no-kvmapf` ajouté au noyau de Proxmox. Sans ce mécanisme, la VM est ralentie si l'hôte swappe, mais elle ne plante plus.
- **Interface DMZ en `/32` après réactivation (09/10/2026).** Après le plantage, l'interface DMZ était désactivée. Elle a été réactivée avec le masque par défaut du menu déroulant, `32`. Dans pf, `(vtnet2:network)` valait alors `10.10.30.1/32` : `lab-vm-1` ne faisait plus partie de « DMZ net », ses requêtes DNS tombaient sur « Default deny / state violation rule », et OPNsense n'avait plus de route connectée vers `10.10.30.0/24` (ping impossible, alors que la VM figurait dans la table ARP). Diagnostic : `ifconfig vtnet2` affichait `netmask 0xffffffff`, et `pfctl -sr` montrait des règles correctes. Correction : masque `24` dans Interfaces → [DMZ]. À retenir : après avoir enregistré une interface, vérifier le masque dans `ifconfig`.
- **Tests de ports faussés : `nc` absent de l'image des VMs (09/10/2026).** Un test `nc -z` en échec donnait « bloqué » pour tous les flux, y compris Zabbix, qui marchait. Pour un test fiable sans installer d'outil : `timeout 4 bash -c 'echo > /dev/tcp/<ip>/<port>'` (code `124` = délai dépassé).

- **Nouvelles VMs injoignables par AWX : `172.20.0.1` dans l'inventaire (06/10/2026).** Création des hôtes `fw-debian` et `lab-vm-3` dans Zabbix par l'API, avec leur vraie IP. À la première connexion de l'agent actif, l'action « Auto-register lab VMs » (métadonnées `lab-vm`) a réécrit l'interface avec l'adresse source vue par le serveur : `172.20.0.1`, la passerelle du réseau Docker `homelab-zabbix_default`. Le trafic de l'agent vers le serveur Zabbix conteneurisé est traduit (NAT) sur l'hôte. L'inventaire AWX prend `ansible_host` dans cette interface, d'où le délai dépassé en SSH. Correction : IP remises par `hostinterface.update`, comme pour `lab-crash-1` le 01/10. Elles tiennent, car l'auto-enregistrement ne rejoue que si les données de connexion de l'agent changent. À retenir : après l'inscription d'une VM, vérifier l'IP de son interface dans Zabbix.
- **DNS de `lab-vm-3` inchangé après redémarrage (06/10/2026).** Le changement de DNS dans cloud-init n'est pas pris en compte par un `reboot` lancé depuis la VM : le processus QEMU reste le même, et Proxmox ne régénère le lecteur cloud-init qu'au démarrage de la VM. Il faut un arrêt complet (`poweroff`) puis un démarrage, fait ici par `lab-vms-provision` (tâche « Démarrer les VMs »). Effet attendu ensuite : la configuration a changé, donc l'instance-id aussi, et cloud-init régénère les clés d'hôte SSH. D'où l'alerte « REMOTE HOST IDENTIFICATION HAS CHANGED », réglée par `ssh-keygen -R 10.10.20.101`.
- **`fw-debian.siteb.lab` résolu aussi en `127.0.1.1` (06/10/2026).** dnsmasq publie par défaut le `/etc/hosts` du pare-feu, où Debian associe son nom à `127.0.1.1`. Correction : `no-hosts`. Seuls les `host-record` versionnés comptent.
- **Runner GitHub arrêté, runs en file depuis le matin (06/10/2026).** Au démarrage de la stack, le contrôle `pgrep -f actions-runner` avait conclu que le runner tournait. C'était un faux positif : `pgrep` trouvait la ligne de commande du contrôle lui-même. Les pushs du jour ont mis les runs « Ansible deploy » et « Hello World » en file sans les lancer. Les déploiements ont été faits en lançant directement le Job Template `lab-site` dans AWX. Contrôle fiable : `pgrep -f Runner.Listener`. **Faux aussi (09/10/2026)** : lancé dans un `bash -c`, `pgrep -f` voit `Runner.Listener` dans la ligne de commande du shell qui l'exécute, et le PID renvoyé n'existait déjà plus. Contrôle fiable : `pgrep -x Runner.Listener`, qui compare le nom du processus et pas sa ligne de commande.

- **Provisioning : `500 Internal Server Error: no options specified` sur la carte réseau (06/10/2026).** Les clones `fw-debian` et `lab-vm-3` étaient créés, puis l'étape qui branche `net0` échouait. Premier diagnostic faux (une liste de cartes construite par une expression Jinja) : l'erreur est restée avec un simple `net0`. Vraie cause : par sécurité, `proxmox_kvm` retire `net` des mises à jour, sauf avec `update_unsafe: true`. La requête partait donc vide. Avec cette version du module, le playbook ne pouvait donc pas changer `net0`. `lab-vm-1` avait d'ailleurs été passée sur `vmbr1` à la main. Correction : `update_unsafe: true`, et la tâche lit d'abord la config (`proxmox_vm_info`). Elle ne réécrit une carte que si le bridge diffère, et elle garde sa MAC, ce qui évite un nouveau bail DHCP. Elle n'a donc plus besoin de se limiter à un clone neuf, et elle a corrigé les VMs existantes sans les recréer.
- **Interfaces `eth0`/`eth1` sur `fw-debian`, pas `ens18`/`ens19` (06/10/2026).** L'image cloud du template garde les anciens noms. Relevé par SSH avant le premier passage du rôle (`ip -br a`). L'assertion `Check router interfaces` l'aurait aussi bloqué avant tout changement.

- **Clavier repassé en QWERTY après l'installation.** Le clavier choisi dans l'installeur ne vaut que pour l'installeur. Solution temporaire dans le shell : `kbdcontrol -l fr` (en QWERTY, le `-` est sur la touche `)`). Solution durable : System → Settings → Administration, rubrique Console. **Constaté le 30/09/2026 : le clavier est resté en français après redémarrage, le `kbdcontrol -l fr` a tenu. Plus rien à faire.**

- **« Aucun ISO dans `local` », et `/var/lib/vz` semblait ne pas exister (28/09/2026).** Fausse alerte : le chemin avait été cherché sur le poste, alors qu'il est à l'intérieur de la VM Proxmox. Vérifié dans le Shell du nœud :
  - `local` (dir, `/var/lib/vz`) est actif, 8,7 Gio libres, contenu `iso,vztmpl,backup,import`
  - `/var/lib/vz/template/iso` existe
  - `local-lvm` (lvmthin) est actif, environ 22 Gio libres pour les disques de VM

  La liste était vide simplement parce que l'ISO n'avait pas encore été envoyé.
- **Interfaces inversées au premier démarrage (28/09/2026).** En mode live, OPNsense 26.7 prend la première carte comme LAN : `LAN = vtnet0` (`192.168.1.1/24`) et `WAN = vtnet1`. Or `vtnet0` = `net0` = `vmbr0`, c'est-à-dire le réseau libvirt `192.168.122.0/24`. Deux conséquences : le LAN et son serveur DHCP se retrouvent du côté du réseau existant, et le WAN pointe vers le bridge interne vide. Correction : réaffecter via l'option 1 de la console (`WAN = vtnet0`, `LAN = vtnet1`), puis revérifier après l'installation. Résultat : `WAN = vtnet0`, `LAN = vtnet1` (`192.168.1.1/24`).
- **WAN affiché sans adresse dans la console.** Ce n'est pas une panne : l'en-tête est affiché avant la réponse DHCP. Le DHCP de libvirt a bien donné un bail au WAN : `192.168.122.119` pour la MAC `bc:24:11:4c:44:30` (`net0`). À noter : la plage DHCP de libvirt (`.2`–`.254`) recouvre les IP fixes du lab (`.101`, `.102`, `.106`), donc un conflit d'adresses est possible.
- **Interface web figée pendant la configuration du WAN (28/09/2026).** Le poste est côté WAN, et OPNsense bloque tout ce qui arrive sur le WAN. Accès ouvert temporairement avec `pfctl -d` depuis la console. Mais le Save/Apply sur **Interfaces → WAN** (décocher Block private / bogon networks) a rechargé les règles et réactivé le filtrage, ce qui a coupé l'interface web (plus de HTTPS ni de ping depuis l'hôte). Leçons :
  - `pfctl -d` ne tient que jusqu'au prochain rechargement des règles, et presque chaque Apply en déclenche un.
  - **Block private networks** passe avant les règles utilisateur. Sur un WAN en adresses privées (cas du lab), il faut le décocher avant qu'une règle Pass puisse servir.
  - Après ajout de la règle WAN (Pass TCP `192.168.122.1/32` → This Firewall:443) et Apply, l'interface web ne répond toujours pas (ni HTTPS, ni ping). L'hôte sort bien avec la source `192.168.122.1`. Diagnostic dans la console :
    - `pfctl -si` : filtrage `Enabled`
    - `pfctl -sr` : plus aucune règle private/bogon, mais la règle chargée est `from 192.168.122.1 port = https to (self)`. Le port 443 a été mis dans **Source port range** au lieu de **Destination port range**. Le port source d'un client étant aléatoire, la règle ne correspondait jamais.
    - Correction : source port = any, destination port = HTTPS.
    - Vérifié depuis l'hôte, filtrage actif : HTTPS (443) répond `200`. HTTP (80), SSH (22) et ping restent bloqués. Seul ce qui est autorisé passe.
  - Pour configurer à l'aise : **Firewall → Settings → Advanced → Disable all packet filtering** résiste aux rechargements. À réactiver à la fin.
- **SSH AWX → LAN en timeout alors que le ping passe (29/09/2026).** `pfctl -sr` montrait la règle `pass in quick on vtnet0 reply-to (vtnet0 192.168.122.1) ... from 192.168.122.148 to (vtnet1:network) port = ssh`. Le WAN ayant une passerelle (DHCP), OPNsense ajoute `reply-to` aux règles WAN : le SYN-ACK de `lab-crash-1` part vers l'hôte `192.168.122.1` au lieu de revenir directement à AWX. L'hôte, qui n'a pas vu le SYN, jette le paquet (état invalide). Le ping passait parce que la règle ICMP n'avait pas de `reply-to`. Test utile pour isoler : `nc -zv 10.10.10.220 22` depuis OPNsense lui-même (côté LAN, hors règles WAN) réussissait. Correction : Pare-feu → Paramètres → Avancé → **Disable reply-to on WAN rules**. Sans risque ici : un seul WAN, et les autres règles WAN viennent de la passerelle elle-même.
- **Agent Zabbix de `lab-crash-1` en échec après le changement d'IP (01/10/2026).** `zabbix-agent2` redémarrait en boucle : `cannot parse "ListenIP" parameter: value of ListenIP not present on the host: "192.168.122.50"`. Le modèle du rôle écrit `ListenIP={{ ansible_host }}`, l'IP de la VM au moment du passage. `lab-vm-1` avait changé d'IP sans souci parce que le pipeline `lab-site` a repassé le rôle juste après ; `lab-crash-1`, exclue de `lab-site`, avait gardé l'ancienne valeur. Deux pièges en chemin :
  - l'hôte n'a pas accès en SSH au LAN (règle WAN limitée à AWX) : c'est voulu, le diagnostic passe par une commande ad hoc AWX
  - la première commande ad hoc visait encore `192.168.122.50` : la synchro d'inventaire attendait la mise à jour du projet (premier lancement après le démarrage d'AWX), et les commandes ad hoc ne déclenchent pas `update_on_launch`. Il faut attendre la fin de la synchro avant de lancer la commande.

  **Corrigé le 01/10/2026 (commit `8f4c7fc`)** : le rôle n'écrit plus `ListenIP` (l'agent écoute sur toutes les interfaces, valeur par défaut) et vérifie l'écoute sur `127.0.0.1`. Pas d'exposition en plus : le 10050 reste fermé depuis l'hôte sur les trois VMs (nftables sur `lab-vm-2`, aucune règle OPNsense vers le LAN). Passé par `lab-vms-bootstrap` (job 114) : `agent.ping` reçu ensuite pour `lab-vm-1`, `lab-vm-2` et `lab-crash-1`.
- **Retour arrière nftables : le play « réussissait » la reconnexion après coup (30/09/2026).** Au premier test, « Check that Ansible can still connect » est passé en `ok` au bout de 80 s, puis « Disarm rollback timer » a échoué (`Unit host-firewall-rollback.timer not loaded`). Deux causes :
  - `wait_for_connection` ne vérifie son délai (30 s) qu'entre deux tentatives, et une tentative SSH durait jusqu'à 2 minutes (`timeout = 30` et `retries = 3` dans `ansible.cfg`). La tentative en cours a donc abouti une fois le retour arrière passé. Correction : `ansible_ssh_timeout: 5` et `ansible_ssh_retries: 0` sur cette tâche.
  - le minuteur systemd a joué à 76 s au lieu de 60 : la précision par défaut d'un timer est d'une minute. Correction : `--timer-property=AccuracySec=1s`.

  La VM était bien revenue en arrière dans les deux cas ; c'est le message d'échec qui était trompeur.
