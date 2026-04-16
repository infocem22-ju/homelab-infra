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

Limitations connues :
- Plugin `community.zabbix.zabbix_inventory` ne résout pas les variables d'environnement injectées par AWX (bug [#713](https://github.com/ansible-collections/community.zabbix/issues/713), fermé sans fix côté plugin). En production, utiliser un script d'inventaire custom ou attendre un fix upstream.
- Credential type custom AWX créé (injection vars d'env) mais inefficace à cause du bug ci-dessus.

À faire :
- Job Templates pour les playbooks principaux (bootstrap, shutdown)
- CI/CD via AWX en remplacement de GitHub Actions
- Inventaire dynamique Zabbix : investiguer script custom comme contournement

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

### IA locale (Ollama)

- Stack Ollama + Open WebUI via Docker Compose
- RAG : collection `devops-books` (22 livres devops/linux/sécurité)
- Mail-tagger : classification emails Thunderbird via Ollama
- Bug plugin Zabbix documenté → credentials en clair dans `zabbix_inventory.yml` (gitignored)

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
