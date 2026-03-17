---
title: "Homelab"
---

# Architecture du Homelab

Le lab repose sur un environnement simulé via containers pour reproduire une infrastructure multi-machines.

---

## 🧱 Infrastructure actuelle

- Nodes Debian simulés avec Podman
- Accès SSH configuré automatiquement
- Inventaire Ansible généré dynamiquement

Chaque node est accessible localement :

- node-1 → localhost:2221
- node-2 → localhost:2222

---

## ⚙️ Automatisation

Les déploiements sont gérés via Ansible avec une structure progressive :

- tests de connectivité
- inspection des hosts
- déploiement de services
- configuration du monitoring

Objectif : atteindre une infrastructure déclarative et reproductible.

---

## 📊 Monitoring

Le lab intègre Zabbix pour observer :

- CPU
- mémoire
- I/O

Le monitoring permet de valider les déploiements et comprendre le comportement réel des systèmes.

---
## Déploiement du site

Le site est généré localement avec Hugo, puis déployé sur un node dédié via Ansible.

Chaîne actuelle :

- contenu Markdown
- génération du site statique avec Hugo
- copie du contenu généré vers le node web
- exposition via nginx

Ce workflow permet de séparer clairement :
- la génération du contenu
- le déploiement
- le service web

---
## 🔜 Évolutions prévues

- passage des containers aux VM
- enrichissement des rôles Ansible
- ajout de nouveaux services
- exploration Kubernetes