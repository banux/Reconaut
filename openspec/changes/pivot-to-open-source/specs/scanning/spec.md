# Spec delta : scanning

## MODIFIED Requirements

### Requirement: Asset Discovery Pipeline
Le système DOIT scanner uniquement les actifs couverts par une entrée de scope **explicitement déclarée par l'opérateur** (CIDR, domaine ou hôte). Aucun balayage du grand internet n'est livré : sans entrée de scope active, le scanner n'émet aucune sonde. Pour chaque hôte découvert dans le scope, le système capture l'IP, l'ASN, la géolocalisation (ISO 3166-1 alpha-2 si dérivable des bases ouvertes embarquées, sinon `null`), le reverse-DNS (s'il existe) et les timestamps `discovered_at` / `last_seen`.

#### Scenario: Nouvel hôte découvert dans le scope
- **GIVEN** une entrée de scope active de `kind=cidr` couvrant `192.0.2.0/24`
- **WHEN** le planificateur exécute une fenêtre de scan sur cette plage et au moins un hôte répond
- **THEN** le système enregistre exactement une ligne `host` par IP répondante avec ASN, pays (si disponible), reverse-DNS (ou `null`) et `discovered_at`
- **AND** les hôtes déjà connus dans cette plage voient leur champ `last_seen` mis à jour dans la même transaction de base

#### Scenario: Cible hors scope refusée en dur
- **GIVEN** aucune entrée de scope active ne couvre `203.0.113.10`
- **WHEN** un job de scan ciblant `203.0.113.10` est consommé par un worker
- **THEN** le worker rejette le job avec le statut `out-of-scope`, n'émet **aucun paquet** vers la cible, et écrit une ligne d'audit avec `actor`, `target=203.0.113.10`, `reason=out-of-scope`
- **AND** un test réseau confirme qu'aucun socket sortant vers `203.0.113.10` n'a été ouvert

### Requirement: Scan Rate Limiting and Abuse Controls
Le scanner DOIT imposer des rate limits par cible et par AS pour ne pas saturer le périmètre scanné, et DOIT respecter `robots.txt` pour toute sonde HTTP au-delà de la page d'index. L'opt-out DNS du grand internet n'est plus pertinent puisque l'opérateur déclare son propre scope ; le scanner n'observe pas de signal d'opt-out tiers, mais reste contraint par le scope déclaré et par les rate limits.

#### Scenario: Limite par AS tenue
- **GIVEN** une limite par AS configurée à 50 requêtes/seconde
- **WHEN** le planificateur dispatche des sondes vers les hôtes de cet AS (tous dans le scope)
- **THEN** le débit sortant réel mesuré au NIC d'egress sur toute fenêtre de 10 secondes est ≤ 55 rps (tolérance 5 %) et ≥ 0 rps

#### Scenario: robots.txt interdit le crawl profond
- **GIVEN** un hôte du scope dont le `robots.txt` interdit `/admin`
- **WHEN** le sondeur HTTP envisage de récupérer `/admin`
- **THEN** la requête n'est pas émise et la décision est journalisée avec la raison `robots-disallow`

## REMOVED Requirements

### Requirement: Cible demande l'opt-out via DNS TXT
**Raison :** Reconaut ne scanne plus de tiers non sollicités. La protection contre le scan non sollicité reposait sur un opt-out (`_reconaut-optout TXT`) publié par les cibles ; dans le modèle scope-driven, la cible est par définition possédée ou contrôlée par l'opérateur, qui n'a pas besoin de publier un opt-out pour elle-même. Le mécanisme est retiré du cœur. Si un déploiement multi-tenant veut réintroduire un signal pour des sous-tenants imbriqués, ce sera l'objet d'un change séparé.

### Requirement: Hôte non répondant reste absent (sur balayage de /24)
**Raison :** Le scenario décrivait un balayage non sollicité d'un `/24` complet ; le nouveau modèle ne balaie pas — il sonde des cibles déclarées. Un hôte dans le scope qui ne répond pas reste absent par construction (pas de ligne créée), mais cette propriété tombe directement de la définition de « pipeline scope-driven » et n'a plus besoin d'un scenario dédié.

## ADDED Requirements

### Requirement: Scope Declaration and Enforcement
L'opérateur DOIT déclarer explicitement le scope autorisé sous forme d'entrées typées (`cidr`, `domain`, `host`). Toute mutation du scope (ajout, révocation) DOIT être journalisée dans le journal d'audit avec l'acteur, la valeur et la raison. Le scanner DOIT vérifier l'appartenance d'une cible au scope **au moment de l'exécution** du job (résolution DNS pour les entrées `domain` faite à ce moment-là), pas seulement à la planification.

#### Scenario: Ajout d'une entrée de scope
- **GIVEN** un opérateur authentifié avec rôle `admin`
- **WHEN** il appelle `POST /scopes` avec `{ "kind": "cidr", "value": "192.0.2.0/24", "description": "Périmètre de prod" }`
- **THEN** une ligne est créée avec `created_by`, `created_at` et `revoked_at = NULL`
- **AND** une ligne d'audit `action=scope.created` est écrite en moins de 1 s
- **AND** un job de scan ultérieur ciblant `192.0.2.10` n'est plus rejeté `out-of-scope`

#### Scenario: Révocation d'une entrée de scope
- **GIVEN** une entrée de scope active couvrant `192.0.2.0/24`
- **WHEN** l'opérateur appelle `DELETE /scopes/{id}`
- **THEN** `revoked_at` est posé sur la ligne (pas de suppression en dur)
- **AND** une ligne d'audit `action=scope.revoked` est écrite
- **AND** un job de scan ultérieur ciblant `192.0.2.10` est de nouveau rejeté `out-of-scope`

#### Scenario: Vérification au runtime (résolution DNS d'une entrée domain)
- **GIVEN** une entrée de scope active `kind=domain`, `value=example.test`
- **WHEN** un job de scan résout `example.test` à `192.0.2.10` au moment de l'exécution
- **THEN** la sonde sur `192.0.2.10` est autorisée
- **AND** si une révocation de l'entrée intervient entre la planification et l'exécution, la sonde est rejetée `out-of-scope` même si elle avait été planifiée précédemment
