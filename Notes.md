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
- VM disponibles via `vm.sh` — inventory à stabiliser
- Préparer une architecture extensible (containers / VM / machines physiques)

Prochaine évolution :

Containers → **VM**

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

À explorer après l'introduction des VM dans le lab.

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

## Prochaine session

- tester playbook bootstrap
- stabiliser inventory dynamique VMs (Zabbix)

Le bouton de bureau sert au contrôle rapide et à la visibilité immédiate.
Le monitoring détaillé reste le rôle de Zabbix.