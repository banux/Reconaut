# Utiliser `reconautctl`

Statut : **stable**.
Audience : opérateur Reconaut qui veut piloter une instance depuis sa ligne de commande.

`reconautctl` est la TUI Go officielle. Elle parle à Reconaut via **MCP HTTP+SSE** pour toutes les opérations métier ; seul le login bootstrap (`POST /auth/sessions`) utilise REST — c'est le seul moment où tu n'as pas encore de clé API à présenter. Cf. [architecture mcp-first](../architecture/mcp-first.md) et [bootstrap auth](../architecture/auth-bootstrap.md).

## Installation

Pré-requis : Go 1.23+ et une instance Reconaut joignable.

```sh
cd apps/tui
go build -o reconautctl ./cmd/reconautctl

# Optionnel : copie le binaire dans ton PATH
sudo install -m 0755 reconautctl /usr/local/bin/
```

Vérifie :

```sh
./reconautctl doctor
```

## Variables d'environnement

| Variable                  | Défaut                       | Rôle                                                     |
|---------------------------|------------------------------|----------------------------------------------------------|
| `RECONAUT_URL`            | `http://localhost:3000`      | URL de base de l'instance Rails.                          |
| `RECONAUT_PASSWORD`       | _(requis pour `login`)_      | Mot de passe opérateur — utilisé une seule fois au login. |
| `RECONAUT_API_KEY`        | _(rempli par `login`)_       | Token Bearer pour les appels MCP authentifiés.            |

Après `login`, la clé API est persistée sous `~/.config/reconaut/credentials` (mode 0600, dossier 0700). Tu n'as plus besoin de poser `RECONAUT_API_KEY` à la main — `reconautctl` lit le fichier au démarrage.

## Premier démarrage (5 minutes)

1. **Lance Reconaut** : `cd apps/api && bundle exec rails server`. Un guide `docker-compose` viendra avec le change `add-helm-chart`.
2. **Bootstrap le mot de passe opérateur** (côté Rails) :
   ```sh
   cd apps/api
   RECONAUT_OPERATOR_PASSWORD='changeme' bundle exec rails reconaut:set_password
   ```
3. **Login depuis la TUI** :
   ```sh
   RECONAUT_URL=http://localhost:3000 \
   RECONAUT_PASSWORD='changeme' \
     ./reconautctl login
   # → "logged in as <user_id>"
   # → clé persistée sous ~/.config/reconaut/credentials
   ```
4. **Vérifie la santé** :
   ```sh
   ./reconautctl doctor
   # → JSON avec checks AGE, embedder_health, mcp_tls_posture, etc.
   ```

À partir d'ici, plus besoin de re-poser `RECONAUT_PASSWORD` ni `RECONAUT_API_KEY` — la TUI lit le fichier.

## Sous-commandes

```
reconautctl <command> [args...]

  login                          Échange password contre clé API persistée
  scope    list                  Liste les entrées de scope actives
  scope    add <kind> <value>    Ajoute une entrée : cidr | domain | host | ip
  scope    revoke <scope_id>     Révoque une entrée (append-only, pas de delete)
  scan     list                  Liste les scans connus (récents d'abord)
  scan     request <kind> <target_kind> <target_value>
                                 Demande un scan : tcp_probe | dns_records |
                                 service_fingerprint | http_banner | ...
  scan     status <scan_id>      État courant d'un scan
  hosts    search <query>        Recherche les hosts (lecture seule)
  hosts    get <host_id>         Détail d'un host
  agent    <prompt>              Pose une question en langage naturel via SSE
  doctor                         Imprime le rapport de self-check
```

Toutes les commandes (sauf `login`) passent par `POST /mcp/tools/<name>` avec le header `Authorization: Bearer $RECONAUT_API_KEY`. Le linter [`check_tui_mcp_only.sh`](https://github.com/banux/Reconaut/blob/main/scripts/check_tui_mcp_only.sh) garantit cet invariant à chaque PR.

## Déclarer son scope

Reconaut **refuse en dur** de scanner ce qui n'est pas dans le scope (cf. [`scope.md`](scope.md) pour le détail).

```sh
# Ajoute un CIDR (toute IP dans le réseau)
./reconautctl scope add cidr 192.0.2.0/24

# Ajoute un domaine (le FQDN exact — pas les sous-domaines en v1)
./reconautctl scope add domain esiea.fr

# Ajoute un host (FQDN exact)
./reconautctl scope add host mail.esiea.fr

# Liste l'état courant
./reconautctl scope list

# Révoque une entrée par son id (append-only ; la ligne reste en table pour l'audit)
./reconautctl scope revoke 7b3c8f2e-...
```

Trois `kind` valides : `cidr`, `domain`, `host` (les valeurs `ip` envoyées en `scan request` sont normalisées vers le `kind` approprié côté serveur — pas besoin de scope `ip` dédié).

## Demander un scan

```sh
# Scan TCP/443 d'une IP
./reconautctl scan request tcp_probe ip 192.0.2.10

# Scan HTTP banner sur un domaine (couvre HTTP et HTTPS via ALPN)
./reconautctl scan request http_banner domain esiea.fr

# Scan SSH (capture banner + host-key SHA-256, ZÉRO tentative d'auth)
./reconautctl scan request service_fingerprint ip 192.0.2.10

# Scan DNS records (A, AAAA, MX, NS, TXT, CAA, SOA, CNAME) — pas d'AXFR
./reconautctl scan request dns_records domain esiea.fr

# Liste les scans demandés
./reconautctl scan list

# Suis l'état d'un scan particulier
./reconautctl scan status scan-2026-05-11-1200-abc123
```

Les scans sont **asynchrones**. La TUI te rend la main immédiatement avec un `scan_id` ; un worker Go consomme la file GoodJob et ingère les résultats. Cf. [`scan-frontier.md`](../architecture/scan-frontier.md) pour le détail du pipeline Rails ↔ Go.

`scan_kind` disponibles en v1 (cf. [`reference/mcp-tools.md`](../reference/mcp-tools.md)) :

- `tcp_probe` — sondage TCP/port-list, ports ouverts/fermés.
- `tls_capture` — capture du certificat TLS sur n'importe quel port TLS-able.
- `http_banner` — HTTP(S) banner, headers, Server, body 32 KiB, ALPN, cert (HTTPS).
- `subdomain_enum` — énumération de sous-domaines (passive, sources publiques).
- `service_fingerprint` — couvre SSH (banner + host-key SHA-256, sans auth).
- `dns_records` — résolution A/AAAA/MX/NS/TXT/CAA/SOA/CNAME.

Hors scope cible → réponse 200 `{ok: false, error: "out-of-scope"}` ; **zéro paquet réseau** émis.

## Chercher dans la connaissance

Deux surfaces :

### Recherche lexicale (rapide, déterministe)

```sh
# Recherche par chaîne dans hosts.ip et hosts.fqdn
./reconautctl hosts search esiea

# Détail d'un host par id UUID
./reconautctl hosts get 7b3c8f2e-aa11-...
```

### Recherche sémantique en langage naturel (SSE streamé)

```sh
./reconautctl agent "liste les hosts qui exposent un service modbus en France"
./reconautctl agent "quels FQDN sont apparus dans les 7 derniers jours"
```

Le serveur émet des événements SSE `tool_result` au fur et à mesure : un `start` puis des `row` puis un `done`. Pendant un retrieval long, des `ping` keep-alive sont émis toutes les 15 s (cf. [`agent-chat-streaming.md`](../operating/agent-chat-streaming.md)). La TUI les consomme et imprime chaque chunk au format `[type] {json...}`.

**Qualité sémantique** : dépend du provider d'embedding configuré côté Rails (cf. [`embedder-providers.md`](../operating/embedder-providers.md)). Le défaut `local` est un encodage déterministe **sans sens sémantique** — utile pour valider la plomberie, pas pour la recherche réelle. Bascule sur `ollama` / `mistral` / `openai-compatible` pour de vraies réponses sémantiques.

## Doctor : self-check

```sh
./reconautctl doctor
```

Imprime un JSON avec des checks :

```json
{
  "ok": true,
  "checks": [
    { "name": "graph_tier",         "status": "ok" },
    { "name": "data_residency",     "status": "info", "details": "self-hosted" },
    { "name": "mcp_tls_posture",    "status": "info", "details": "mcp.tls.required=false posture=internal" },
    { "name": "embedder_health",    "status": "info", "details": {"provider":"local","dim":384,"circuit_state":"closed","failures_total":0} },
    { "name": "embedding_pipeline", "status": "info", "details": {"indexed_hosts":42,"total_hosts":50,"ratio":0.84,"last_indexed_at":"..."} },
    { "name": "auth_storage",       "status": "info", "details": {"backend":"active_record","users":1,"api_keys_active":3} }
  ]
}
```

`ok: false` ⇒ au moins un check en `:fail` — l'opérateur doit agir. `status: :info` est purement informatif, jamais bloquant.

## Streaming via SSE : exemples curl

Si tu veux contourner la TUI (intégration avec un agent IA externe, debugging) :

```sh
# JSON unique
curl -X POST http://localhost:3000/mcp/tools/agent_chat \
  -H "Authorization: Bearer $RECONAUT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"modbus exposés en France"}'

# SSE streamé (avec heartbeat keep-alive)
curl -N -X POST http://localhost:3000/mcp/tools/agent_chat \
  -H "Authorization: Bearer $RECONAUT_API_KEY" \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream" \
  -d '{"prompt":"modbus exposés en France"}'
```

Cf. [`agent-chat-streaming.md`](../operating/agent-chat-streaming.md) pour le format SSE complet.

## Troubleshooting

### `401 invalid_credentials` au `login`

Le mot de passe ne matche pas. Vérifie côté Rails :

```sh
cd apps/api && bundle exec rails runner '
puts "users: #{Reconaut::Auth::ArUser.count}"
puts "first user: #{Reconaut::Auth::ArUser.first&.email}"
'
```

Si `users: 0` → rejoue `reconaut:set_password`. Si l'email diffère → rotation password :

```sh
RECONAUT_ROTATE=true RECONAUT_OPERATOR_PASSWORD='nouveau' bundle exec rails reconaut:set_password
```

La rotation révoque AUSSI toutes les clés API existantes — tu devras `login` à nouveau.

### `426 Upgrade Required` au `scope list` / `agent` / ...

Le serveur Rails refuse les connexions en clair (posture TLS internet-facing). Soit tu termines TLS en amont (reverse proxy + header `X-Forwarded-Proto: https`), soit en dev :

```sh
RECONAUT_MCP_TLS_REQUIRED=false bundle exec rails server
```

Cf. [`init-reconaut-platform §5.5`](https://github.com/banux/Reconaut/blob/main/openspec/changes/init-reconaut-platform/tasks.md). Depuis le commit `8b957d0`, le défaut est permissif en `Rails.env.development?` — tu ne devrais pas hitter ça en dev local.

### `404 unknown_tool` sur `agent_chat`

Le pipeline d'embedding n'est pas câblé au boot Rails. Causes possibles :

- Extension pgvector pas installée (`CREATE EXTENSION vector;` dans Postgres).
- Table `embeddings` absente (`bundle exec rails db:migrate`).
- L'initializer `agent_pipeline.rb` a échoué silencieusement — cherche `[agent] pipeline not wired` dans les logs Rails.

Workaround : la TUI continue de tourner ; les autres outils MCP (`scope`, `scan`, `hosts search`, `doctor`) marchent indépendamment du retriever.

### `agent` retourne `total_rows: 0` toujours

Aucun host n'est indexé. Vérifie :

```sh
./reconautctl doctor | jq '.checks[] | select(.name == "embedding_pipeline")'
```

Si `total_hosts: 0` → la base est vide. Ingère des hosts via `scan request` (mais ça exige un worker Go qui consomme la file et écrit dans `hosts`) ou directement via `rails runner` pour smoke test.

Si `total_hosts > 0` et `indexed_hosts < total_hosts` → backfill :

```sh
cd apps/api && bundle exec rails reconaut:reindex
```

Cf. [`embedding-pipeline.md`](../operating/embedding-pipeline.md).

### `scope add domain ...` retourne 400

Vérifie que `<kind>` est l'un des 3 acceptés : `cidr`, `domain`, `host`. La valeur `ip` au `scope add` n'est pas valide directement — utilise `cidr` avec un masque /32 (`cidr 192.0.2.10/32`).

### `scan request tcp_probe ip ...` retourne `out-of-scope`

L'IP cible n'est pas couverte par une entrée de scope active. Ajoute d'abord un `cidr` qui la contient, par ex. `scope add cidr 192.0.2.0/24`.

## Liens

- [Modèle scope-driven](scope.md) — pourquoi le refus en dur hors scope est l'invariant central.
- [Architecture MCP-first](../architecture/mcp-first.md) — pourquoi tout passe par MCP HTTP+SSE.
- [Bootstrap auth](../architecture/auth-bootstrap.md) — pourquoi `/auth/*` reste REST.
- [Streaming agent_chat](../operating/agent-chat-streaming.md) — format SSE détaillé + heartbeat + cancellation.
- [Providers d'embedding](../operating/embedder-providers.md) — local / Ollama / Mistral / OpenAI-compatible.
- [Pipeline d'embedding](../operating/embedding-pipeline.md) — comment les hosts deviennent recherchables.
- [Référence outils MCP](../reference/mcp-tools.md) — liste exhaustive auto-générée.
