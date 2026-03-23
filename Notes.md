# Homelab – Roadmap / Notes

## Projets actifs

### Ansible

- Structuration des rôles Ansible
- Mise en place d’un playbook de bootstrap des nodes
- Organisation des group_vars
- Stabilisation du lab containers

Objectif :

Comprendre le fonctionnement réel d’Ansible :
- inventaire
- rôles
- idempotence
- structuration d’infrastructure

---

### Monitoring

- Mise en place d’un monitoring Zabbix propre
- Installation et test du rôle `zabbix_agent2`

Objectifs :

- Comprendre les métriques système
- Lire correctement CPU / RAM / I/O
- Apprendre à interpréter les graphes Zabbix

---

### Infrastructure du lab

- Stabiliser le script `lab.sh`
- Ajouter des VM dédiées pour l’apprentissage Ansible
- Préparer une architecture extensible (containers / VM / machines physiques)

Prochaine évolution :

Containers → **VM**

---

### IA locale

- Stabilisation du RAG Ollama
- Organisation du dossier `knowledge`
- Tests de modèles locaux

Objectif :

Comprendre l’intégration d’un LLM dans un environnement auto-hébergé.

---

### Documentation

- Documentation du lab
- Création d’un README propre
- Structuration des notes techniques

---

## En cours de montée en priorité

### Kubernetes

À explorer après l’introduction des VM dans le lab.

Objectifs :

- comprendre l’orchestration de containers
- comprendre l’architecture d’un cluster
- comparer avec l’approche Ansible

---

## En pause / plus tard

- Mettre en place Semaphore pour orchestrer Ansible
- Github Action
- Apprendre les bases de Grafana
- Installer HashiCorp Vault
- Expérimenter NixOS

---

## Projets personnels

- Mettre en place un reverse DNS sur le Raspberry Pi

---

## Prochaine session

- tester playbook bootstrap
- préparer infrastructure VM pour le lab
- Passer en inventaire dynamique avec le module zabbix

Vendredi : session homelab "fun / exploration"
Pas d'objectif lourd, juste tester et découvrir.

Le bouton de bureau sert au contrôle rapide et à la visibilité immédiate.
Le monitoring détaillé reste le rôle de Zabbix.