# Spec delta : gdpr-compliance

## ADDED Requirements

### Requirement: EU Data Residency
Toutes les données de scan, embeddings, index vectoriels, PII tenant et journaux d'audit DOIVENT être stockés et traités dans des juridictions EU/EEE. Le transfert vers un pays tiers DOIT être bloqué sauf si un mécanisme Art. 46 est explicitement configuré pour ce flux de données. L'architecture étant multi-actif EU, les données peuvent résider simultanément dans plusieurs régions EU autoritatives ; la liste blanche des régions s'applique à toutes.

#### Scenario: Déploiement tente une région non-EU
- **WHEN** un plan de déploiement déclare un stockage en `us-east-1`
- **THEN** le job de déploiement échoue immédiatement avec l'erreur `region-not-allowed` avant qu'aucune ressource ne soit provisionnée

#### Scenario: Self-check runtime au boot
- **WHEN** un service démarre
- **THEN** il lit sa région effective depuis les métadonnées cloud et sort avec un statut non nul si la région n'est pas dans la liste blanche `{eu-west-3, eu-central-1, fr-par, nl-ams, de-fra}`

#### Scenario: Réplication cross-région reste dans l'EU
- **WHEN** un mécanisme de réplication est configuré entre régions
- **THEN** les régions source et destination sont toutes deux dans la liste blanche EU ; toute configuration croisant cette frontière est rejetée par la pré-condition Terraform et par le contrôleur de réplication runtime

### Requirement: Right to Erasure for Scanned Subjects
La plateforme DOIT fournir un workflow de suppression vérifiable pour les personnes physiques identifiables dans les données de scan (par ex. un service auto-hébergé lié à une IP résidentielle). L'effacement DOIT se compléter en moins de 30 jours après approbation et DOIT couvrir les tiers chaud, froid et vectoriel **dans toutes les régions EU actives**.

#### Scenario: Demande d'effacement vérifiée honorée multi-région
- **GIVEN** une personne concernée vérifiée soumet une demande d'effacement avec preuve de contrôle sur un identifiant IP/domaine
- **WHEN** un opérateur approuve la demande
- **THEN** sous 30 jours toutes les références à cet identifiant sont supprimées du tier chaud, du tier froid et de l'index vectoriel **dans chaque région EU active**
- **AND** une tombstone hashée est écrite dans le journal d'audit pour que la complétude puisse être revérifiée par région
- **AND** un message de confirmation est envoyé au contact vérifié de la personne concernée

#### Scenario: Demande non vérifiée rejetée
- **GIVEN** une demande d'effacement sans vérification de contrôle de l'identifiant
- **WHEN** l'UI opérateur charge la demande
- **THEN** l'action « approuver » est désactivée et l'UI explique pourquoi

### Requirement: Audit Logging
Tout accès à des données personnelles et tout changement de politique de scan DOIT être ajouté à un journal write-once conservé au moins 24 mois. Chaque entrée DOIT inclure `actor`, `action`, `target`, `timestamp` et `source_ip`. La réplication cross-région DOIT garantir que toute entrée d'audit est visible dans toutes les régions EU actives en moins de 5 secondes (p99).

#### Scenario: Opérateur lit un enregistrement d'hôte
- **WHEN** un opérateur visualise un enregistrement d'hôte via API ou UI
- **THEN** une ligne d'audit est ajoutée en moins de 1 seconde contenant actor, host_id, action=`read`, ts, source_ip

#### Scenario: Le journal d'audit est append-only
- **WHEN** un rôle de base de données tente `UPDATE` ou `DELETE` sur la table de journal d'audit
- **THEN** l'opération est rejetée par une politique imposée en base et la tentative elle-même est journalisée

#### Scenario: Réplication cross-région d'audit
- **WHEN** une entrée d'audit est écrite dans n'importe quelle région EU active
- **THEN** elle est observable depuis les autres régions EU actives en moins de 5 secondes (p99) ; un test de monitoring continu publie une métrique `audit_replication_lag_seconds`
