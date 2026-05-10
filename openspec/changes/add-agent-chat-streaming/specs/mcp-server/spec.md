# Spec delta : mcp-server

## ADDED Requirements

### Requirement: Agent Chat SSE Heartbeat
La plateforme DOIT émettre un événement SSE `ping` toutes les `RECONAUT_AGENT_CHAT_HEARTBEAT_S` secondes (défaut 15 s) pendant l'exécution d'un appel `agent_chat` streamé, afin d'éviter les timeouts intermédiaires (reverse proxy, load balancer, navigateur) et la fermeture des connexions inactives.

Le ping DOIT respecter ces contraintes :

- Format : `event: ping\ndata: {}\n\n` (SSE conforme).
- Pas de donnée applicative : un client qui ne sait pas dispatcher `event: ping` DOIT pouvoir l'ignorer sans erreur.
- Émis uniquement pendant la phase de retrieval ; cesse dès que `done` (ou `client_gone`) est émis.
- Ne perturbe PAS l'ordre des chunks `start → row* → done` : le ping est un événement séparé qui peut s'intercaler entre des `tool_result`.
- Configurable à 0 = désactivé (déploiement en réseau strictement local sans proxy lent).

#### Scenario: Heartbeat émis pendant un retrieval lent
- **GIVEN** une instance avec `RECONAUT_AGENT_CHAT_HEARTBEAT_S=1` et un retriever qui prend 2,5 s à répondre
- **WHEN** un client appelle `POST /mcp/tools/agent_chat` avec `Accept: text/event-stream`
- **THEN** le client reçoit au moins **1** événement `event: ping` avant le premier `tool_result` payload `start`
- **AND** la séquence finale contient les chunks attendus (`start`, `row`*, `done`) plus les `ping` intercalés

#### Scenario: Heartbeat désactivé via env=0
- **GIVEN** `RECONAUT_AGENT_CHAT_HEARTBEAT_S=0` et un retriever qui prend 2,5 s
- **WHEN** un client streame
- **THEN** **aucun** événement `ping` n'est émis
- **AND** la séquence est identique au comportement actuel (start → row* → done)

#### Scenario: Heartbeat ignorable côté client
- **GIVEN** un client SSE qui s'abonne uniquement à `event: tool_result`
- **WHEN** le serveur émet alternativement `tool_result` et `ping`
- **THEN** le client reçoit tous les `tool_result` dans l'ordre attendu et n'est pas perturbé par les `ping`

### Requirement: Agent Chat Cancellation Propagation
La plateforme DOIT détecter la fermeture de la connexion client pendant un appel `agent_chat` streamé et arrêter d'écrire des chunks. La cancellation est passive — le retrieval en cours n'est PAS interrompu activement, mais aucun chunk n'est plus émis et la requête est journalisée comme `client_gone`.

Le contrat :

- Avant chaque `response.stream.write`, le serveur DOIT vérifier `response.stream.closed?`.
- Si fermé, la boucle d'émission DOIT sortir proprement sans lever d'erreur côté logs (au pire un `info`, pas un `error`).
- Une ligne d'audit DOIT être écrite avec `params_normalized.outcome = "client_gone"` (vs `"completed"` pour un retrieval normal).
- Le retriever en cours (embedder + DB) continue jusqu'à son terme — la cancellation active relève d'un futur `add-cancellable-embedder` (cf. proposal).
- Le thread heartbeat (cf. requirement précédent) DOIT être annulé via `Thread#kill` au plus tard quand le `ensure response.stream.close` du controller s'exécute.

#### Scenario: Client ferme la connexion en plein retrieval
- **GIVEN** un retriever qui prend 3 s à répondre et un client qui ferme la connexion après 1 s
- **WHEN** le client coupe la TCP
- **THEN** au prochain heartbeat OR write, le serveur détecte `closed?` et sort de la boucle d'émission
- **AND** une ligne d'audit existe avec `outcome=client_gone`
- **AND** aucune erreur `Errno::EPIPE` ou `IOError` ne remonte dans les logs Rails (rattrapée silencieusement)

#### Scenario: Thread heartbeat libéré proprement après client_gone
- **GIVEN** un client qui se déconnecte mid-retrieval
- **WHEN** le serveur détecte la déconnexion
- **THEN** le thread qui pousse les pings est `kill`-é avant le retour de la requête
- **AND** un test `ObjectSpace.each_object(Thread).count` avant/après ne révèle pas de thread orphelin

### Requirement: Optional Progressive Row Emission
Le pipeline `Agent::HybridRetriever` PEUT exposer une méthode `each_chunk(query) { |chunk| ... }` qui yield les chunks progressivement (au lieu de produire un `Response` complet). Quand cette méthode est implémentée, le controller `Mcp::ToolsController#stream_agent_chat!` DOIT l'utiliser et écrire chaque chunk dès réception.

Quand le retriever **n'implémente pas** `each_chunk`, le controller DOIT retomber sur le comportement actuel : appel synchrone à `call(query)` puis chunkage post-hoc via `Mcp::AgentChatStreamer.chunks_for(response)`. Aucun retriever existant ne DOIT être cassé par l'introduction de ce contrat optionnel.

#### Scenario: Retriever implémente each_chunk → utilisation de la voie progressive
- **GIVEN** un retriever fictif `StreamingRetriever` qui yield `{type: "row", row: ...}` toutes les 100 ms pour 5 rows
- **WHEN** le client streame `POST /mcp/tools/agent_chat`
- **THEN** le client reçoit le 1er `tool_result` row dans la 1ère 200 ms (avant que les 4 autres soient produits)
- **AND** la trace temporelle des 5 rows reçus côtoie ~100 ms d'écart entre chacun

#### Scenario: Retriever sans each_chunk → fallback post-hoc inchangé
- **GIVEN** un retriever historique qui n'implémente que `call`
- **WHEN** un client streame
- **THEN** le comportement reste celui livré par `mcp-as-primary-entrypoint` : `call(query)` synchrone puis `Mcp::AgentChatStreamer.chunks_for` puis émission séquentielle des chunks
- **AND** aucune ligne n'est différente côté ordre des chunks (`start → row* → done`)

### Requirement: Audit Log Includes Streaming Outcome
La ligne d'audit pour un appel `agent_chat` streamé DOIT inclure dans `params_normalized` le champ `streaming: true` et le champ `outcome` ∈ {`completed`, `client_gone`}. Pour un appel `agent_chat` non streamé (réponse JSON simple), aucun de ces champs n'est ajouté.

#### Scenario: agent_chat streamé complète → audit `outcome=completed`
- **GIVEN** un client qui consomme tout le stream jusqu'au `done`
- **WHEN** le serveur a émis `done` et fermé le stream
- **THEN** l'entrée d'audit existe avec `template_id=mcp:agent_chat`, `params_normalized={streaming: true, outcome: "completed"}`, `duration_ms` ≥ retrieval time

#### Scenario: agent_chat non streamé (JSON simple) → audit sans champ streaming
- **GIVEN** un client qui appelle sans `Accept: text/event-stream` ni `?stream=1`
- **WHEN** le serveur retourne une réponse JSON unique
- **THEN** l'entrée d'audit existe sans champ `streaming` ni `outcome` (compatible avec les audits historiques)
