# VM pare-feu — rapport de travail

Journal tenu au fil de l'eau pendant la mise en place d'un pare-feu dans le lab.
Démarré le 28/09/2026.

## Objectif

Placer les VMs du lab derrière un pare-feu, comme sur un réseau de PME :

- WAN sur le réseau actuel `192.168.122.0/24` (réseau `default` de libvirt)
- LAN sur un bridge interne dédié à Proxmox (`vmbr1`)
- Filtrage, NAT sortant, DHCP/DNS côté LAN
- Supervision du pare-feu dans Zabbix (SNMP)

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

### Prochaine session

- Rôle Ansible `host_firewall` (nftables) pour `lab-vm-2` : entrée bloquée par défaut, SSH depuis AWX et l'hôte, HTTP pour nginx. Prévoir un retour arrière automatique pour ne pas couper AWX.
- Versionner la source d'inventaire `homelab-zabbix` (`awx.awx.inventory_source`, `update_on_launch: true`) dans `ansible/awx/job_templates.yml`
- `lab-crash-1` : réservation DHCP dans OPNsense et IP à jour dans Zabbix (encore `192.168.122.50`)
- Clavier de la console d'OPNsense à rendre permanent (pour l'instant, `kbdcontrol -l fr` à chaque démarrage)

## Décisions

- **28/09/2026 — OPNsense en premier.** C'est le moyen le plus rapide d'avoir un pare-feu qui marche, et il servira de référence pour la version nftables.
- **28/09/2026 — Mise en place à la main dans l'interface web de Proxmox.** Pas de token API sur le poste pour l'instant. Les étapes sont notées ici pour pouvoir les passer ensuite en Ansible.
- **28/09/2026 — LAN en `10.10.10.0/24`** au lieu du `192.168.1.0/24` par défaut, trop courant sur les box et donc exposé aux collisions. Plan d'adressage :
  - `10.10.10.1` : OPNsense, passerelle et DNS du LAN
  - `.10`–`.199` : adresses fixes (les VMs du lab gardent leur numéro, `lab-vm-1` → `10.10.10.101`)
  - `.200`–`.249` : plage DHCP
- **29/09/2026 — AWX reste sur le WAN et atteint le LAN par une route via OPNsense.** Route `10.10.10.0/24 via 192.168.122.119` sur AWX et sur l'hôte, règle WAN SSH limitée à la source AWX. C'est le schéma d'un réseau d'admin qui accède au LAN à travers un pare-feu filtrant. Mettre AWX derrière le pare-feu aurait obligé à router l'hôte et le runner GitHub vers AWX.
- **29/09/2026 — `lab-vm-2` reste devant le pare-feu, protégée par Ansible.** Deux modèles côte à côte : `lab-vm-1` derrière OPNsense (sécurité périmétrique, règles dans l'appliance) et `lab-vm-2` sur le WAN avec un pare-feu local nftables déployé par AWX (sécurité au niveau de l'hôte, règles versionnées). Le rôle servira aussi pour la version Debian + nftables. Limites assumées : le « WAN » est le réseau NAT de libvirt, pas Internet (menace simulée : une autre machine compromise sur `192.168.122.0/24`) ; en PME, un serveur exposé irait plutôt en DMZ (troisième interface d'OPNsense, `vmbr2`), piste pour plus tard.

## Points ouverts

- **Accès d'AWX aux VMs du lab une fois derrière le pare-feu.** Le Job Template `lab-site` vise `lab-vm-1`/`lab-vm-2` en `192.168.122.101`/`.102` (`ansible/inventory/lab_vms_static.yml`), et `proxmox_provision_vms.yml` fixe leur IP et la passerelle `192.168.122.1` par cloud-init. En passant ces VMs sur `vmbr1`, AWX (`192.168.122.148`) ne les voit plus, et la CI/CD casse. Pistes : une route vers `10.10.10.0/24` via `192.168.122.119` sur AWX (et sur l'hôte) plus une règle WAN SSH depuis AWX, ou AWX lui-même derrière le pare-feu. À trancher avant de déplacer `lab-vm-1`/`lab-vm-2`. **Tranché le 29/09/2026 : route (voir Décisions).**

## Problèmes rencontrés

- **Clavier repassé en QWERTY après l'installation.** Le clavier choisi dans l'installeur ne vaut que pour l'installeur. Solution temporaire dans le shell : `kbdcontrol -l fr` (en QWERTY, le `-` est sur la touche `)`). Solution durable : System → Settings → Administration, rubrique Console.

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
