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

# Roadmap

- structurer rôles Ansible
- déployer Zabbix agent
- ajouter nodes VM
- explorer inventory dynamique