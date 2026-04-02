# Homelab – Roadmap / Notes

## Projets actifs

### Ansible

- Structuration des rôles Ansible
- Mise en place d'un playbook de bootstrap des nodes
- Organisation des group_vars
- Stabilisation du lab containers

Objectif :

Comprendre le fonctionnement réel d'Ansible :
- inventaire
- rôles
- idempotence
- structuration d'infrastructure

---

### CI/CD

- Self-hosted runner GitHub Actions en place
- Workflow déclenché sur push dans `ansible/` ou manuellement

Ce que fait le pipeline :
- clone le repo
- génère le site Hugo
- vérifie que les containers Podman sont actifs
- lance le playbook Ansible

---

### Monitoring

- Mise en place d'un monitoring Zabbix propre
- Installation et test du rôle `zabbix_agent2`

Objectifs :

- Comprendre les métriques système
- Lire correctement CPU / RAM / I/O
- Apprendre à interpréter les graphes Zabbix

---

### Infrastructure du lab

- Stabiliser le script `lab.sh`
- ~~VM disponibles via `vm.sh` KVM~~ → **migré vers Proxmox**
- Préparer une architecture extensible (containers / VM / machines physiques)

Évolution actuelle :

Containers + **Proxmox** (VMs avec IPs fixes via cloud-init)

---

### IA locale

- Stabilisation du RAG Ollama
- Organisation du dossier `knowledge`
- Tests de modèles locaux

Objectif :

Comprendre l'intégration d'un LLM dans un environnement auto-hébergé.

---

### Documentation

- Documentation du lab
- Création d'un README propre
- Structuration des notes techniques

---

## En cours de montée en priorité

### Kubernetes

À explorer après consolidation de l'infra Proxmox.

Objectifs :

- comprendre l'orchestration de containers
- comprendre l'architecture d'un cluster
- comparer avec l'approche Ansible

---

## En pause / plus tard

- Mettre en place Semaphore pour orchestrer Ansible
- Apprendre les bases de Grafana
- Installer HashiCorp Vault
- Expérimenter NixOS

---

## Projets personnels

- Mettre en place un reverse DNS sur le Raspberry Pi

---

## Exploration / Culture technique

### Proxmox VE

Acquis :
- Architecture : hyperviseur type 1, KVM + LXC + interface web
- Différence Proxmox vs KVM/libvirt nu vs Kubernetes
- Concurrents : VMware vSphere (migration post-Broadcom), XCP-ng, Hyper-V
- Installation en VM nested sur libvirt
- Interface web : création VM, snapshots, backup, shell intégré
- Monitoring : zabbix-agent2 + template Proxmox VE by HTTP (API port 8006)
- Automatisation : collection `community.proxmox` (proxmox_kvm, proxmox_snap...)
- Template Debian 12 cloud-init opérationnel
- Provisioning VMs via Ansible avec IPs fixes stables

---

## Session 31 mars 2026

### Accompli

- Création template Proxmox (debian-12-genericcloud + cloud-init)
- Provisioning VMs via Ansible (community.proxmox) :
  - clone depuis template
  - IP fixe via cloud-init (lab-vm-1: 192.168.122.101, lab-vm-2: 192.168.122.102)
  - démarrage automatique
- Bootstrap VMs : déploiement zabbix-agent2 via systemd
- Inventory dynamique Zabbix opérationnel avec bonnes IPs
- Workflow complet : Ansible → Proxmox → Zabbix → inventory dynamique

---

## Session 1er avril 2026

### Accompli

- Groupe `Lab VMs` dans Zabbix confirmé opérationnel (auto-register)
- Filtre `groupids: ["27"]` ajouté dans `zabbix_inventory.yml` → inventory limité aux VMs du lab
- Playbook `test_zabbix_inventory.yml` validé : connectivité OK sur lab-vm-1 et lab-vm-2 via inventory Zabbix uniquement

## Session 2 avril 2026

### Accompli
- Nettoyage ansible/ : suppression fichiers .old, test_zabbix_inventory.yml
- Fusion group_vars/lab_vms.yml dans group_vars/lab_vms/vars.yml
- Confirmation que les deux inventories sont déjà fusionnés dans ansible.cfg
- Création playbook master provision_and_bootstrap.yml (chaînage proxmox_provision_vms + wait_for_connection + bootstrap_lab_vms)
- Investigation credentials Proxmox dans hostvars Zabbix → pas de vrai problème, variables chiffrées dans le vault, pas stockées dans Zabbix

### Prochaine session (mardi 7 avril)
- Diagnostic système sur les VMs : CPU, RAM, I/O via outils système + Zabbix
- Objectif : construire une méthodologie de diagnostic incident (serveur qui lag → trouver la cause)

### Vendredi 4 avril
- homelab-control.sh : intégrer le contrôle Proxmo
- RAG Ollama si le script est expédié rapidement
---

Le bouton de bureau sert au contrôle rapide et à la visibilité immédiate.
Le monitoring détaillé reste le rôle de Zabbix.