# homelab-infra

Infrastructure de lab personnelle, construite from scratch et maintenue activement.

Objectif : pratiquer l'administration Linux et l'automatisation d'infrastructure dans un environnement reproductible — provisioning de VMs, monitoring, CI/CD, déploiement de services.

**Stack :** Ansible · AWX · Proxmox VE · KVM · Podman · Docker Compose · Zabbix · GitHub Actions · Git

---

## Architecture

```
  git push (ansible/**)
        │
        ▼
  GitHub Actions ──► runner self-hosted (workstation)
                          │  API REST AWX (token OAuth)
                          ▼
[Workstation principale]
  │
  ├─ KVM / libvirt  (réseau 192.168.122.0/24)
  │   ├─ Awx  192.168.122.148  (Debian 12, k3s + AWX Operator, UI :30080)
  │   │   └─ Job Templates exécutés dans l'EE homelab-ee (ghcr.io)
  │   │
  │   └─ proxmox-lab  (Proxmox VE, virtualisation imbriquée)
  │       ├─ lab-vm-1     192.168.122.101  (Debian 12, cloud-init)
  │       ├─ lab-vm-2     192.168.122.102  (Debian 12, cloud-init)
  │       └─ lab-crash-1  192.168.122.50   (VM de test incidents)
  │
  ├─ Docker Compose : Zabbix 7.4 (server + PostgreSQL, web :8081)
  │   └─ supervision + inventaire dynamique → groupe lab_vms
  │
  └─ Podman (containers légers)
      ├─ demo-node-1  SSH localhost:2221
      └─ site Hugo    HTTP localhost:8080
```

---

## Ce qui tourne (septembre 2026)

- **AWX** : déployé sur VM KVM dédiée (Debian 12 + k3s + AWX Operator) — orchestration Ansible via interface web, gestion centralisée des credentials, journalisation des jobs ; Job Templates et Execution Environment définis en code
- **Proxmox VE** : templates Debian 12 cloud-init, provisioning via collection `community.proxmox`
- **Ansible** : playbooks idempotents, rôles, `group_vars`
- **Playbook master** `provision_and_bootstrap.yml` : chaînage complet Proxmox → `wait_for_connection` → bootstrap → déploiement Zabbix agent
- **Zabbix** : auto-register des agents, inventory dynamique avec filtre `groupids`, dashboards
- **Podman** : containers de test + site statique Hugo déployé via Ansible
- **CI/CD** : push sur `ansible/` → GitHub Actions (runner self-hosted) → Job Template AWX `lab-site`

---

## Structure du repo

```
homelab-infra/
├── ansible.cfg
├── requirements.yml            # collections Ansible (community.zabbix, community.proxmox)
├── .github/workflows/
│   └── ansible.yml             # déclenche le Job Template AWX lab-site
├── ansible/
│   ├── awx/
│   │   └── job_templates.yml           # config AWX en code (awx.awx) : JT, EE, credential type
│   ├── ee/
│   │   └── execution-environment.yml   # EE custom homelab-ee (ansible-builder)
│   ├── inventory/
│   │   ├── lab_vms_static.yml          # inventaire statique KVM/Proxmox
│   │   ├── zabbix_inventory.yml        # inventaire dynamique Zabbix (versionné, lu par AWX)
│   │   └── group_vars/
│   ├── playbooks/
│   │   ├── lab_site.yml                # pipeline CI/CD (trace, nginx, zabbix-agent2)
│   │   ├── proxmox_provision_vms.yml
│   │   └── provision_and_bootstrap.yml
│   └── roles/                          # nginx_demo, zabbix_agent2
├── zabbix/docker-compose.yml   # Zabbix 7.4 + PostgreSQL
├── ollama/                     # IA locale — déprécié, plus développé
├── procedures/                 # procédures d'incident (disque plein, nginx down)
├── tools/homelab-control.sh    # menu de démarrage/arrêt de la stack
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
- **proxmox-api** : token API Proxmox (credential type custom « Proxmox API », injecté en variables d'env `PROXMOX_*`)
- **homelab-token** : token GitHub pour sync du repo (Source Control)
- **zabbix-inventory-creds** : credential type custom pour l'inventaire dynamique

Inventaires :
- `homelab` : basé sur `lab_vms_static.yml` (groupe `lab_vms_static`)
- `homelab-zabbix` : inventaire dynamique via plugin `community.zabbix.zabbix_inventory` (groupe `lab_vms`, filtré sur le groupe Zabbix "Lab VMs")

> **Note** : le plugin `community.zabbix.zabbix_inventory` ne résout pas les variables d'environnement injectées par AWX (bug connu [#713](https://github.com/ansible-collections/community.zabbix/issues/713)). Le fichier d'inventaire est donc versionné avec les identifiants en clair : ce sont les identifiants par défaut (`Admin`/`zabbix`) d'un Zabbix de lab non exposé, et AWX doit pouvoir lire le fichier depuis le Project Git.

Job Templates :
- **lab-vms-provision** : `ansible/playbooks/proxmox_provision_vms.yml` sur l'inventaire `homelab` — clone/configure/démarre les VMs lab sur Proxmox (EE `homelab-ee`)
- **lab-vms-bootstrap** : `ansible/playbooks/bootstrap_lab_vms.yml` sur l'inventaire `homelab-zabbix` — installe/configure zabbix-agent2
- **lab-vms-shutdown** : `ansible/playbooks/shutdown_lab_vms.yml` sur l'inventaire `homelab` — arrêt propre des VMs
- **lab-site** : `ansible/playbooks/lab_site.yml` sur l'inventaire `homelab-zabbix` — pipeline de déploiement, déclenché par GitHub Actions

Execution Environment **homelab-ee** (`ansible/ee/execution-environment.yml`) : image `awx-ee` épinglée (ansible-core 2.18) + `proxmoxer` + collections du repo, publiée sur `ghcr.io/infocem22-ju/homelab-ee:1.0`.

Définis de façon idempotente via `ansible/awx/job_templates.yml` (collection `awx.awx`, auth par token API — voir `ansible/awx/.env`, gitignoré) :

```bash
set -a; . ansible/awx/.env; ansible-playbook ansible/awx/job_templates.yml
```

---

## CI/CD

Déclenché sur push dans `ansible/` ou manuellement (`workflow_dispatch`). Le runner self-hosted ne porte aucune logique : il appelle l'API AWX, qui exécute le playbook avec ses propres credentials et journalise le job.

Pipeline :
1. GitHub Actions lance le Job Template AWX `lab-site` (`POST /api/v2/job_templates/<id>/launch/`)
2. AWX synchronise le projet Git et exécute `lab_site.yml` sur les VMs lab : trace de connexion, nginx, zabbix-agent2
3. Le runner interroge le statut du job jusqu'à la fin ; en cas d'échec, les 50 dernières lignes du job AWX sont affichées dans le run GitHub

Secrets GitHub requis : `AWX_HOST` (`http://192.168.122.148:30080`) et `AWX_TOKEN` (token OAuth AWX dédié, scope write).

> Le runner est lancé à la main (`~/actions-runner/run.sh`) : tant qu'il n'est pas démarré, les runs restent en file d'attente.

---

## Roadmap

- [x] Job Templates AWX pour les playbooks principaux (bootstrap, shutdown) — 27/08/2026
- [x] CI/CD via AWX (GitHub Actions ne fait plus que déclencher le Job Template) — 25/09/2026
- [ ] Déploiement du site Hugo sur les VMs lab (build dans l'EE) au lieu de demo-node-1
- [ ] VM pare-feu (OPNsense vs Debian + nftables) devant les VMs lab
- [ ] Diagnostic système via Zabbix : méthodologie incident
- [ ] ~~Stabilisation RAG Ollama~~ — abandonné, la partie IA est déplacée vers un projet perso non publié
