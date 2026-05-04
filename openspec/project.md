# Reconaut — Contexte projet

Reconaut est un SaaS européen, conforme RGPD, qui cartographie les actifs exposés sur internet — un équivalent de Shodan avec l'IA comme capacité de premier ordre, pas un ajout cosmétique.

## Différenciateurs
- **Optimisation des scans pilotée par IA** — planification adaptative pondérée par le taux de churn, l'intérêt du tenant et la fraîcheur ; détection d'anomalies sur les profils de services par hôte.
- **Interface agent conversationnelle** — recherche en langage naturel sur le jeu de données indexé, propulsée par les embeddings `multilingual-e5-small` déjà embarqués sous `models/`.
- **Serveur MCP** — expose des outils de scan, de recherche et de reporting pour que les agents IA des clients automatisent leurs workflows contre Reconaut.
- **Résidence EU par politique** — bâti autour du principe de responsabilité du RGPD, pas plaqué après coup.

## Stack (existante et prévue)
- **Backend** : Python 3.12, async ; FastAPI pour l'API tenant ; aiohttp pour les workers de scan.
- **Stockage** : Postgres + hypertables TimescaleDB (timeseries de scan) + pgvector (index sémantique) ; stockage objet S3-compatible EU pour le tier froid (fournisseur différé, sujet procurement).
- **Embeddings** : `multilingual-e5-small` ONNX (384-dim), déjà présent à `models/model.onnx`. Paramètres dans `config.json` : chunk_size 500, top_k 5.
- **Auth** : OIDC ; choix concret de l'IdP différé (le contrat reste identique côté plateforme).
- **Facturation** : Stripe EU + Stripe Tax (compteurs : scans, appels MCP, dépassements de rétention).
- **MCP** : SDK Python officiel ; transport **HTTP+SSE uniquement** en v1 (stdio non livré).

## Hébergement
**Multi-actif EU/EEE** par décision d'architecture. Au moins deux régions EU sont autoritatives en read/write simultanément, avec réplication cross-région pour les données chaudes et le journal d'audit (cible : retard de réplication p99 < 5 s). La liste blanche des régions est appliquée au déploiement et revérifiée au boot.

## Non-objectifs
- Pas d'exploitation active, pas de PoC d'exploitation, pas de payloads weaponisés.
- Pas de désanonymisation de masse.
- Pas de scan au-delà de barrières authentifiées sans autorisation explicite du responsable de traitement.
- Pas de clients mobiles en v1.

## Conventions OpenSpec utilisées ici
- Le change fondateur vit sous `changes/init-reconaut-platform/`.
- Les domaines sont scindés en une spec par capacité (`scanning`, `ai-optimization`, `agent-interface`, `mcp-server`, `gdpr-compliance`, `platform`).
- Chaque `### Requirement:` porte au moins un `#### Scenario:` et utilise MUST/SHALL (DOIT/DEVRA en français).
- Les marqueurs structurels OpenSpec restent en anglais pour compatibilité outillage : `## ADDED Requirements`, `### Requirement:`, `#### Scenario:`, mots Gherkin en gras **GIVEN**/**WHEN**/**THEN**/**AND**. Le contenu en dessous est en français.
