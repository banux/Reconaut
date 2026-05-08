# Spec delta : architecture

## MODIFIED Requirements

### Requirement: Frontend Interface
Le frontend opérateur de Reconaut DOIT être implémenté comme un **binaire Go** fournissant une **TUI** (Terminal User Interface) construite sur la suite Charm (`bubbletea` + `lipgloss` + `bubbles`, licence MIT, compatibles AGPL-3.0-only). Le binaire est nommé `reconautctl` et se distribue sous forme d'un binaire statique multi-arch indépendant des autres composants. **Aucun framework web** (Vue, React, Svelte, Angular, Solid, Nuxt, etc.) ne DOIT être livré dans le périmètre v1. Aucun bundle JavaScript / asset pipeline statique côté Rails ne DOIT exister pour servir une SPA.

#### Scenario: Tentative d'introduire un framework web
- **GIVEN** une PR ajoute un répertoire `apps/web/` ou un fichier `*.vue`/`*.jsx`/`*.tsx`/`*.svelte` dans le repo
- **WHEN** le pipeline CI s'exécute
- **THEN** le check de stack rejette la PR avec le message `frontend-stack-violation: web frameworks not shipped in v1, use the Go TUI`
- **AND** le job ne progresse pas

#### Scenario: Le binaire reconautctl est un binaire statique Go
- **GIVEN** une release publiée
- **WHEN** un opérateur télécharge `reconautctl` pour son architecture
- **THEN** le binaire s'exécute sans installation préalable de runtime (pas de Node, pas de Ruby, pas de bundle JS)
- **AND** `file reconautctl` confirme un binaire ELF/Mach-O statiquement linké pour l'arch attendue

#### Scenario: Aucun asset pipeline web servi par Rails
- **GIVEN** l'app Rails déployée
- **WHEN** un client envoie `GET /` ou `GET /assets/*` à l'API
- **THEN** Rails ne sert ni page HTML ni bundle JS — seules les routes API/MCP/auth sont exposées
- **AND** le linter de stack rejette toute introduction d'un répertoire `app/javascript/` ou d'une dépendance type `propshaft`/`importmap-rails`/`sprockets-rails`

### Requirement: Scan Workers Runtime
Les workers de scan (énumération de sous-domaines, port scan, fingerprinting de protocole, capture de bannière, parsing TLS) DOIVENT être implémentés en **Go** (Golang) comme binaires statiques séparés du process Rails. **Chaque `scan_kind` a son propre binaire dédié** (`scanner-tcp`, `scanner-tls`, `scanner-http`, `scanner-dns`, `scanner-fingerprint`, ou équivalents) consommant **sa propre queue GoodJob** nommée `scan:<kind>`. Aucune logique de scan ne DOIT résider dans le code Rails ni dans une gem Ruby chargée par Rails. Aucun binaire « universel » qui dispatch sur tous les `scan_kind` ne DOIT être livré — la séparation en binaires spécialisés est un invariant de surface d'attaque.

#### Scenario: Un binaire par scan_kind
- **GIVEN** la liste des `scan_kind` supportés par `ScanJobV1` (cf. `packages/job-schema/scan_job_v1.json`)
- **WHEN** la release est construite
- **THEN** un binaire Go distinct est publié pour chaque `scan_kind` (au minimum cinq pour la liste actuelle)
- **AND** un linter CI vérifie que chaque binaire n'importe que les packages Go correspondant à son protocole (par ex. `scanner-tcp` n'importe pas `crypto/tls`, `scanner-http` n'importe pas `net.dialUDP`)

#### Scenario: Chaque worker consomme sa propre queue
- **GIVEN** Rails enqueue un job avec `scan_kind=tls_capture`
- **WHEN** le job est persisté dans `good_jobs`
- **THEN** son `queue_name` est `scan:tls_capture`
- **AND** seuls les binaires `scanner-tls` consomment cette queue (`SELECT ... WHERE queue_name = 'scan:tls_capture' FOR UPDATE SKIP LOCKED`)
- **AND** un binaire `scanner-tcp` lancé sur la même DB ne voit jamais ce job

#### Scenario: Crash d'un worker spécialisé n'affecte pas les autres
- **GIVEN** le binaire `scanner-tls` panique sur une réponse TLS malformée
- **WHEN** son process se termine
- **THEN** les autres workers (`scanner-tcp`, `scanner-http`, etc.) continuent de consommer leurs queues sans interruption
- **AND** le process Rails continue de servir l'API et MCP

## ADDED Requirements

### Requirement: TUI Operator Surface
Le binaire `reconautctl` DOIT exposer au minimum les sous-commandes / vues TUI suivantes, chacune mappée sur un endpoint de l'API Rails existante :

- `reconautctl login` — invite interactive (email + mot de passe), échange contre une clé API personnelle, stocke la clé sous `$XDG_CONFIG_HOME/reconaut/credentials` en mode `0600`. Aucun secret n'est jamais affiché en clair après stockage.
- `reconautctl logout` — efface la clé API stockée (et révoque la clé côté serveur si l'opérateur le demande explicitement).
- `reconautctl scope list|add|revoke` — gestion du scope déclaré (cf. spec `scanning`).
- `reconautctl scan request|status|list` — déclenchement et suivi des scans (cf. spec `mcp-server` / `scanning`).
- `reconautctl hosts search|show` — recherche et inspection d'hôtes.
- `reconautctl agent` — chat conversationnel interactif via SSE sur `/agent/chat` (cf. spec `agent-interface`).
- `reconautctl doctor` — appel au self-check Rails (équivalent de `rails reconaut:doctor` mais piloté à distance par le binaire opérateur).

Toutes les actions destructrices ou productrices d'effet (révocation de scope, déclenchement de scan, effacement DSAR) DOIVENT demander une confirmation explicite (« y/N » ou similaire) avant exécution.

#### Scenario: Login interactif crée un fichier credentials sécurisé
- **GIVEN** un opérateur fraîchement déployé qui n'a jamais loggué `reconautctl`
- **WHEN** l'opérateur lance `reconautctl login` et saisit email + mot de passe d'un compte local existant
- **THEN** le binaire envoie la requête d'authentification à l'API Rails et reçoit une clé API personnelle
- **AND** la clé est écrite sous `$XDG_CONFIG_HOME/reconaut/credentials` avec mode `0600`
- **AND** le mot de passe N'EST PAS persisté localement
- **AND** un test e2e vérifie que `stat -c '%a' $XDG_CONFIG_HOME/reconaut/credentials` renvoie `600`

#### Scenario: Le binaire ne dépend d'aucun runtime externe
- **WHEN** un opérateur lance `reconautctl --version` sur un système minimal (alpine sans Ruby ni Node)
- **THEN** le binaire affiche sa version et sort en zéro
- **AND** un test charge `ldd reconautctl` (Linux) ou `otool -L` (macOS) et confirme l'absence de dépendances dynamiques non-stdlib (sauf libc / libsystem)

#### Scenario: Action destructrice demande confirmation
- **GIVEN** un opérateur authentifié avec rôle `admin`
- **WHEN** il lance `reconautctl scope revoke <id>`
- **THEN** la TUI affiche les détails du scope concerné et demande « Confirmer la révocation ? [y/N] »
- **AND** sans réponse explicite « y », aucune requête de révocation n'est envoyée à l'API
- **AND** un test e2e en mode non-interactif (drapeau `--yes`) court-circuite la confirmation pour les scripts

### Requirement: Operator Binary Boundary
Le binaire `reconautctl` est un **client** de l'API Rails. Il NE DOIT PAS contenir de logique métier qui dupliquerait ou contournerait les invariants du serveur (vérification de scope, validation RBAC, audit). Toute décision d'autorisation DOIT être prise côté Rails ; le binaire ne fait que l'invocation de l'API et la présentation des résultats.

#### Scenario: Le binaire ne court-circuite pas le contrôle de scope
- **GIVEN** un opérateur avec rôle `admin` qui demande un scan via `reconautctl scan request --target 203.0.113.10`
- **AND** la cible n'est pas dans le scope déclaré
- **WHEN** le binaire envoie la requête à `POST /scans`
- **THEN** Rails répond `out-of-scope` (cf. spec `scanning`) et le binaire affiche l'erreur sans contourner
- **AND** un audit du code Go du binaire confirme l'absence de logique de validation de scope locale (pas de fichier `scope_validator.go` dans `apps/tui/`)

#### Scenario: Le binaire ne stocke aucune donnée de scan localement
- **GIVEN** un opérateur visualise des hôtes via `reconautctl hosts show H1`
- **WHEN** la session se termine
- **THEN** aucune donnée de scan n'est persistée sur le poste de l'opérateur (pas de cache local, pas de DB locale)
- **AND** seul le fichier credentials (clé API + URL du backend) reste sur disque
