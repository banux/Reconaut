# Déclarer son scope

Statut : **stable**.
Audience : opérateur qui démarre une instance Reconaut.

Ce document explique le modèle **scope-driven** de Reconaut, comment déclarer son périmètre d'actifs, et ce qui se passe quand une cible n'est pas dans le scope.

## Pourquoi un scope ?

Reconaut **refuse en dur** de scanner toute cible qui n'est pas explicitement déclarée par l'opérateur. C'est la frontière éthique et légale du produit — l'invariant central de [`openspec/project.md`](../../openspec/project.md) :

> Le scanner refuse par construction de scanner une cible hors de la liste d'autorisation déclarée par l'opérateur. Pas de découverte du grand internet « à la Shodan ».

Conséquence pratique : avant de scanner quoi que ce soit, l'opérateur déclare ce qu'il possède ou contrôle. Sans entrée de scope active couvrant la cible, **tout scan est rejeté** avec l'erreur `out-of-scope` — pas un seul paquet réseau n'est émis vers la cible.

## Trois formes de scope

Une entrée de scope porte un `kind` ∈ `{cidr, domain, host}` et une `value` typée :

| `kind`   | Exemple                  | Couvre                                                                      |
|----------|--------------------------|-----------------------------------------------------------------------------|
| `cidr`   | `192.0.2.0/24`           | Toute IP dans le réseau 192.0.2.0/24, plus tout sous-réseau plus restreint |
| `domain` | `example.fr`             | **Le domaine exact** `example.fr` (pas les sous-domaines en v1).            |
| `host`   | `mail.example.fr`        | **Le FQDN exact** `mail.example.fr`.                                        |

Chaque entrée porte aussi `description` (texte libre — utile pour expliquer pourquoi cette zone est dans le scope), `created_by` (clé API auteure), `created_at`, et `revoked_at` (nul tant que l'entrée est active).

### Ce que le scope ne fait PAS en v1

- **Pas de wildcard sous-domaine**. `domain:example.fr` ne couvre **pas** `sub.example.fr`. Si tu veux scanner les sous-domaines, ajoute une entrée `host:sub.example.fr` ou utilise `subdomain_enum` qui découvre des sous-domaines à partir d'un domaine déjà scopé puis tu ajoutes les sous-domaines découverts à ton scope.
- **Pas de match de famille IP**. `cidr:2001:db8::/32` couvre IPv6 ; `192.0.2.0/24` couvre IPv4. Pas de translation automatique.
- **Pas de glob de domaine**. `*.example.fr` n'est pas une entrée valide.

## Déclarer une entrée de scope

### Via l'outil MCP `add_scope`

Le canal canonique est MCP HTTP+SSE. Avec une clé API qui porte le scope MCP `write:scopes` :

```sh
curl -X POST http://localhost:3000/mcp/tools/add_scope \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $RECONAUT_API_KEY" \
  -d '{
    "kind": "cidr",
    "value": "192.0.2.0/24"
  }'
```

Réponse 200 :

```json
{
  "tool": "add_scope",
  "result": { "ok": true, "scope": { "id": "...", "kind": "cidr", "value": "192.0.2.0/24", ... } }
}
```

### Via la TUI `reconautctl`

Une fois loggué (`reconautctl login`) :

```sh
reconautctl scope add ip 192.0.2.10
reconautctl scope add cidr 192.0.2.0/24
reconautctl scope add domain example.fr
reconautctl scope add host mail.example.fr
reconautctl scope list
```

### Via un agent IA externe

Le même outil MCP `add_scope` est utilisable par n'importe quel SDK MCP (Claude SDK, OpenAI Assistants, agents maison) avec une clé API ayant le scope `write:scopes`. C'est le pattern recommandé pour un agent qui orchestre la découverte ET l'extension du scope (l'opérateur valide a posteriori via le journal d'audit).

## Ce qui se passe quand une cible est hors scope

L'enforcement est côté Rails, **avant l'enqueue du job**. Le service `Reconaut::ScanEnqueuer` appelle `ensure_in_scope!(target_kind, target_value)` qui :

1. Récupère toutes les entrées de scope **actives** (`revoked_at IS NULL`).
2. Pour chacune, applique `ScanScopeEntry#covers?(target_kind, target_value)` :
   - `cidr` : utilise `IPAddr#include?` pour tester l'inclusion réseau (IP, CIDR, ou host résolu).
   - `domain` : match strict (égalité de chaîne).
   - `host` : match strict.
3. Si **aucune** entrée ne couvre la cible : lève `Reconaut::ScanEnqueuer::OutOfScopeError`.

L'erreur remonte au tool MCP qui renvoie :

```json
{
  "tool": "request_scan",
  "result": {
    "ok": false,
    "error": "out-of-scope",
    "message": "out-of-scope: ip:8.8.8.8 n'est pas dans la liste declaree"
  }
}
```

**Aucun job n'est enqueueé**. **Aucun paquet réseau n'est émis** vers la cible. Une ligne d'audit est écrite côté Rails avec `outcome=out-of-scope`, `caller_id` (la clé qui a tenté), et `target_value`.

## Révoquer une entrée de scope

Le scope est **append-only** — on ne supprime pas, on **révoque** :

```sh
reconautctl scope revoke <scope_id>
```

ou via MCP :

```sh
curl -X POST http://localhost:3000/mcp/tools/revoke_scope \
  -H "Authorization: Bearer $RECONAUT_API_KEY" \
  -d '{"id": "<scope_id>"}'
```

Cela pose `revoked_at` = `now()`. Toute requête `request_scan` ultérieure pour une cible qui n'était couverte que par cette entrée sera rejetée.

L'entrée révoquée reste **dans la table** pour la traçabilité — l'audit doit pouvoir reconstruire l'historique des scopes actifs à un instant T.

## Que se passe-t-il pour les actifs déjà scannés ?

La révocation d'une entrée de scope **ne purge pas** automatiquement les hôtes/services/scans déjà ingérés pour cette cible. C'est volontaire : l'historique reste consultable.

Si tu veux purger les données d'un actif retiré du scope, utilise **l'outil d'effacement par cible** :

```sh
reconautctl erase <host_id_ou_fqdn_ou_ip>
```

Cf. [`responsibility-model.md`](../operating/responsibility-model.md) section *Effacement par cible*. C'est un outil d'**hygiène opérationnelle**, pas RGPD.

## Résolution DNS au moment du scan

Pour les entrées `domain`, la résolution DNS qui transforme un domaine en IPs concrètes est faite **au moment du scan**, pas à la déclaration. Conséquences :

1. Si les enregistrements DNS du domaine changent (par ex. l'opérateur change l'hébergeur), Reconaut suit automatiquement vers les nouvelles IPs au prochain scan.
2. Le scope `domain:example.fr` couvre l'ensemble des IPs auxquelles le domaine résout au moment du scan, **mais ne couvre pas les IPs qui ne sont plus liées au domaine**.

Le scanner DNS dédié (`scanner-dns_records`, cf. change [`add-dns-records-scanner`](../../openspec/changes/add-dns-records-scanner/)) capture les enregistrements A/AAAA/MX/NS/TXT/CAA/SOA/CNAME du domaine, ce qui te permet d'avoir une vue complète des IPs derrière le domaine sans devoir les ajouter manuellement comme entrées de scope.

## Bonnes pratiques

1. **Commence petit**. Déclare une CIDR de test (`192.0.2.0/24` est officiellement réservé pour la doc) avant de pousser ton vrai périmètre.
2. **Documente chaque entrée**. Le champ `description` n'est pas indexé mais il est précieux pour l'audit ultérieur (« pourquoi avais-je ajouté ça ? »).
3. **Utilise des clés API scopées**. Une clé pour le bootstrap (`write:scopes`), une autre pour les agents IA en lecture (`read:scopes`, `read:hosts`, etc.). Cf. spec [`single-user-only`](../../openspec/changes/single-user-only/specs/mcp-server/spec.md) pour la matrice de scopes.
4. **Audit régulier**. Liste périodiquement les entrées actives :
   ```sh
   reconautctl scope list --json | jq '.scopes[] | select(.revoked_at == null)'
   ```
5. **Révoque proactivement**. Quand un actif est cédé, désaffecté, ou ne fait plus partie du périmètre, révoque l'entrée — sans attendre.

## Liens

- [`openspec/project.md`](../../openspec/project.md) — section *Positionnement* (Scope-driven).
- [`init-reconaut-platform/specs/scanning/spec.md`](../../openspec/changes/init-reconaut-platform/specs/scanning/spec.md) — Requirement *Scope Declaration and Enforcement*.
- [`responsibility-model.md`](../operating/responsibility-model.md) — modèle de responsabilité opérateur ↔ Reconaut.
- [`single-user-only/specs/mcp-server/spec.md`](../../openspec/changes/single-user-only/specs/mcp-server/spec.md) — matrice des scopes MCP.
