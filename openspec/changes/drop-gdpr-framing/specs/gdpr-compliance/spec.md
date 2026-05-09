# Spec delta : gdpr-compliance

## REMOVED Requirements

### Requirement: Operator-as-Controller Boundary
**Raison** : Reconaut ne stocke pas de PII au sens RGPD (cf. `proposal.md` du change `drop-gdpr-framing`). Le périmètre réel des données — entrées de scope, hôtes, services, certificats, métadonnées de scan — couvre des actifs internet de l'opérateur, pas des personnes identifiables. Le cadre « opérateur as controller » n'a pas d'objet et signalait à tort que le projet serait conçu pour traiter du PII.

### Requirement: Erasure Workflow (Operator Tool)
**Raison** : retiré sous cette forme. La fonctionnalité d'effacement par cible reste utile pour l'hygiène opérationnelle (retirer un hôte hors scope, purger un certificat révoqué) — elle est conservée et reformulée dans la spec `scanning` modifiée par ce change comme **`Operational Erase by Target`**, sans tombstone hashée ni cadrage conformité.

### Requirement: Audit Trail (Append-Only, RGPD-aware)
**Raison** : retiré sous cette forme. Le journal d'audit append-only reste — il est utile pour la forensique opérationnelle indépendamment de RGPD — et est ré-introduit dans la spec `platform` modifiée comme **`Operational Audit Log`** (sans la dimension « registre des traitements », sans propagation cross-région obligatoire, sans checksum quotidien obligatoire — ces aspects restent **possibles** en doc opérateur mais ne sont plus des invariants core).

### Requirement: Data Residency Configuration (RGPD-driven)
**Raison** : retiré sous cette forme. La configuration de résidence reste, comme **étiquette documentaire de souveraineté** (cf. spec `platform` modifiée). Plus de validation EU codée en dur, plus de check `region in {eu-west-1, …}` au boot.

### Requirement: Cross-Region Replication for Audit Trail
**Raison** : retiré. La réplication Postgres standard reste possible (l'opérateur peut configurer son cluster comme il l'entend), mais elle n'est plus un invariant cœur du projet ni un test acceptance.

### Requirement: Records of Processing Activities (RoPA)
**Raison** : retiré. Le projet ne maintiendra pas de registre des traitements documentaire dans le repo.

## Note d'archivage

À l'archivage de `init-reconaut-platform`, la capacité `gdpr-compliance` ne figurera pas dans `openspec/specs/` — elle est retirée intégralement par ce change. Le dossier `openspec/changes/init-reconaut-platform/specs/gdpr-compliance/` peut être conservé comme archive historique (montre la posture initiale) mais n'est plus une source de vérité active.
