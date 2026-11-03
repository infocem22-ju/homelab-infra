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

### Prochaine session

- Étape 1, suite : installer k3s sur `k3s-vm-1` par Ansible.
- Avant cela, rendre l'IP de la VM stable pour l'inventaire (voir Points ouverts).

## Décisions

- **03/11/2026 — Cluster dans des VMs du KVM de l'hôte, pas dans Proxmox.** Proxmox, en virtualisation imbriquée, a planté deux fois sous la pression mémoire de l'hôte (09/10 et 13/10, voir `docs/pare-feu.md`). Proxmox et le lab pare-feu restent éteints pendant les sessions k8s. Inconvénient accepté : ces VMs ne sont pas visibles dans l'interface de Proxmox.
- **03/11/2026 — Terraform dès la création de la première VM, au lieu de `bootstrap/vm.sh`.** Terraform est demandé dans les offres et absent du lab jusqu'ici. Une seule VM, c'est le moment le moins coûteux pour l'apprendre, et le deuxième nœud de l'étape 3 ne demandera qu'un `count`. Partage des rôles : Terraform crée les VMs, Ansible les configure.
- **03/11/2026 — Image de base et réseau `default` cités, pas gérés par Terraform.** `debian-12-generic-amd64.qcow2` sert aussi à d'autres VMs : si Terraform la gérait, un `terraform destroy` la supprimerait.
- **03/11/2026 — Dimensionnement : 2 vCPU, 4 Gio, 30 Gio.** Partir petit, sauf là où c'est pénible à agrandir. Les vCPU et la RAM s'agrandissent facilement, à l'arrêt de la VM. Le disque se redimensionne mal, mais ne coûte rien grâce au qcow2 alloué à la demande. 2 Gio de RAM, le minimum de k3s, auraient fait passer l'étape 2 à déboguer des manques de mémoire. On montera à 6 ou 7 Gio pour l'étape 4.
- **03/11/2026 — State Terraform local et hors de Git.** Il peut contenir des secrets, et le dépôt est public. En équipe, il irait dans un backend distant avec un verrou (S3, Terraform Cloud). Le `.terraform.lock.hcl` est versionné, pour figer la version du provider.

## Points ouverts

- **IP de `k3s-vm-1` attribuée par DHCP (`192.168.122.171`), donc pas garantie dans la durée.** Ansible a besoin d'une adresse stable. Pistes : réservation DHCP dans le réseau `default` (comme OPNsense en `.119`), ou IP fixe par cloud-init (`network_config`).

## Problèmes rencontrés

- **`Domain Not Found` sur le data source de l'IP (03/11/2026).** `libvirt_domain.k3s.id` vaut `1` en 0.9.9 : c'est le numéro d'exécution de la VM (colonne `ID` de `virsh list`), pas son UUID, contrairement à ce que laisse entendre la doc. Corrigé avec `libvirt_domain.k3s.name`, qui reste stable d'un démarrage à l'autre. Les quatre ressources avaient été créées : seule la lecture de l'IP avait échoué, et l'`apply` suivant a annoncé `0 to add`.
- **VM bloquée à 1,8 s de démarrage, sans aucun bail DHCP (03/11/2026).** Console (`virsh screenshot`) : `xhci_hcd ... -110`, puis plus rien. `domstats` : environ 1,5 cœur consommé en continu, 0 octet écrit sur le disque. Le XML de la VM n'avait ni `<features>` (ACPI, APIC), ni CPU autre que `qemu64`. `virt-install` les ajoute par défaut, le provider n'ajoute rien qui ne soit pas écrit. Ajout de `cpu = { mode = "host-passthrough" }` : les erreurs `xhci` disparaissent, mais le blocage reste. Ajout de `features = { acpi = true, apic = {} }` : le noyau va plus loin.
  - Piège rencontré au passage : `cpu.features` (liste d'instructions du processeur) n'est pas `features` (fonctions de la machine virtuelle, au niveau de la VM).
- **Kernel panic à 2,4 s : `Attempted to kill init! exitcode=0x00000200` (03/11/2026).** Les images Debian *cloud* démarrent avec `console=ttyS0`, et la VM n'avait pas de port série. Comparaison avec la VM AWX, qui démarre : elle a un port série. Corrigé en ajoutant `serials` et `consoles` de type série, une syntaxe que la doc n'indique pas : je l'ai trouvée dans le ticket n° 1332 du provider. Démarrage complet ensuite, et le port série donne au passage `virsh console k3s-vm-1`. À retenir : un outil déclaratif de bas niveau ne fait rien d'implicite. Trois réglages que `virt-install` posait sans le dire ont dû être écrits.
- **`qemu-img info` refusé sur le disque d'une VM en marche (03/11/2026).** `Failed to get shared "write" lock` : QEMU verrouille le disque pour éviter qu'un autre programme l'écrive en même temps. `-U` (`--force-share`) permet une lecture seule. Ne jamais l'utiliser pour une écriture (`resize`, `convert`) sur une VM allumée.
