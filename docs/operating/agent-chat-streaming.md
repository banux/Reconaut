# Streaming SSE de `agent_chat`

Statut : **stable**.
Audience : opérateur qui consomme `POST /mcp/tools/agent_chat` depuis la TUI ou un agent IA externe.

L'outil MCP `agent_chat` accepte deux modes :

- **JSON unique** (défaut) : un POST classique retourne un objet JSON complet.
- **Streaming SSE** : le serveur émet des événements `tool_result` au fur et à mesure, plus des `ping` keep-alive pour éviter les timeouts intermédiaires.

## Activer le streaming

Ajoute un header `Accept: text/event-stream`, ou bien le query param `?stream=1` :

```sh
curl -N -X POST http://localhost:3000/mcp/tools/agent_chat \
  -H "Authorization: Bearer $RECONAUT_API_KEY" \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream" \
  -d '{"prompt":"modbus exposés en France"}'
```

Le `-N` (no buffering) côté curl est important — sinon curl bufferise tout le flux.

## Format des événements émis

### `event: tool_result`

Trois sous-types via `result.type` :

```
event: tool_result
data: {"tool":"agent_chat","partial":true,"result":{"type":"start","retrieval_path":"hybrid","duration_ms":12}}

event: tool_result
data: {"tool":"agent_chat","partial":true,"result":{"type":"row","row":{"host_id":"h1","scanned_at":"2026-05-01"},"citation":{"host_id":"h1","scanned_at":"2026-05-01","source":"vector"}}}

event: tool_result
data: {"tool":"agent_chat","partial":false,"result":{"type":"done","warnings":[],"total_rows":1}}
```

L'ordre est garanti :

1. **Exactement un** `start` au début (avec `retrieval_path` et `duration_ms`).
2. **Zéro ou plus** `row` (un par résultat, chacun avec sa `citation`).
3. **Exactement un** `done` à la fin (avec `warnings` et `total_rows`).

`partial: true` sur tous les chunks sauf le `done`. Permet à un consommateur générique de savoir quand fermer son buffer.

### `event: ping`

```
event: ping
data: {}
```

Émis toutes les `RECONAUT_AGENT_CHAT_HEARTBEAT_S` secondes (défaut 15) pendant l'exécution du retrieval. **Un consommateur DOIT ignorer ces événements** — ils ne portent aucune donnée applicative. Les SDK SSE qui ne s'abonnent qu'à `event: tool_result` n'ont rien à faire ; les SDK qui dispatchent par défaut (ex. `EventSource` dans le navigateur) doivent filtrer explicitement.

But : empêcher les reverse proxies (cloudflare, nginx, ALB) de fermer une connexion qu'ils croient inactive. Sans ping, un retrieval qui dépasse 60 s sur un proxy strict serait fermé avant le premier chunk.

## Configuration côté serveur

| Variable                              | Défaut | Effet                                                         |
|---------------------------------------|--------|---------------------------------------------------------------|
| `RECONAUT_AGENT_CHAT_HEARTBEAT_S`     | `15`   | Intervalle entre pings. `0` = désactivé.                      |
| `RECONAUT_EMBEDDER_TIMEOUT_S`         | `2.5`  | Timeout du retrieval (cf. `add-embedder-pluggable`).           |

## Comportement de cancellation

Si le client ferme la TCP en plein retrieval (Ctrl-C dans la TUI, navigateur fermé), le serveur :

1. Détecte `response.stream.closed?` au prochain write (au plus tard au prochain ping).
2. Sort de la boucle d'émission silencieusement (pas de log d'erreur).
3. Écrit une ligne d'audit avec `params_normalized.outcome = "client_gone"`.
4. Le retrieval EN COURS continue jusqu'à son terme côté backend (embedder + DB) — la cancellation est passive en v1.

Si tu veux interrompre activement le retrieval embedder (économiser quota Mistral), c'est différé à `add-cancellable-embedder`.

## Bonnes pratiques pour SDK consommateurs

1. **Ignorer `event: ping`**. La plupart des SDK SSE (curl, EventSource, Go `bufio.Scanner`) les laissent passer naturellement si tu ne t'abonnes qu'à `tool_result`.
2. **Buffer sur `partial: false`**. Un consommateur générique peut accumuler les chunks `row` jusqu'au `done` pour reconstituer la `Response` complète. C'est exactement ce que fait `Mcp::AgentChatStreamer.chunks_for` côté inverse.
3. **Reconnecter sur déconnexion** : pas de support `Last-Event-Id` en v1 — relance la requête depuis zéro. Différé à `add-sse-resume`.
4. **Timeout côté client** : aligne ton timeout client sur `RECONAUT_AGENT_CHAT_HEARTBEAT_S * 2` au minimum, sinon tu coupes la connexion entre deux pings sur un retrieval qui ne produit aucun row.

## Émission progressive vs post-hoc chunking

En v1, deux comportements coexistent selon l'implémentation du retriever câblé :

- **Retriever standard `Agent::HybridRetriever`** : retrieval synchrone complet, puis chunkage post-hoc via `Mcp::AgentChatStreamer.chunks_for`. Du point de vue client, tous les `row` arrivent presque simultanément à la fin du retrieval. Le bénéfice du streaming est limité aux pings keep-alive et à la cancellation.
- **Retriever override `each_chunk(query)`** : le retriever yield directement les chunks au fur et à mesure de leur production. Du point de vue client, les `row` arrivent espacés dans le temps, à la cadence où le retrieval les produit. Cas d'usage : retrievers multi-step, agents LLM qui génèrent du texte token-par-token.

Le contrat `each_chunk` est documenté dans `app/lib/agent/hybrid_retriever.rb`. Override la méthode pour passer en mode progressif.

## Liens

- `openspec/changes/add-agent-chat-streaming/` — change qui livre heartbeat + cancellation + each_chunk.
- `openspec/changes/mcp-as-primary-entrypoint/specs/mcp-server/spec.md` — spec parente (agent_chat streaming).
- `apps/api/app/lib/mcp/agent_chat_streamer.rb` — découpage en chunks.
- `apps/api/app/lib/mcp/agent_chat_heartbeat.rb` — thread heartbeat.
