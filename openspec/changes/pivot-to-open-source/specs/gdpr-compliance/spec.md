# Spec delta : gdpr-compliance

## MODIFIED Requirements

### Requirement: Configurable Data Residency
La plateforme DOIT permettre à l'opérateur de déclarer la zone de résidence des données sous forme d'une liste libre d'identifiants (régions cloud, racks on-prem, juridiction documentaire) et DOIT empêcher tout démarrage si la liste n'est pas déclarée explicitement. Le cœur ne fige plus l'EU comme seule zone autorisée — c'est l'opérateur qui choisit, en fonction de ses propres obligations légales et contractuelles. Si l'opérateur configure plusieurs zones, la plateforme refuse toute réplication ou export vers une zone hors de la liste.

#### Scenario: Boot sans configuration de résidence
- **WHEN** un service démarre sans valeur pour `data_residency.allowed_regions`
- **THEN** il sort avec un statut non-zero et le message `data-residency-not-configured` ; aucun trafic n'est servi

#### Scenario: Réplication vers une zone hors liste rejetée
- **GIVEN** `data_residency.allowed_regions=["eu-west-3","eu-central-1"]`
- **WHEN** une configuration de réplication déclare une destination en `us-east-1`
- **THEN** la pré-condition de déploiement (Terraform / Helm hook) rejette le plan avec `region-not-allowed`
- **AND** le contrôleur de réplication runtime refuse également d'établir la connexion

#### Scenario: Self-check au boot
- **WHEN** un service démarre
- **THEN** il lit sa région effective (depuis les métadonnées cloud, l'env ou un fichier opérateur) et sort en non-zero si la valeur n'est pas dans `data_residency.allowed_regions`

### Requirement: Erasure Workflow (Operator Tool)
La plateforme DOIT fournir à l'opérateur un workflow d'effacement par identifiant (IP, domaine, host_id, ou tenant_id en mode multi-tenant). L'effacement DOIT être transactionnel : couvre simultanément la base OLTP, l'index vectoriel, le graphe (si la capacité `graph-retrieval` est active) et le tier froid (si configuré). Une tombstone hashée DOIT être écrite dans le journal d'audit. Le workflow ne tente pas de valider le « contrôle de la cible » par la personne concernée — c'est à l'opérateur, en tant que controller, de définir et d'exécuter sa procédure de vérification interne. La plateforme se borne à exécuter l'effacement de manière atomique et auditable une fois que l'opérateur l'a déclenché.

#### Scenario: Effacement déclenché par l'opérateur
- **GIVEN** des données existent pour `host_id=H1` (lignes scalaires, vecteurs, nœuds graphe)
- **WHEN** un opérateur avec rôle `admin` exécute l'effacement via UI ou API
- **THEN** dans la même transaction Postgres, les lignes scalaires, les vecteurs et les nœuds/arêtes graphe associés à `H1` sont supprimés
- **AND** une tombstone hashée est écrite dans le journal d'audit avec `actor`, `target_hash`, `reason`, `timestamp`
- **AND** un test e2e vérifie l'absence de l'identifiant dans toutes les couches après commit, et la persistance des données en cas de rollback

#### Scenario: Effacement multi-région quand la réplication est activée
- **GIVEN** une configuration de réplication active vers une autre région autorisée
- **WHEN** l'effacement est exécuté
- **THEN** la suppression se propage à la région répliquée selon le mécanisme Postgres standard
- **AND** la documentation opérateur explique comment vérifier la propagation (la métrique `audit_replication_lag_seconds` reste exposée si la réplication est configurée)

### Requirement: Append-Only Audit Log
Tout accès aux données et toute mutation de configuration sensible (scope, RBAC, secrets) DOIT être ajouté à un journal write-once. La rétention par défaut est de 24 mois, configurable par l'opérateur. Chaque entrée DOIT inclure `actor`, `action`, `target`, `timestamp` et `source_ip`. La table d'audit DOIT rejeter `UPDATE` et `DELETE` au niveau du rôle Postgres applicatif. La réplication cross-région reste *possible* (réplication logique Postgres standard) mais n'est plus un invariant cœur — c'est l'opérateur qui décide d'activer une topologie multi-région et de monitorer le retard.

#### Scenario: Opérateur lit un enregistrement d'hôte
- **WHEN** un opérateur visualise un enregistrement d'hôte via API ou UI
- **THEN** une ligne d'audit est ajoutée en moins de 1 seconde contenant actor, host_id, action=`read`, ts, source_ip

#### Scenario: Le journal d'audit est append-only
- **WHEN** un rôle de base de données tente `UPDATE` ou `DELETE` sur la table de journal d'audit
- **THEN** l'opération est rejetée par une politique imposée en base et la tentative elle-même est journalisée

### Requirement: External Subprocessors (Conditional)
Les sous-traitants externes (fournisseur d'embeddings, fournisseur d'auth, fournisseur de paiement éventuel) DOIVENT être encadrés par un Data Processing Agreement conforme à l'Art. 28 RGPD **entre l'opérateur et le fournisseur** — la plateforme ne contracte avec aucun fournisseur en lieu et place de l'opérateur. Toute intégration livrée (par ex. embedder Mistral) DOIT être désactivable et **désactivée par défaut**. Quand activée, la plateforme DOIT logger l'identité du fournisseur et l'endpoint utilisé, à des fins d'audit et de transparence pour l'opérateur.

#### Scenario: Mistral activé par l'opérateur
- **GIVEN** l'opérateur a configuré `embedder.provider=mistral` et fourni une clé API
- **WHEN** l'agent route une requête d'embedding contenant des données de scan vers Mistral
- **THEN** un log structuré est émis avec `subprocessor=mistral`, `endpoint=<URL configurée>`, `bytes_sent=<n>`
- **AND** la documentation opérateur rappelle que l'opérateur DOIT avoir signé un DPA Art. 28 avec Mistral avant cette activation

#### Scenario: Aucun appel sortant en configuration par défaut
- **GIVEN** la configuration par défaut (embedder local, pas d'OIDC public, pas de télémétrie)
- **WHEN** l'instance est bootée et reçoit du trafic interne pendant 5 minutes
- **THEN** un test d'audit réseau confirme zéro connexion sortante vers un endpoint public
- **AND** aucune entrée de log « subprocessor » n'est émise

## REMOVED Requirements

### Requirement: Right to Erasure for Scanned Subjects
**Raison :** L'exigence d'origine décrivait un workflow DSAR pour des personnes physiques identifiables dans des données collectées par Reconaut sur le grand internet (controller = Reconaut). Dans le nouveau modèle scope-driven et auto-hébergé, l'opérateur ne scanne que ses propres actifs et est lui-même le controller ; le DSAR de tiers scannés ne s'applique plus à la plateforme. La capacité technique d'effacement par identifiant est conservée et formalisée dans la nouvelle exigence `Erasure Workflow (Operator Tool)` — elle sert désormais d'outil d'hygiène pour l'opérateur, pas de canal de droit-au-public exposé en SaaS.

### Requirement: EU Data Residency
**Raison :** L'exigence figeait l'EU comme seule zone autorisée et exigeait au minimum deux régions EU read/write actives en simultané. Le nouveau modèle laisse l'opérateur choisir sa zone (EU, autre juridiction, on-prem hors cloud), et le multi-actif EU n'est plus un invariant cœur. Remplacée par `Configurable Data Residency` ci-dessus, qui maintient le contrat de blocage sortie-de-zone mais sur une liste configurable.
