# Modèle de responsabilité opérationnelle

Statut : **stable**.
Audience : opérateur d'instance Reconaut.

Ce document explique **qui est responsable de quoi** dans le couple opérateur ↔ Reconaut. Il ne donne **pas** d'avis juridique : c'est à l'opérateur d'établir sa propre conformité, son éthique de scan, et ses procédures internes.

## TL;DR

- **L'opérateur** : applique sa propre éthique et légalité de scan, choisit ses cibles, configure ses fournisseurs externes (s'il en active), tient sa propre conformité (RGPD ou autre — voir « Pas de cadre RGPD applicatif » plus bas).
- **Reconaut** : applique le **scope déclaré** (refus en dur des cibles hors scope), produit un journal d'audit append-only, expose des outils d'effacement par cible et d'étiquette de résidence — **comme outils opérationnels**, pas comme framework de conformité.
- **Fournisseurs externes activés par l'opérateur** (LLM cloud, embedder OpenAI-compatible, IdP OIDC quand il sera disponible) : sont sous la responsabilité de l'opérateur. Le projet en fournit des intégrations substituables, pas une caution.

## Pas de cadre RGPD applicatif

Reconaut **ne stocke pas de PII** au sens du RGPD. Le périmètre des données stockées est :

| Type de donnée               | Exemple                                                     | PII ? |
|------------------------------|-------------------------------------------------------------|-------|
| Entrée de scope              | `cidr:192.0.2.0/24`, `domain:example.fr`                    | Non — actif internet de l'opérateur |
| Hôte                         | IP, FQDN, `first_seen_at`, `last_seen_at`                   | Non — actif technique |
| Service                      | `port`, `protocol`, banner, fingerprint                     | Non — métadonnée technique |
| Certificat TLS               | CN/SAN, hash, dates de validité                             | Non — public par construction |
| Métadonnée de scan           | `idempotency_key`, `started_at`, `outcome`, `duration_ms`   | Non |
| Audit log                    | `caller_id` (`key:<prefix>` de la clé API), `action`        | Non |
| User opérateur               | `email` (matricule local, ex. `operator@local`), `password_hash` Argon2id | Non — identifiant local, pas une adresse réelle obligatoire |
| API keys                     | `prefix` (8 chars), `token_hash` (SHA-256 du token, jamais le clair), `scopes` MCP | Non |
| Embeddings (vecteurs sémantiques) | `host_id`, `content` (banner/services agrégés), `vector(384)`, `provider` (`local`/`ollama`/`mistral`/`openai-compatible`), `model`, `dim` | Non — métadonnée technique d'index ; aucun enrichissement nominatif |

Le change [`drop-gdpr-framing`](../../openspec/changes/drop-gdpr-framing/proposal.md) acte que le projet ne fournit pas de framework RGPD dédié (tombstone hashée, registre des traitements, validation EU codée en dur). Les capacités utiles — audit, erase, résidence — restent, sous cadrage **opérationnel**.

Si l'opérateur ingère **involontairement** des données personnelles (rare : un site web public qui retourne du contenu personnel dans son banner HTTP, par exemple), c'est à lui d'évaluer la conformité de sa pratique. Il dispose des outils suivants pour agir.

## Outils opérationnels fournis par Reconaut

### 1. Audit log append-only

Cf. [`init §6.3`](../../openspec/changes/init-reconaut-platform/tasks.md). La table `audit_log` est protégée par TRIGGERs Postgres qui rejettent tout `UPDATE`/`DELETE` direct avec un code d'erreur explicite. Chaque action mutante côté serveur (mutation de scope, scan déclenché, erase, mutation de clé API) écrit une ligne avec :

- `caller_id` — typiquement `key:<prefix>` de la clé API courante
- `template_id` ou nom d'action
- `params_normalized` — JSON normalisé (jamais de secrets)
- `duration_ms`, `nodes_touched`
- `outcome` — `success` / `unauthorized` / `param_invalid` / autre
- `recorded_at` — timestamp serveur

L'opérateur peut requêter `audit_log` directement en SQL, ou via les outils MCP de lecture quand ils seront livrés. Le journal est un outil **forensique** (debug, accountability, post-mortem) — pas un registre de traitements RGPD.

### 2. Effacement par cible

Cf. [`Reconaut::EraseTarget`](../../apps/api/app/lib/reconaut/erase_target.rb). Service transactionnel qui supprime, en une transaction Postgres :

- Les lignes scalaires `hosts` (matching id UUID, fqdn, ou ip), avec cascade FK vers `services`.
- Les lignes `scans` qui matchent target_value ou idempotency_key.
- Les nœuds AGE (Host{id=…}, Domain{name=…}, Service{host_id=…}) via `DETACH DELETE` Cypher.

Atomique : commit ou rollback global. Une ligne d'audit avec `target_hash` (SHA-256 du target) et le compte d'objets supprimés est écrite.

Cas d'usage typiques :

- Un actif n'est plus dans le scope → l'effacer pour ne pas garder une connaissance obsolète.
- Un certificat révoqué → purger pour ne pas alerter sur un faux positif.
- Une entrée erronée → nettoyer.

Ce n'est **pas** un workflow DSAR/RGPD. C'est un outil d'**hygiène opérationnelle**.

### 3. Étiquette de résidence des données

Cf. [`Reconaut::Doctor#check_data_residency`](../../apps/api/app/lib/reconaut/doctor.rb). L'opérateur déclare un identifiant libre de résidence via la variable d'environnement :

```sh
RECONAUT_DATA_RESIDENCY="on-prem-rack-paris-1"
RECONAUT_DATA_RESIDENCY="hetzner-fsn1"
RECONAUT_DATA_RESIDENCY="aws-eu-west-3"
RECONAUT_DATA_RESIDENCY="self-hosted"
```

Le doctor expose la valeur dans son rapport (info-level). **Aucune validation EU codée en dur** — c'est l'opérateur qui choisit comment cataloguer son ancrage géographique, et c'est sa propre conformité qui dicte ce qui est acceptable.

## Fournisseurs externes activés par l'opérateur

Reconaut peut être configuré pour appeler des services externes :

- **Embedder externe** : Mistral, OpenAI-compatible (LM Studio, vLLM, llama.cpp server, LiteLLM, Anthropic-compatible…). Activé via `RECONAUT_EMBEDDER_PROVIDER` + une URL/token. Sans cette config, l'embedder par défaut est local et `0 appel sortant`.
- **Ollama sidecar** : LLM/embedder local mais lancé hors process Rails. Reste 100 % réseau privé.
- **Future intégration OIDC** (différée) : Keycloak, Authentik, Dex, etc.

Quand l'opérateur active un fournisseur externe :

1. **Il devient responsable** de la relation avec ce fournisseur (contrat de sous-traitance, conditions d'usage, sécurité de la connexion).
2. **Reconaut ne porte aucune caution implicite**. Le projet livre l'intégration ; le choix du fournisseur et l'évaluation de sa conformité relèvent de l'opérateur.
3. **L'opérateur peut tout désactiver** : la configuration par défaut tourne 100 % en réseau privé sans appel sortant.

## Modèle de menace

Le détail vit dans [`openspec/project.md`](../../openspec/project.md) section *Modèle de menace et limites de responsabilité*. Résumé :

- **Pas de balayage du grand internet** — le scanner refuse en dur les cibles hors scope.
- **Pas de scan offensif** — pas de PoC d'exploitation, pas de bruteforce d'authentification, pas de payload weaponisé. Les sondeurs (SSH, HTTP, etc.) capturent banners et fingerprints en lecture pure.
- **Pas de télémétrie vers un acteur tiers** — pas de phone-home, pas de SDK d'analytics. L'instrumentation OpenTelemetry est livrable mais sans destination par défaut.
- **L'opérateur est seul destinataire** des traces / métriques / logs OTel s'il configure son propre collecteur.

## Liens

- [`drop-gdpr-framing`](../../openspec/changes/drop-gdpr-framing/proposal.md) — la décision et son raisonnement.
- [`audit-bootstrap.md`](../architecture/auth-bootstrap.md) — pourquoi `/auth/*` reste REST.
- [`mcp-first.md`](../architecture/mcp-first.md) — MCP comme canal principal.
- [`agent-knowledge-base.md`](../positioning/agent-knowledge-base.md) — vision produit.
