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

### Prochaine session

- Comparaison avec la version Debian + nftables

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

## Points ouverts

- **Accès d'AWX aux VMs du lab une fois derrière le pare-feu.** Le Job Template `lab-site` vise `lab-vm-1`/`lab-vm-2` en `192.168.122.101`/`.102` (`ansible/inventory/lab_vms_static.yml`), et `proxmox_provision_vms.yml` fixe leur IP et la passerelle `192.168.122.1` par cloud-init. En passant ces VMs sur `vmbr1`, AWX (`192.168.122.148`) ne les voit plus, et la CI/CD casse. Pistes : une route vers `10.10.10.0/24` via `192.168.122.119` sur AWX (et sur l'hôte) plus une règle WAN SSH depuis AWX, ou AWX lui-même derrière le pare-feu. À trancher avant de déplacer `lab-vm-1`/`lab-vm-2`. **Tranché le 29/09/2026 : route (voir Décisions).**

## Problèmes rencontrés

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
