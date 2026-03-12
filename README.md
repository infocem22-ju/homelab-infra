# Homelab Infra

Infrastructure de laboratoire pour expérimenter Ansible et l'automatisation système.

Objectifs :

- apprendre Ansible
- tester déploiement de services
- expérimenter monitoring (Zabbix)
- automatiser infrastructure locale

Le lab utilise des containers Podman pour simuler plusieurs machines.

---

# Architecture

Le lab crée des nodes Debian accessibles via SSH :

demo-node-1 → localhost:2221  
demo-node-2 → localhost:2222

Un utilisateur `ansible` est configuré automatiquement avec une clé SSH.

---

# Lancer le lab

Créer les nodes :

./bootstrap/lab.sh up 2

Voir le statut :

./bootstrap/lab.sh status

Supprimer le lab :

./bootstrap/lab.sh down

---

# Tester Ansible

Test simple :

ansible demo_nodes -m ping

Playbook test :

ansible-playbook ansible/playbooks/playbook-trace.yml

---

# Structure du projet

homelab-infra
├── ansible.cfg
├── ansible
│ ├── inventory
│ ├── group_vars
│ ├── playbooks
│ └── roles
├── bootstrap
│ └── lab.sh
└── Notes.md


---
## Topologie actuelle du homelab

```text
[Workstation principale]
  ├─ Ansible
  │   ├─ inventory
  │   ├─ group_vars
  │   ├─ playbooks
  │   └─ roles
  │
  ├─ Podman / Lab containers
  │   ├─ demo-node-1 (SSH localhost:2221)
  │   └─ demo-node-2 (SSH localhost:2222)
  │
  ├─ Monitoring
  │   └─ Zabbix
  │
  └─ IA locale
      ├─ Ollama
      └─ Open WebUI

## Schéma du lab

```mermaid
flowchart TD
    A[Workstation principale] --> B[Ansible]
    A --> C[Podman / Lab containers]
    A --> D[Monitoring Zabbix]
    A --> E[IA locale : Ollama / Open WebUI]

    C --> F[demo-node-1<br/>SSH localhost:2221]
    C --> G[demo-node-2<br/>SSH localhost:2222]

    C -. évolution .-> H[VM]
    H -. plus tard .-> I[Kubernetes]

# Roadmap

- structurer rôles Ansible
- déployer Zabbix agent
- ajouter nodes VM
- explorer inventory dynamique