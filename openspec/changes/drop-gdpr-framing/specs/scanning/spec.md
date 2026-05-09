# Spec delta : scanning

## MODIFIED Requirements

### Requirement: Operational Data Lifecycle (rétention + erase)
La plateforme DOIT permettre à l'opérateur de gérer la **durée de vie opérationnelle** des données collectées :

- **Rétention chaude par défaut : 90 jours** sur la table `services` (hypertable TimescaleDB), configurable via `retention.hot_days`. Les chunks dépassant la fenêtre sont supprimés ou compressés selon la stratégie retenue.
- **Erase by target** : un outil opérateur permet de supprimer toutes les données associées à un identifiant (IP, FQDN, host_id) — utile pour retirer un hôte qui n'est plus scopé, purger un certificat révoqué, ou nettoyer une entrée erronée.

Le cadrage est **opérationnel** (volume de la base, granularité d'analyse historique, hygiène de la connaissance) — **pas** RGPD. Reconaut ne stocke pas de PII (cf. change `drop-gdpr-framing`).

#### Scenario: Rétention par défaut 90 jours
- **GIVEN** une instance Reconaut avec configuration par défaut
- **WHEN** un service vieillit au-delà de 90 jours
- **THEN** la politique Timescale `add_retention_policy('services', INTERVAL '90 days')` purge le chunk
- **AND** un test confirme que `policy_retention` est attaché à l'hypertable `services`

#### Scenario: Opérateur ajuste la fenêtre chaude
- **WHEN** un opérateur définit `retention.hot_days = 365`
- **THEN** les services ultérieurs sont conservés 365 jours
- **AND** le changement est journalisé dans le journal d'audit opérationnel

#### Scenario: Erase by target
- **GIVEN** des données existent pour `host_id=H1` (ligne hôte, services rattachés, nœuds graphe)
- **WHEN** l'opérateur exécute l'effacement via outil MCP `erase_target` (ou rake task équivalent)
- **THEN** dans la même transaction Postgres, les lignes scalaires (hosts/services/scans liés) ET les nœuds/arêtes AGE associés à `H1` sont supprimés
- **AND** une ligne d'audit est écrite avec `actor_key_id`, `target=H1`, `action=erase`, `outcome=success`

## REMOVED Requirements

### Requirement: GDPR-Driven Retention with Cold Tier and Tombstone
**Raison** : retiré au profit de la formulation `Operational Data Lifecycle` ci-dessus. Le tier froid (Postgres compressé / filesystem) reste **possible** (opérateur libre de configurer la compression Timescale) mais n'est plus un invariant cœur. Plus de tombstone hashée — l'audit standard suffit.
