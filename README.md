# homelab-infra

Infrastructure de lab personnelle, construite from scratch et maintenue activement.

Objectif : pratiquer l'administration Linux et l'automatisation d'infrastructure dans un environnement reproductible — provisioning de VMs, monitoring, CI/CD, déploiement de services.

**Stack :** Ansible · Proxmox VE · Podman · Zabbix · GitHub Actions · Ollama · Git

---

## Architecture

```
[Workstation principale]
  │
  ├─ Proxmox VE (hyperviseur)
  │   ├─ lab-vm-1  192.168.122.101  (Debian 12, cloud-init)
  │   └─ lab-vm-2  192.168.122.102  (Debian 12, cloud-init)
  │
  ├─ Podman (containers légers)
  │   ├─ demo-node-1  SSH localhost:2221
  │   ├─ demo-node-2  SSH localhost:2222
  │   └─ site Hugo    HTTP localhost:8080
  │
  ├─ Zabbix (monitoring)
  │   └─ inventory dynamique → lab-vm-1, lab-vm-2
  │
  └─ Ollama + Open WebUI (IA locale, en cours de stabilisation)
```

---

## Ce qui tourne (avril 2026)

- **Proxmox VE** : templates Debian 12 cloud-init, provisioning via collection `community.proxmox`
- **Ansible** : playbooks idempotents, rôles, `group_vars`, credentials chiffrés via Vault
- **Playbook master** `provision_and_bootstrap.yml` : chaînage complet Proxmox → `wait_for_connection` → bootstrap → déploiement Zabbix agent
- **Zabbix** : auto-register des agents, inventory dynamique avec filtre `groupids`, dashboards
- **Podman** : containers de test + site statique Hugo déployé via Ansible
- **CI/CD GitHub Actions** : runner self-hosted, workflow déclenché sur push `ansible/` — génération Hugo, vérification containers, exécution playbook

---

## Structure du repo

```
homelab-infra/
├── ansible.cfg
├── ansible/
│   ├── inventory/          # inventory statique + dynamique Zabbix
│   ├── group_vars/
│   ├── playbooks/
│   │   └── provision_and_bootstrap.yml   # playbook master
│   └── roles/
├── bootstrap/
│   ├── lab.sh              # gestion containers Podman
│   └── vm.sh               # legacy KVM (remplacé par Proxmox)
├── homelab-site/           # site Hugo déployé via Ansible
└── Notes.md                # journal de bord technique
```

---

## Prérequis

### Ansible

```bash
pip install ansible
ansible-galaxy collection install community.zabbix community.proxmox
```

### Inventory dynamique Zabbix

```bash
cp ansible/inventory/zabbix_inventory.yml.example ansible/inventory/zabbix_inventory.yml
# Renseigner les credentials (ou utiliser Ansible Vault)
```

### Containers Podman

```bash
./bootstrap/lab.sh up 2     # créer les nodes
./bootstrap/lab.sh status   # vérifier
./bootstrap/lab.sh down     # supprimer
```

---

## Lancer le provisioning complet

```bash
# Provisionner les VMs + bootstrap + Zabbix agent
ansible-playbook ansible/playbooks/provision_and_bootstrap.yml

# Tester la connectivité via inventory Zabbix
ansible -i ansible/inventory/zabbix_inventory.yml lab_vms -m ping

# Déployer le site Hugo
ansible-playbook ansible/playbooks/lab_site.yml
```

---

## CI/CD

Runner self-hosted GitHub Actions. Le workflow se déclenche sur push dans `ansible/` ou manuellement.

Pipeline :
1. Clone du repo
2. Génération du site Hugo
3. Vérification que les containers Podman sont actifs
4. Exécution du playbook Ansible

---

## Roadmap

- [ ] Diagnostic système via Zabbix : CPU, RAM, I/O — méthodologie incident
- [ ] Intégration `homelab-control.sh` pour contrôle Proxmox en ligne de commande
- [ ] Stabilisation RAG Ollama
- [ ] Kubernetes — après consolidation Proxmox
