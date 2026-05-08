# Spec delta : platform

## MODIFIED Requirements

### Requirement: Authentication (Single Operator) via TUI
L'authentification DOIT être **mono-user, local-first** (cf. change `single-user-only`) : une instance Reconaut = **un seul opérateur humain** identifié par un mot de passe local Argon2id, plus N **clés API personnelles** (hashées en base) que cet opérateur peut générer avec leurs propres scopes MCP. Pas d'IdP externe en v1, pas de second compte.

Le canal d'accès opérateur de référence est le **binaire TUI `reconautctl`** (cf. spec `architecture` : Requirement TUI Operator Surface). Le binaire échange un mot de passe local contre une clé API personnelle côté Rails et utilise cette clé pour les appels suivants. Aucun navigateur web n'est requis pour le bootstrap, le login ou l'usage quotidien.

Le contrôle d'accès est porté par les **scopes attachés à chaque clé API** (et non par un rôle). Une clé scopée `read:hosts` + `read:scans` ne peut pas appeler un tool MCP qui exige `write:scans` — le serveur rejette avec une erreur structurée nommant le scope manquant.

#### Scenario: Bootstrap initial sans navigateur
- **GIVEN** une instance fraîchement déployée, sans password configuré
- **WHEN** l'opérateur initial exécute `rails reconaut:set_password` (avec `RECONAUT_OPERATOR_PASSWORD=<password>`) puis `reconautctl login`
- **THEN** le password de l'opérateur unique est stocké hashé Argon2id
- **AND** `reconautctl login` échange ce password contre une clé API personnelle stockée sous `$XDG_CONFIG_HOME/reconaut/credentials` (mode `0600`)
- **AND** aucune connexion sortante vers un IdP externe ni aucun navigateur n'a été ouvert pendant le bootstrap

#### Scenario: Clé API à scope insuffisant tente une action mutante via la TUI
- **GIVEN** un opérateur dont la clé API courante porte uniquement les scopes `read:hosts` et `read:scans`
- **WHEN** la TUI lance `reconautctl scan request --target 192.0.2.10` (qui invoque le tool MCP `request_scan` exigeant `write:scans`)
- **THEN** Rails répond HTTP 403 avec body `{ "error": "rbac_forbidden", "message": "missing scopes: write:scans" }`
- **AND** la TUI affiche un message d'erreur clair (pas de retry automatique)
- **AND** une entrée d'audit est écrite côté Rails avec le `key:<prefix>` de la clé courante

#### Scenario: L'opérateur génère une seconde clé scopée pour un agent IA
- **GIVEN** un opérateur loggué via `reconautctl login` avec une clé full-scope
- **WHEN** l'opérateur exécute `reconautctl keys create --scopes read:hosts,read:scans` (ou un appel direct `POST /auth/api_keys` avec body `{"scopes": ["read:hosts", "read:scans"]}`)
- **THEN** Rails émet une nouvelle clé API à scope réduit
- **AND** cette clé peut invoquer `search_hosts` mais pas `add_scope` ni `request_scan`
- **AND** la révocation de la clé scopée n'affecte pas la clé full-scope de la TUI
