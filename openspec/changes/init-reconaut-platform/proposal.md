# Change : init-reconaut-platform

## Pourquoi
Reconaut est initialisé comme un SaaS européen conforme RGPD pour la découverte d'actifs internet — un équivalent de Shodan avec l'IA comme capacité de premier ordre (optimisation, agent conversationnel, automatisation MCP). Le dépôt ne contient pour l'instant qu'un `README.md` minimal (les fichiers `config.json`, `models/` et `vectors.db` éventuellement présents dans le working tree appartiennent à un autre projet — `devrag` — et sont git-ignored). Ce change établit les exigences fondatrices à travers six domaines pour que les changes OpenSpec suivants se conçoivent contre une base stable.

C'est volontairement un change de *fondation* : il code la surface contractuelle de la plateforme (ce qu'elle fait, ce qu'elle ne DOIT PAS faire, comment elle est observable) plutôt que d'implémenter une fonctionnalité unique en profondeur. Les fonctionnalités concrètes (par ex. un sondeur de protocole donné, un modèle d'anomalie particulier) feront l'objet de propositions OpenSpec ultérieures.

## Ce qui change
Le change ajoute des exigences initiales dans six domaines de spec :

1. **scanning** — pipeline de découverte, fingerprinting de ports/services, contrôles d'abus (rate limits, signaux d'opt-out), rétention.
2. **ai-optimization** — planificateur adaptatif, détection d'anomalies.
3. **agent-interface** — recherche sémantique avec `multilingual-e5-small`, restriction au tenant, citation de provenance.
4. **mcp-server** — surface d'outils MCP (`search_hosts`, `get_host`, `request_scan`, `get_scan_status`, `export_report`), scopes, audit. Transport HTTP+SSE uniquement.
5. **gdpr-compliance** — résidence des données EU, droit à l'effacement, journal d'audit immuable, exigences multi-région.
6. **platform** — isolation multi-tenant, OIDC + RBAC.

Il amorce aussi `openspec/project.md` pour que les changes futurs partagent un document de contexte.

## Contraintes
- Tout traitement et stockage DOIVENT rester dans les juridictions EU/EEE ; aucun transfert vers un pays tiers sans mécanisme Art. 46.
- Le modèle d'embedding est figé à `multilingual-e5-small` (384-dim) pour la v1 (multilingue, légère, déployable CPU). Reconaut packagera son propre artefact ; aucune dépendance sur des fichiers présents dans le working tree au moment du bootstrap.
- Le scan DOIT respecter les limites de consentement des cibles (opt-out DNS, robots.txt pour les sondes HTTP au-delà de la page d'index) et les rate limits par cible et par AS.
- L'isolation tenant DOIT être imposée à la couche la plus basse possible (RLS Postgres, partitionnement de queue, préfixe object store) — pas par filtres applicatifs après-coup.
- L'architecture multi-actif EU implique que toutes ces propriétés (isolation, audit, effacement) DOIVENT tenir simultanément dans chaque région active et survivre à la réplication.

## Non-objectifs (hors scope de ce change)
- Exploitation active, PoC d'exploitation ou payloads weaponisés de toute nature.
- Couverture IPv6 full-space en v1 — préfixes échantillonnés uniquement.
- Clients mobiles.
- Distribution on-prem chez le client ; SaaS uniquement.
- Choix d'un modèle d'anomalie spécifique (linéaire / GBDT / NN) — l'exigence spécifie le contrat, pas l'implémentation.
- Transport stdio du serveur MCP — pas en v1.

## Décisions prises
1. **Architecture EU** — Multi-actif EU. La plateforme tourne simultanément dans au moins deux régions EU (read/write autoritatif dans chacune), avec réplication cross-région pour les données chaudes et le journal d'audit. Conséquence : isolation tenant, durabilité d'audit et workflows d'effacement DOIVENT tenir compte du retard de réplication (cible : p99 < 5 s).
2. **Transport MCP** — HTTP+SSE uniquement. Stdio n'est pas livré en v1. Conséquence : le serveur MCP est un service réseau authentifié par clé API tenant sur TLS ; aucun chemin de code stdio n'est exercé par les tests ou la doc.

## Différé (non bloquant, parqué pour plus tard)
- **Fournisseur d'identité** — Choix entre Keycloak EU auto-hébergé et WorkOS / Auth0 EU est parqué. La spec `platform` exige toujours OIDC + les cinq rôles ; le IdP concret peut être permuté sans altérer le contrat.
- **Stockage objet tier froid** — Scaleway vs OVHcloud est un sujet procurement. Tout stockage S3-compatible en région EU/EEE satisfait l'exigence de résidence ; le choix est différé et ne bloque pas l'implémentation.
