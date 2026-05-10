# Change : add-agent-chat-streaming

## Pourquoi

Le tool MCP `agent_chat` exposé via `POST /mcp/tools/agent_chat` supporte déjà le format SSE (`text/event-stream`) — `Mcp::AgentChatStreamer` découpe la `Agent::HybridRetriever::Response` en chunks `start → row* → done` et `Mcp::ToolsController#stream_agent_chat!` les pousse au client. Cette plomberie a été livrée par `mcp-as-primary-entrypoint`. Mais l'implémentation est **post-hoc** : le retriever produit la réponse entière en synchrone, puis le controller chunk le résultat AVANT de commencer à écrire dans le stream. Du point de vue du client, le premier byte arrive après la latence totale du retrieval — l'apparence de progressivité est cosmétique.

Trois trous concrets que ce change ferme :

1. **Pas de heartbeat.** Quand l'embedder externe (Mistral, Ollama) prend 1-2 s, le stream reste muet jusqu'à la fin. Reverse proxies (nginx, Cloudflare, ALB) ferment souvent les connexions inactives après 30-60 s ; certains middlewares Rack tamponnent les bytes jusqu'au flush. Sur un cluster lent ou un provider qui ralentit, le client reçoit une connexion fermée avant le premier chunk.
2. **Pas de cancellation propagation.** Quand l'opérateur ferme `reconautctl agent-chat` (Ctrl-C) en plein retrieval, le serveur continue à tourner — embed → DB queries → render → write to a closed stream. C'est du gaspillage (quota Mistral consommé inutilement) et un risque de fuite (handle de connexion non libéré jusqu'au timeout).
3. **Pas de progressive row emission.** Les rows sont chunkées post-hoc ; un retrieval qui produit 50 rows en 2 s aurait pu en montrer 10 dès la 500ème ms. Bénéfice modeste pour le pattern search-and-cite de Reconaut, mais l'infrastructure permet de le débloquer pour des futurs use cases (résumé LLM, agent multi-step).

## Ce qui change

1. **Heartbeat SSE** : pendant un retrieval long, le serveur émet `event: ping\ndata: {}\n\n` toutes les 15 s par défaut (`RECONAUT_AGENT_CHAT_HEARTBEAT_S`). Le ping est un keep-alive pur — il ne contient pas de donnée applicative et le client doit l'ignorer (les SDK SSE ignorent par défaut les événements qu'ils ne savent pas dispatcher). Implémentation via un thread observateur qui pousse les pings tant que le retrieval n'est pas terminé.

2. **Cancellation propagation** : avant chaque `response.stream.write`, le controller vérifie `response.stream.closed?`. Si fermé, il lève `ClientGoneError` qui est rattrapée silencieusement (audit recordé, pas d'erreur logguée bruyamment). La détection arrive APRÈS le premier write tenté — mais comme le heartbeat émet régulièrement, le client gone est détecté en moins de 15 s. Une détection plus précoce (TCP RST avant la fin du retrieval) nécessiterait `Rack::Hijack`, hors scope.

3. **Émission progressive des rows** : nouveau contrat optionnel sur `Agent::HybridRetriever` — `each_chunk(query) { |chunk| ... }`. Quand implémenté, le controller boucle sur les chunks émis et écrit immédiatement. L'implémentation par défaut continue à appeler `call(query)` puis chunker post-hoc (équivalent au comportement actuel). Le `Reconaut::HybridRetriever` réel sera migré progressivement vers le mode `each_chunk` natif dans des changes ultérieurs (`add-streaming-retriever`).

4. **Audit et stats** : la ligne d'audit pour un agent_chat streamé est écrite **à la FIN** (après `done` ou `client_gone`), avec un nouveau champ `params_normalized.streaming = true`. Le `duration_ms` reflète le temps total du stream, pas seulement le retrieval. Le check `embedder_health` du doctor (livré par `add-embedder-pluggable`) reste inchangé — la cancellation ne touche pas au circuit breaker (un client gone n'est pas un échec embedder).

5. **Documentation client** : nouveau `docs/operating/agent-chat-streaming.md` qui explique le format des chunks `start/row/done/ping`, le comportement de cancellation, et les bonnes pratiques pour les SDK consommateurs (TUI, agent IA externe).

## Contraintes

- **Pas de réintroduction de `POST /agent/chat`**. Le canal canonique reste `POST /mcp/tools/agent_chat` (cf. `mcp-as-primary-entrypoint`). Le linter `check_rest_allowlist.sh` reste vert.
- **Compatible avec les clients existants**. Les SDK qui ignorent `event: ping` (comportement par défaut de la plupart des bibliothèques SSE) ne voient aucun changement de comportement. La TUI Go (`apps/tui/cmd/reconautctl`) qui consomme les chunks `tool_result` continue de fonctionner sans modification.
- **Pas de ressource leak**. Le thread heartbeat est annulé proprement via `Thread#kill` quand le stream se ferme (succès ou cancellation). Les `Timeout` autour de l'embedder restent strictes (cf. `add-embedder-pluggable` §2.4).
- **Pas de dépendance externe**. Pas de `actioncable`, pas de `eventmachine`. On utilise `ActionController::Live` + un `Thread` simple. Le linter `check_no_billing.sh` reste vert.
- **Pas de breaking change sur l'interface `Agent::HybridRetriever`**. La méthode `call` reste obligatoire ; `each_chunk` est optionnelle, default = wrapper autour de `call`.
- **Pas de cancellation forcée du retrieval lui-même**. Le retrieval est interrompu *passivement* : on cesse d'écrire et on quitte la boucle. Si l'embedder externe est en plein appel HTTP, on attend son timeout (2.5 s par défaut). Une cancellation active (interrompre la requête HTTP en cours) nécessite des changements dans `Reconaut::Embedder::*`, hors scope.

## Non-objectifs (hors scope de ce change)

- **Cancellation active du retriever** — interrompre une requête HTTP embedder en cours. Relève d'un futur `add-cancellable-embedder` qui devrait revoir l'interface `Embedder.embed` pour accepter un `cancellation_token`.
- **Streaming pour `search_hosts` et autres tools MCP** — `agent_chat` est l'unique tool qui bénéficie du streaming pour l'instant (search_hosts est rapide). Si d'autres tools deviennent lents, ils auront leur propre change.
- **Métriques Prometheus du streaming** (`agent_chat_chunks_emitted_total`, `agent_chat_client_gone_total`) — relève de `add-prometheus-metrics` quand le pipeline d'observabilité OTel sera en place.
- **Reconnexion automatique côté client** (header `Last-Event-Id`, replay) — le contrat actuel est best-effort : si le client se déconnecte, il refait la requête. Pas de checkpoint/resume.
- **Réintroduction d'un endpoint REST `/agent/chat`** — explicitement contraire à `mcp-as-primary-entrypoint`.

## Décisions prises

1. **`Thread` Ruby plutôt que `Fiber` ou `EventMachine`** pour le heartbeat. Un `Thread` simple suffit pour pousser un ping toutes les 15 s ; `Fiber` ajouterait de la complexité (cooperative scheduling) sans bénéfice ; `EventMachine` introduirait une nouvelle dépendance externe non justifiée.
2. **Heartbeat à 15 s par défaut**. Suffisamment court pour battre les défauts de cloudflare (100s) / nginx (60s) / ALB (60s) ; suffisamment long pour ne pas spammer le réseau (4 pings/min). Configurable via env pour les déploiements derrière des proxies plus stricts.
3. **Cancellation passive plutôt qu'active**. Le client qui ferme la connexion n'attend rien — `kill` du thread retriever serait correct mais introduit des risques (state corrompu côté embedder, transactions DB à demi). Mieux vaut laisser le retrieval finir silencieusement, juste ne pas écrire dans un stream fermé.
4. **`each_chunk` comme contrat additionnel optionnel**. Plutôt que de casser tous les retrievers existants pour un mode streaming, on rend le mode opt-in. Les retrievers qui n'implémentent pas `each_chunk` retombent automatiquement sur `call` + post-hoc chunking — comportement actuel.
5. **Audit log écrit à la fin du stream**. Cohérent avec le pattern existant (audit après `tool.call` complète). Ajout du champ `streaming: true` dans `params_normalized` permet de mesurer l'adoption sans changer le schéma audit_log.

## Différé (non bloquant, parqué pour plus tard)

- **`add-cancellable-embedder`** : signal de cancellation propagé jusqu'aux requêtes HTTP embedder en cours.
- **`add-streaming-retriever`** : `Reconaut::HybridRetriever` natif qui produit les rows progressivement (sans passer par un Response complet).
- **`add-prometheus-metrics`** : compteurs `agent_chat_chunks_emitted_total`, `agent_chat_client_gone_total`, `agent_chat_heartbeat_emitted_total`.
- **`add-sse-resume`** : support de `Last-Event-Id` pour reconnexions client après coupure réseau.
