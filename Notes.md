# Homelab – Notes techniques

## Projets actifs

### AWX

Déployé sur VM KVM dédiée (Debian 12 + k3s + AWX Operator). Proxmox était trop instable pour ce cas d'usage (nested virtualization + ressources).

Acquis :
- Déploiement AWX Operator sur k3s
- Gestion centralisée des credentials (SSH, Source Control, Vault, types custom)
- Projet Git synchronisé avec installation automatique des collections via `requirements.yml`
- Inventaire statique depuis le repo Git (`lab_vms_static.yml`)
- Inventaire dynamique Zabbix via plugin `community.zabbix.zabbix_inventory`
- Job Template opérationnel sur lab-vm-1 et lab-vm-2
- Journalisation complète des jobs (qui, quand, quoi, résultat par hôte)
- `proxmox_provision_vms.yml` réparé (23/09/2026) : plus de vars `vault_proxmox_*`, auth via variables d'env `PROXMOX_*` (lues nativement par `community.proxmox`), injectées dans AWX par un credential type custom « Proxmox API » ; Job Template `lab-vms-provision` défini en code
- **Job Templates `lab-vms-bootstrap` et `lab-vms-shutdown` créés et validés de bout en bout (27/08/2026)**, définis en code via `ansible/awx/job_templates.yml` (collection `awx.awx`, idempotent, rejouable)

Limitations connues :
- Plugin `community.zabbix.zabbix_inventory` ne résout pas les variables d'environnement injectées par AWX (bug [#713](https://github.com/ansible-collections/community.zabbix/issues/713), fermé sans fix côté plugin). En production, utiliser un script d'inventaire custom ou attendre un fix upstream.
- Credential type custom AWX créé (injection vars d'env) mais inefficace à cause du bug ci-dessus.

À faire :
- CI/CD via AWX en remplacement de GitHub Actions
- Inventaire dynamique Zabbix : investiguer script custom comme contournement
- Valider le Job Template `lab-vms-provision` dans AWX (playbook validé en local le 23/09/2026 ; token API Proxmox `root@pam!ansible` et credential `proxmox-api` créés)

---

### Ansible

Acquis :
- Structuration rôles, group_vars, playbooks idempotents
- Playbook master `provision_and_bootstrap.yml` : chaînage Proxmox → wait_for_connection → bootstrap → Zabbix agent
- Inventory dynamique Zabbix opérationnel avec filtre `groupids`
- Suppression du Vault (bug plugin Zabbix + complexité non justifiée pour le lab)

---

### Monitoring (Zabbix)

Acquis :
- Auto-register des agents, groupe `Lab VMs`, inventory dynamique filtré
- Template Proxmox VE by HTTP (API port 8006)
- Méthodologie de diagnostic incident : CPU / RAM / I/O / logs / réseau

Bug corrigé (27/08/2026) :
- `ansible/inventory/zabbix_inventory.yml` utilisait `keyed_groups` sur une clé `host_groups` qui n'existe pas dans les données renvoyées par le plugin (aucun `selectGroups` demandé côté API) → tous les hosts atterrissaient dans `ungrouped`, en local comme via AWX. Remplacé par `groups: {lab_vms: true}`, puisque `host_zapi_query` filtre déjà sur le groupe Zabbix "Lab VMs" (`groupids: ["27"]`) — inutile de re-dériver le nom du groupe.
- Credential AWX `ssh-homelab` : username vide (tentait une connexion `root`, refusée par les VMs) et clé SSH privée périmée par rapport à celle réellement autorisée sur les VMs. Les deux ont été corrigés directement dans AWX (pas versionné, c'est de la config runtime AWX).

---

### Infrastructure du lab

Évolution :
- ~~KVM nu~~ → Proxmox VE pour les VMs lab
- KVM nu conservé pour AWX (VM dédiée isolée)
- Containers Podman pour les nodes de test légers

VMs actives :
- `lab-vm-1` 192.168.122.101 — Debian 12, cloud-init
- `lab-vm-2` 192.168.122.102 — Debian 12, cloud-init
- `lab-crash-1` — VM de test pour scénarios d'incident (conservée)

---

### CI/CD

- Runner self-hosted GitHub Actions opérationnel
- Workflow sur push `ansible/` : Hugo + vérification containers + playbook Ansible
- Migration vers AWX prévue

---

### IA locale (Ollama) — déprécié (27/08/2026)

Toute la partie IA (RAG, mail-tagger) a été déplacée vers un projet perso non publié. Le stack Ollama + Open WebUI reste présent dans ce repo mais n'est plus développé activement ; ne pas y investir de nouveau travail sans confirmation.

Historique :
- Stack Ollama + Open WebUI via Docker Compose
- RAG : collection `devops-books` (22 livres devops/linux/sécurité)
- Mail-tagger : classification emails Thunderbird via Ollama
- Bug plugin Zabbix documenté → credentials en clair dans `zabbix_inventory.yml` — **attention : ce fichier est en fait tracké/commité dans git, pas gitignoré comme supposé ici**, à corriger (retirer du repo + rotation du mot de passe Zabbix)

---

## En pause / plus tard

- Grafana
- HashiCorp Vault
- NixOS
- Reverse DNS sur Raspberry Pi

---

## Exploration / Culture technique

### Proxmox VE

- Architecture : hyperviseur type 1, KVM + LXC + interface web
- Concurrents : VMware vSphere, XCP-ng, Hyper-V
- Provisioning VMs via Ansible (`community.proxmox`) avec IPs fixes cloud-init
- Monitoring via zabbix-agent2 + template Proxmox VE by HTTP

### AWX vs Semaphore

AWX apporte par rapport à Semaphore :
- Gestion des credentials chiffrés en base, jamais exposés dans les logs
- Granularité des permissions par équipe/rôle (exécuter sans voir les credentials)
- Journalisation complète et auditable des jobs
- Credential types custom pour injection de secrets
- Inventaires dynamiques intégrés

Semaphore : plus simple, suffisant pour usage solo, moins adapté à un contexte d'équipe.
