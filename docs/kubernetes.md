# Kubernetes et Grafana — rapport de travail

Journal tenu au fil de l'eau pendant l'apprentissage de Kubernetes dans le lab, en mode cours : questions, expériences, puis conclusions.
Démarré le 03/11/2026.

## Objectif

Les compétences qui manquent le plus face aux offres DevOps : orchestrer des conteneurs avec Kubernetes, et superviser un cluster avec Prometheus et Grafana. Terraform s'ajoute en chemin, pour créer les VMs du cluster en code.

Plan :

0. Concepts, en partant de Docker Compose
1. VM créée par Terraform, puis k3s sur un seul nœud, installé par Ansible
2. Une vraie application : ConfigMap, Secret, Ingress (Traefik), sondes de santé
3. Deux nœuds, puis pannes provoquées
4. Helm, puis kube-prometheus-stack (Prometheus et Grafana)
5. GitOps avec Argo CD
6. Sécurité : RBAC, NetworkPolicies, secrets

## État de départ (03/11/2026)

| Composant | Adresse | État |
|---|---|---|
| Poste (hôte KVM) | `192.168.122.1` | 31 Gio de RAM, 16 threads (Ryzen 7 5700X3D) |
| Zabbix (Docker Compose) | hôte | arrêté depuis le 16/10, relancé pour l'étape 0 |
| AWX (VM KVM `Awx`) | `192.168.122.148` | éteint — 6 Gio, 4 vCPU |
| Proxmox VE (VM KVM `proxmox-lab`) | `192.168.122.106` | éteint, reste éteint pendant les sessions k8s |

## Journal

### 03/11/2026

**Étape 0 — ce que Kubernetes apporte, à partir du Compose de Zabbix**

- Plantage simulé de `zabbix-server` par `sudo kill -9` sur son PID côté hôte, sans passer par Docker. Suivi avec `docker events --filter container=zabbix-server` :
  - `die` avec `exitCode=137` (128 + 9, SIGKILL), puis `start` 110 ms plus tard
  - `RestartCount` à 1, les deux autres conteneurs intacts
  - c'est `dockerd` qui relance, à cause de `restart: unless-stopped`. Ma première réponse était « il faut relancer à la main », et c'est l'expérience qui a tranché.
- Pourquoi les conteneurs étaient restés en `Exited (0)` depuis deux semaines, malgré plusieurs redémarrages du poste et `docker.service` activé au boot : le code 0 indique un arrêt propre et demandé. `unless-stopped` mémorise cet arrêt et ne relance pas.
- Données : `zabbix_pgdata` est un volume nommé (`/var/lib/docker/volumes/homelab-zabbix_zabbix_pgdata/_data`). Il survit à la suppression du conteneur et à un `docker compose down`, mais pas à un `down -v` ni à la perte du disque. La sauvegarde `zabbix_backup_2026-01-22.sql.gz` est sur le même disque : elle protège d'une erreur de manipulation, pas d'une panne matérielle (règle 3-2-1).
- Conclusion : avec Compose, si la machine tombe, il n'y a plus personne pour relancer, puisque le seul surveillant, `dockerd`, tourne dessus. Kubernetes généralise la boucle de réconciliation (état voulu comparé en permanence à l'état réel) à plusieurs machines. Sur un seul nœud, on gagne les sondes de santé (un processus figé est relancé, pas seulement un processus mort), les mises à jour progressives et des manifestes réutilisables, mais pas encore la tolérance à la panne d'une machine.

**Étape 1 — VM `k3s-vm-1` créée par Terraform**

- Terraform 1.15.9 installé (`pacman -S terraform`).
- Prise en main sur un cas sans risque, le provider `hashicorp/local` (un fichier `hello.txt`) :
  - cycle `init` → `plan` → `apply` → `destroy`
  - un `plan` ne crée rien : il compare et annonce
  - dérive : après une modification à la main, le `plan` propose de remettre le contenu déclaré. L'`id` de la ressource est le SHA-1 du contenu (`printf 'bonjour\n' | sha1sum` donne bien `e7bc5463…`), c'est par lui que Terraform voit l'écart au moment du *refresh*.
- Code dans `terraform/k3s/` (`main.tf`, `variables.tf`), provider `dmacvicar/libvirt` 0.9.9 sur `qemu:///system`. Correspondance avec `bootstrap/vm.sh` :

  | `vm.sh` | Terraform |
  |---|---|
  | variables d'environnement | blocs `variable` |
  | `qemu-img create -b` | `libvirt_volume` avec `backing_store` |
  | `cloud-localds` | `libvirt_cloudinit_disk`, déposé dans le pool par un `libvirt_volume` |
  | `virt-install --import` | `libvirt_domain` |

- `plan` : 4 ressources. L'ordre de création est déduit des références du code : le disque et l'ISO cloud-init d'abord, en parallèle, puis le volume de l'ISO, puis la VM, et enfin la lecture de l'IP.
- Après les corrections (voir Problèmes rencontrés) : la VM démarre, avec un bail DHCP `192.168.122.171`. Le `plan` ne propose plus aucun changement d'infrastructure.
- Vérifié dans la VM : 2 vCPU, 3,8 Gio de RAM (le noyau garde sa part), `/` de 29G (partition EFI et métadonnées ext4 en moins).
- Vérifié sur l'hôte (`qemu-img info -U`) : taille virtuelle de 30 Gio, mais 28,4 Mio réellement occupés. Le disque ne contient que ce que la VM a écrit depuis son premier démarrage (cloud-init, agrandissement de la partition, journaux). Debian reste dans l'image de base, lue en copie sur écriture : un deuxième nœud sur la même base ne coûtera lui aussi que quelques dizaines de Mio au départ.

### 04/11/2026

**Étape 1, suite — IP stable pour `k3s-vm-1`**

- Choix d'une réservation DHCP, avec une MAC fixée dans le code (variables `mac` = `52:54:00:6b:33:01`, préfixe QEMU/KVM, et `ip` = `192.168.122.131`), plutôt que d'une IP fixe dans la VM. En vérifiant les adresses déjà prises, constat que la plage DHCP du réseau `default` couvre tout le sous-réseau, IP fixes comprises (voir Points ouverts).
- Le réseau `default` n'est pas géré par Terraform. La réservation y est ajoutée par `virsh net-update … add ip-dhcp-host`, lancée par un `terraform_data` avec deux `local-exec`, l'un à la création et l'autre à la destruction (`when = destroy`).
  - Le provisioner de destruction lit `self.input`, c'est-à-dire la valeur enregistrée dans le state, et non `var.mac`/`var.ip`. Essai : avec `var.mac`, `terraform validate` refuse (`Invalid reference from destroy provisioner`). Ma réponse était « les variables ne sont pas encore connues ». En réalité, elles sont connues, mais peut-être plus à jour : si `ip` passe de `.131` à `.132`, il faut supprimer la réservation `.131`, que seul le state connaît encore. Pour défaire, on lit ce qui a été fait, pas ce qu'on voudrait maintenant.
  - `depends_on` sur la VM : elle ne fait référence à la réservation nulle part, donc sans lui Terraform créerait les deux en parallèle. La réservation gagnerait presque toujours la course, puisque `virsh` répond en une fraction de seconde contre plusieurs secondes de démarrage pour la VM. C'est justement le genre de bug qui passe les tests et tombe un jour.
- Après un redémarrage du poste, le `plan` voulait recréer l'ISO cloud-init et remplacer son volume, alors que je n'avais touché à rien : le provider génère l'ISO dans `/tmp`, un `tmpfs` vidé à chaque démarrage. Sans danger pour la VM, puisque cloud-init ne rejoue pas pour un `instance-id` déjà vu, mais c'est du bruit qui masquerait une vraie dérive, et un contrôle en CI par `plan -detailed-exitcode` échouerait à chaque redémarrage. `lifecycle { ignore_changes = [create] }` sur `libvirt_volume.cidata` supprime le remplacement du volume. Il reste la recréation du fichier local (voir Points ouverts).
- Vérifié : bail `192.168.122.131` 11 s après le démarrage, SSH avec la clé Ansible, `terraform plan -detailed-exitcode` qui renvoie `0`.

### Prochaine session

- Étape 1, suite : installer k3s sur `k3s-vm-1` par Ansible.
- Dans l'inventaire, gérer la clé d'hôte SSH, qui change à chaque recréation de la VM alors que l'IP reste la même. Pistes : `accept-new` limité au groupe k3s avec `ssh-keygen -R` au remplacement, ou une clé d'hôte générée par Terraform, mais elle finirait dans le state.

## Décisions

- **03/11/2026 — Cluster dans des VMs du KVM de l'hôte, pas dans Proxmox.** Proxmox, en virtualisation imbriquée, a planté deux fois sous la pression mémoire de l'hôte (09/10 et 13/10, voir `docs/pare-feu.md`). Proxmox et le lab pare-feu restent éteints pendant les sessions k8s. Inconvénient accepté : ces VMs ne sont pas visibles dans l'interface de Proxmox.
- **03/11/2026 — Terraform dès la création de la première VM, au lieu de `bootstrap/vm.sh`.** Terraform est demandé dans les offres et absent du lab jusqu'ici. Une seule VM, c'est le moment le moins coûteux pour l'apprendre, et le deuxième nœud de l'étape 3 ne demandera qu'un `count`. Partage des rôles : Terraform crée les VMs, Ansible les configure.
- **03/11/2026 — Image de base et réseau `default` cités, pas gérés par Terraform.** `debian-12-generic-amd64.qcow2` sert aussi à d'autres VMs : si Terraform la gérait, un `terraform destroy` la supprimerait.
- **03/11/2026 — Dimensionnement : 2 vCPU, 4 Gio, 30 Gio.** Partir petit, sauf là où c'est pénible à agrandir. Les vCPU et la RAM s'agrandissent facilement, à l'arrêt de la VM. Le disque se redimensionne mal, mais ne coûte rien grâce au qcow2 alloué à la demande. 2 Gio de RAM, le minimum de k3s, auraient fait passer l'étape 2 à déboguer des manques de mémoire. On montera à 6 ou 7 Gio pour l'étape 4.
- **03/11/2026 — State Terraform local et hors de Git.** Il peut contenir des secrets, et le dépôt est public. En équipe, il irait dans un backend distant avec un verrou (S3, Terraform Cloud). Le `.terraform.lock.hcl` est versionné, pour figer la version du provider.

- **04/11/2026 — IP de `k3s-vm-1` réservée dans le DHCP du réseau `default`, avec une MAC fixée dans le code.** L'IP reste gérée au même endroit que celle d'OPNsense (`.119`), et la VM n'a rien de particulier à configurer. Comme le réseau `default` n'est pas géré par Terraform, la réservation passe par un `terraform_data` et `virsh net-update`. HashiCorp présente les provisioners comme un dernier recours : Terraform ne voit pas ce que fait la commande, et ne détecterait pas une réservation supprimée à la main. Accepté, faute de mieux sans gérer tout le réseau.

## Points ouverts

- ~~IP de `k3s-vm-1` attribuée par DHCP, donc pas garantie dans la durée.~~ Réglé le 04/11 par une réservation (voir Décisions).
- **La plage DHCP du réseau `default` (`.2`–`.254`) couvre tout le sous-réseau.** Les IP fixes (`.101`, `.102` des VMs Proxmox, `.148` d'AWX…) sont dedans : le DHCP pourrait en donner une à une autre machine. Seuls OPNsense et `k3s-vm-1` ont une réservation. Piste : réduire la plage, par exemple à `.200`–`.254`, et réserver le reste aux IP fixes.
- **Après chaque redémarrage du poste, le `plan` veut recréer `libvirt_cloudinit_disk.init`.** C'est l'ISO cloud-init générée dans `/tmp` (`tmpfs`), donc un fichier local sans effet sur la VM, mais le `plan` n'est plus vide (code retour `2`). `ignore_changes` a seulement évité le remplacement du volume dans libvirt.
- **Changer `mac` sur un disque existant recasse le réseau de la VM** (voir Problèmes rencontrés du 04/11). Il faut alors remplacer aussi le disque.

## Problèmes rencontrés

- **`Domain Not Found` sur le data source de l'IP (03/11/2026).** `libvirt_domain.k3s.id` vaut `1` en 0.9.9 : c'est le numéro d'exécution de la VM (colonne `ID` de `virsh list`), pas son UUID, contrairement à ce que laisse entendre la doc. Corrigé avec `libvirt_domain.k3s.name`, qui reste stable d'un démarrage à l'autre. Les quatre ressources avaient été créées : seule la lecture de l'IP avait échoué, et l'`apply` suivant a annoncé `0 to add`.
- **VM bloquée à 1,8 s de démarrage, sans aucun bail DHCP (03/11/2026).** Console (`virsh screenshot`) : `xhci_hcd ... -110`, puis plus rien. `domstats` : environ 1,5 cœur consommé en continu, 0 octet écrit sur le disque. Le XML de la VM n'avait ni `<features>` (ACPI, APIC), ni CPU autre que `qemu64`. `virt-install` les ajoute par défaut, le provider n'ajoute rien qui ne soit pas écrit. Ajout de `cpu = { mode = "host-passthrough" }` : les erreurs `xhci` disparaissent, mais le blocage reste. Ajout de `features = { acpi = true, apic = {} }` : le noyau va plus loin.
  - Piège rencontré au passage : `cpu.features` (liste d'instructions du processeur) n'est pas `features` (fonctions de la machine virtuelle, au niveau de la VM).
- **Kernel panic à 2,4 s : `Attempted to kill init! exitcode=0x00000200` (03/11/2026).** Les images Debian *cloud* démarrent avec `console=ttyS0`, et la VM n'avait pas de port série. Comparaison avec la VM AWX, qui démarre : elle a un port série. Corrigé en ajoutant `serials` et `consoles` de type série, une syntaxe que la doc n'indique pas : je l'ai trouvée dans le ticket n° 1332 du provider. Démarrage complet ensuite, et le port série donne au passage `virsh console k3s-vm-1`. À retenir : un outil déclaratif de bas niveau ne fait rien d'implicite. Trois réglages que `virt-install` posait sans le dire ont dû être écrits.
- **`qemu-img info` refusé sur le disque d'une VM en marche (03/11/2026).** `Failed to get shared "write" lock` : QEMU verrouille le disque pour éviter qu'un autre programme l'écrive en même temps. `-U` (`--force-share`) permet une lecture seule. Ne jamais l'utiliser pour une écriture (`resize`, `convert`) sur une VM allumée.
- **Pas d'IP après l'ajout de la MAC, réservation pourtant en place (04/11/2026).** L'`apply` a ajouté la MAC et démarré la VM. Le démarrage était complet (8 s de CPU, 7 Mo écrits), mais `domstats` indiquait `tx.pkts=0` : aucune requête DHCP envoyée, donc la panne était dans la VM, pas dans `dnsmasq`. Au premier démarrage, cloud-init avait écrit une configuration réseau qui reconnaît la carte par son ancienne MAC, aléatoire. Il ne la réécrit pas, puisque l'`instance-id` n'a pas changé. Remplacer `libvirt_domain.k3s` seul n'aurait pas suffi, la configuration étant sur le disque : `terraform apply -replace=libvirt_volume.disk -replace=libvirt_domain.k3s`, sans perte puisque rien n'était encore installé. Avec la MAC fixée dans le code, un futur `-replace` ne reproduira pas le problème.
- **`-replace` sans effet (04/11/2026).** La VM gardait son UUID et sa durée de fonctionnement. La confirmation n'avait pas reçu `yes` : Terraform n'accepte que ce mot en entier, et annule sur toute autre réponse. C'est voulu, pour une commande qui détruit.
- **`ip` affiche « pas encore de bail DHCP » juste après l'`apply` (04/11/2026).** Le data source lit les baux dès que la VM démarre, avant sa requête DHCP. Le bail est arrivé quelques secondes plus tard : `terraform apply -refresh-only` met la sortie à jour.
