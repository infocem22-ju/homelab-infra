# homelab-infra

Infrastructure de lab personnelle, construite from scratch et maintenue activement.

Objectif : pratiquer l'administration Linux et l'automatisation d'infrastructure dans un environnement reproductible — provisioning de VMs, monitoring, CI/CD, déploiement de services.

**Stack :** Ansible · AWX · Proxmox VE · KVM · Podman · Zabbix · GitHub Actions · Ollama · Git

---

## Architecture

```
[Workstation principale]
  │
  ├─ KVM / libvirt
  │   └─ awx-vm  (Debian 12, k3s + AWX Operator)
  │       └─ Interface web AWX : orchestration Ansible
  │
  ├─ Proxmox VE (hyperviseur)
  │   ├─ lab-vm-1  192.168.122.101  (Debian 12, cloud-init)
  │   ├─ lab-vm-2  192.168.122.102  (Debian 12, cloud-init)
  │   └─ lab-crash-1                (VM de test incidents)
  │
  ├─ Podman (containers légers)
  │   ├─ demo-node-1  SSH localhost:2221
  │   └─ site Hugo    HTTP localhost:8080
  │
  ├─ Zabbix (monitoring)
  │   └─ inventory dynamique → lab-vm-1, lab-vm-2, lab-crash-1
  │
  └─ Ollama + Open WebUI (IA locale)
```

---

## Ce qui tourne (avril 2026)

- **AWX** : déployé sur VM KVM dédiée (Debian 12 + k3s + AWX Operator) — orchestration Ansible via interface web, gestion centralisée des credentials, journalisation des jobs
- **Proxmox VE** : templates Debian 12 cloud-init, provisioning via collection `community.proxmox`
- **Ansible** : playbooks idempotents, rôles, `group_vars`
- **Playbook master** `provision_and_bootstrap.yml` : chaînage complet Proxmox → `wait_for_connection` → bootstrap → déploiement Zabbix agent
- **Zabbix** : auto-register des agents, inventory dynamique avec filtre `groupids`, dashboards
- **Podman** : containers de test + site statique Hugo déployé via Ansible
- **CI/CD GitHub Actions** : runner self-hosted, workflow déclenché sur push `ansible/`

---

## Structure du repo

```
homelab-infra/
├── ansible.cfg
├── requirements.yml            # collections Ansible (community.zabbix, community.proxmox)
├── ansible/
│   ├── inventory/
│   │   ├── lab_vms_static.yml          # inventaire statique KVM/Proxmox
│   │   └── zabbix_inventory.yml        # inventaire dynamique Zabbix (versionné, lu par AWX)
│   ├── group_vars/
│   ├── playbooks/
│   │   └── provision_and_bootstrap.yml
│   └── roles/
├── bootstrap/
│   ├── lab.sh                  # gestion containers Podman
│   └── vm.sh                   # legacy KVM
├── homelab-site/               # site Hugo
└── Notes.md
```

---

## Prérequis

### Ansible (local)

```bash
pip install ansible
ansible-galaxy collection install -r requirements.yml
```

### Inventory dynamique Zabbix

`ansible/inventory/zabbix_inventory.yml` est prêt à l'emploi (identifiants par défaut de Zabbix, `server_url` à adapter).

### Containers Podman

```bash
./bootstrap/lab.sh up 2     # créer les nodes
./bootstrap/lab.sh status
./bootstrap/lab.sh down
```

---

## Lancer le provisioning complet

```bash
# Provisionner les VMs + bootstrap + Zabbix agent
ansible-playbook ansible/playbooks/provision_and_bootstrap.yml

# Tester la connectivité
ansible -i ansible/inventory/zabbix_inventory.yml lab_vms -m ping

# Déployer le site Hugo
ansible-playbook ansible/playbooks/lab_site.yml
```

---

## AWX

AWX est déployé sur une VM KVM dédiée (Debian 12 + k3s + AWX Operator).

Credentials configurés :
- **ssh-homelab** : clé SSH (user `ansible`) pour accès aux VMs lab
- **homelab-token** : token GitHub pour sync du repo (Source Control)
- **zabbix-inventory-creds** : credential type custom pour l'inventaire dynamique

Inventaires :
- `homelab` : basé sur `lab_vms_static.yml` (groupe `lab_vms_static`)
- `homelab-zabbix` : inventaire dynamique via plugin `community.zabbix.zabbix_inventory` (groupe `lab_vms`, filtré sur le groupe Zabbix "Lab VMs")

> **Note** : le plugin `community.zabbix.zabbix_inventory` ne résout pas les variables d'environnement injectées par AWX (bug connu [#713](https://github.com/ansible-collections/community.zabbix/issues/713)). Le fichier d'inventaire est donc versionné avec les identifiants en clair : ce sont les identifiants par défaut (`Admin`/`zabbix`) d'un Zabbix de lab non exposé, et AWX doit pouvoir lire le fichier depuis le Project Git.

Job Templates :
- **lab-vms-bootstrap** : `ansible/playbooks/bootstrap_lab_vms.yml` sur l'inventaire `homelab-zabbix` — installe/configure zabbix-agent2
- **lab-vms-shutdown** : `ansible/playbooks/shutdown_lab_vms.yml` sur l'inventaire `homelab` — arrêt propre des VMs

Définis de façon idempotente via `ansible/awx/job_templates.yml` (collection `awx.awx`, auth par token API — voir `ansible/awx/.env`, gitignoré).

---

## CI/CD

Runner self-hosted GitHub Actions. Déclenché sur push dans `ansible/` ou manuellement.

Pipeline :
1. Clone du repo
2. Génération du site Hugo
3. Vérification containers Podman
4. Exécution playbook Ansible

---

## Roadmap

- [x] Job Templates AWX pour les playbooks principaux (bootstrap, shutdown) — 27/08/2026
- [ ] CI/CD via AWX (remplacement GitHub Actions)
- [ ] Diagnostic système via Zabbix : méthodologie incident
- [ ] ~~Stabilisation RAG Ollama~~ — abandonné, la partie IA est déplacée vers un projet perso non publié
