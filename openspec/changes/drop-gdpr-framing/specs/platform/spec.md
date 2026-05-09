# Spec delta : platform

## ADDED Requirements

### Requirement: Operational Audit Log
La plateforme DOIT exposer un journal d'audit qui enregistre, pour chaque action mutante côté serveur (mutation de scope, scan déclenché, erase, mutation de clé API, etc.), au minimum : `caller_id` (typiquement `key:<prefix>` de la clé API courante), `template_id` ou nom d'action, `params_normalized` (Hash), `duration_ms`, `outcome` (`success` / `unauthorized` / `param_invalid` / autre), et un `recorded_at`. La table d'audit DOIT empêcher les UPDATE et DELETE pour le rôle applicatif (append-only).

Ce journal est cadré comme **outil opérationnel** (forensique, debug, accountability vis-à-vis de l'opérateur lui-même) — il n'est PAS un registre de traitements RGPD ni une trace de compliance. Le projet ne se prononce pas sur la conformité RGPD de l'opérateur ; cela relève de sa propre évaluation s'il scanne involontairement des actifs qui exposent des données personnelles dans leurs bannières.

#### Scenario: Mutation de scope est auditée
- **GIVEN** une clé API avec scope `write:scopes`
- **WHEN** la clé invoque le tool MCP `add_scope`
- **THEN** une ligne d'audit est écrite avec `caller_id=key:<prefix>`, `action=create`, `kind`, `value`, `outcome=success`
- **AND** un test grep confirme que la table d'audit est en mode append-only (`UPDATE` et `DELETE` direct rejetés par le rôle applicatif)

#### Scenario: Le journal n'est pas un registre RGPD
- **GIVEN** une instance Reconaut
- **WHEN** un opérateur consulte la doc
- **THEN** la doc indique explicitement que le journal d'audit est un outil opérationnel, pas un registre de traitements RGPD
- **AND** aucune fonctionnalité du projet ne prétend produire un Records of Processing Activities (RoPA)

### Requirement: Data Residency as Sovereignty Label
La plateforme DOIT permettre à l'opérateur de déclarer un identifiant de résidence des données (`data_residency.label`) — chaîne libre documentaire (`"on-prem-rack-eu-1"`, `"hetzner-fsn1"`, `"aws-eu-west-3"`, `"self-hosted"`, etc.). Cette valeur est consommée par le doctor (info-level) et exposée pour observabilité, mais le projet **n'effectue aucune validation RGPD** : le contenu de la chaîne et la localisation effective relèvent de l'opérateur.

#### Scenario: Doctor expose la résidence déclarée
- **GIVEN** `RECONAUT_DATA_RESIDENCY=on-prem-rack-paris-1`
- **WHEN** l'opérateur lance `bin/rails reconaut:doctor`
- **THEN** le rapport contient un check `data_residency` avec status `:info` et la valeur déclarée
- **AND** le check ne valide PAS la valeur contre une allowlist EU (le check `region` historique est retiré de cette responsabilité)

#### Scenario: Résidence non configurée → info, pas fail
- **GIVEN** aucune valeur `RECONAUT_DATA_RESIDENCY`
- **WHEN** doctor s'exécute
- **THEN** le check rapporte `:unknown` avec `details="résidence non déclarée — l'opérateur peut la déclarer via RECONAUT_DATA_RESIDENCY"`
- **AND** le doctor ne renvoie PAS d'exit code non-nul pour cette absence (résidence est une étiquette, pas une exigence)

## REMOVED Requirements

### Requirement: Audit Trail with EU Residency Constraint
**Raison** : retiré. La résidence devient un label documentaire (cf. ci-dessus), pas une exigence cadrée par RGPD avec allowlist EU.

### Requirement: Records of Processing Activities (operator's responsibility)
**Raison** : retiré. Le projet ne se prononce pas sur le RoPA de l'opérateur. Si l'opérateur a besoin d'un RoPA, il l'écrit lui-même hors du projet.
