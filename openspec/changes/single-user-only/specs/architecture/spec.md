# Spec delta : architecture

## MODIFIED Requirements

### Requirement: Single API Key per Operator Across MCP Clients
L'opérateur unique d'une instance Reconaut DOIT pouvoir utiliser **une ou plusieurs clés API personnelles** pour ses différents usages : TUI, agents IA externes, scripts CI. Le modèle mono-user (cf. spec `platform`) implique qu'il n'y a qu'un seul opérateur, mais cet opérateur peut détenir N clés API simultanément, chacune avec son propre set de scopes (défense-en-profondeur).

La plateforme NE DOIT PAS imposer de typer la clé par client (pas de `tui_key` vs `mcp_key`). Toute clé valide donne accès aux outils MCP couverts par ses scopes. La révocation d'une clé NE DOIT couper QUE les usages associés à cette clé — les autres clés de l'opérateur restent fonctionnelles.

#### Scenario: TUI et agent IA partagent une instance avec deux clés différentes
- **GIVEN** un opérateur authentifié avec une clé full-scope (utilisée par `reconautctl`) ET une clé `read:hosts` + `read:scans` (utilisée par un agent IA)
- **WHEN** la TUI invoque `add_scope` et l'agent IA invoque `search_hosts` simultanément
- **THEN** les deux appels réussissent (chacun a les scopes nécessaires)
- **AND** chaque appel est audité avec son propre `actor_key_id` distinct

#### Scenario: Révocation d'une clé n'affecte pas les autres
- **GIVEN** l'opérateur a deux clés actives (TUI full-scope et agent read-only)
- **WHEN** l'opérateur invoque `revoke_api_key` sur la clé read-only
- **THEN** dans la minute, l'agent IA reçoit une erreur d'auth structurée sur son prochain appel
- **AND** la TUI continue de fonctionner avec sa clé full-scope intacte
- **AND** une ligne d'audit nomme la révocation et la clé révoquée
