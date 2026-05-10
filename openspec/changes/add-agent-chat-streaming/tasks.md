# Tâches : add-agent-chat-streaming

Checklist du heartbeat SSE + cancellation propagation + émission progressive optionnelle pour `POST /mcp/tools/agent_chat`. Chaque tâche inclut des notes d'implémentation et un test plan.

---

## 1. Heartbeat SSE

- [x] **1.1 Helper `Mcp::AgentChatHeartbeat`**
  - **Notes** : Nouveau fichier `apps/api/app/lib/mcp/agent_chat_heartbeat.rb`. Classe qui démarre un `Thread` qui pousse `event: ping\ndata: {}\n\n` toutes les `interval_s` secondes dans un IO writable. Méthode `start(stream:, interval_s:)` retourne le thread ; `stop(thread)` l'annule via `Thread#kill`. Si `interval_s == 0`, `start` retourne nil et aucun thread n'est créé (heartbeat désactivé).
    ```ruby
    module Mcp
      class AgentChatHeartbeat
        def self.start(stream:, interval_s:)
          return nil if interval_s.to_f <= 0

          Thread.new do
            loop do
              sleep interval_s
              break if stream.closed?
              stream.write("event: ping\ndata: {}\n\n")
            end
          rescue IOError, Errno::EPIPE
            # Stream fermé — sortie silencieuse.
          end
        end

        def self.stop(thread)
          return if thread.nil?
          thread.kill
          thread.join(0.1) # ne bloque pas si la kill rate
        end
      end
    end
    ```
  - **Test plan** : Spec dédiée `spec/lib/mcp/agent_chat_heartbeat_spec.rb` :
    - (a) avec `interval_s=0.1`, sleep 0.35 s, le stream a reçu ≥ 2 pings.
    - (b) avec `interval_s=0`, `start` retourne nil et aucun thread démarré.
    - (c) après `stop`, le thread est `dead`.
    - (d) si le stream est fermé pendant un sleep, le thread sort sans erreur.

- [x] **1.2 Variable d'env `RECONAUT_AGENT_CHAT_HEARTBEAT_S`**
  - **Notes** : Lue par `Mcp::ToolsController#stream_agent_chat!` (default 15). Cast en Float (admet `15.0`, `0.5`, etc.). Validée au boot dans le même initializer que les autres var MCP, sinon laisse passer (la valeur 0 = désactivé reste valide).
  - **Test plan** : Spec request avec `RECONAUT_AGENT_CHAT_HEARTBEAT_S=0.1` ; assure qu'un retriever lent émet ≥ 1 ping. Spec avec `=0` ; assure aucun ping.

- [x] **1.3 Câblage dans `Mcp::ToolsController#stream_agent_chat!`**
  - **Notes** : Wrapper autour de la boucle existante `chunks_for(...).each` :
    ```ruby
    heartbeat = Mcp::AgentChatHeartbeat.start(
      stream: response.stream,
      interval_s: Float(ENV.fetch("RECONAUT_AGENT_CHAT_HEARTBEAT_S", 15))
    )
    begin
      Mcp::AgentChatStreamer.chunks_for(reconstructed).each do |chunk|
        break if response.stream.closed?
        # ... existing write ...
      end
    ensure
      Mcp::AgentChatHeartbeat.stop(heartbeat)
      response.stream.close
    end
    ```
  - **Test plan** : Spec request qui consomme le stream et détecte `event: ping` dans le buffer reçu.

---

## 2. Cancellation propagation

- [x] **2.1 Détection de stream fermé dans la boucle d'émission**
  - **Notes** : Modifier la boucle `chunks_for(...).each do |chunk|` pour qu'elle vérifie `response.stream.closed?` avant chaque `write`. Si fermé, sortir proprement (`break`). Le rescue de `IOError, Errno::EPIPE` remonte autour du write par sécurité (en cas de race entre check et write).
  - **Test plan** : Spec qui simule un client qui ferme la connexion (via Rack::Test ou un thread qui `close` le stream après 100 ms) ; assure que le serveur détecte `closed?` et sort sans lever d'erreur.

- [x] **2.2 Audit `outcome` ∈ {completed, client_gone}**
  - **Notes** : `stream_agent_chat!` doit savoir si la boucle a complété ou été coupée. Variable locale `outcome = :completed`, set à `:client_gone` sur `break`. À la fin (dans le `ensure`), appel à `audit("invoke_streamed", "agent_chat", streaming: true, outcome: outcome)` qui ajoute les deux champs au `params_normalized`. La méthode `audit` actuelle accepte déjà un `params_normalized` Hash — il suffit de l'enrichir.
  - **Test plan** : Spec qui force la fermeture mid-stream ; assure que la dernière entrée `audit_recorder.entries.last[:params_normalized]` contient `streaming: true` ET `outcome: "client_gone"`. Spec inverse : consommation complète → `outcome: "completed"`.

- [x] **2.3 Pas de log error sur EPIPE / IOError**
  - **Notes** : Ces erreurs sont attendues quand le client part. Le `rescue` autour du write ne doit pas appeler `Rails.logger.error` — au plus un `Rails.logger.info("[agent_chat] client gone")` pour traçabilité.
  - **Test plan** : Spec qui force EPIPE (mock `response.stream.write` à raise) ; capture `Rails.logger` et assure qu'aucun `:error` level n'est écrit pour cette ligne.

---

## 3. Émission progressive optionnelle (each_chunk)

- [x] **3.1 Contrat `each_chunk` documenté + détection runtime**
  - **Notes** : `Mcp::ToolsController#stream_agent_chat!` détecte si le retriever (ou le retour du tool — il faudra plomber ça) répond à `each_chunk`. Si oui, appelle `retriever.each_chunk(query) { |chunk| ... }` et écrit chaque chunk en temps réel. Si non, retombe sur le code actuel (call + chunks_for). Le contrat n'oblige aucun retriever existant à changer.
  - **Test plan** : Spec qui injecte un fake retriever avec `each_chunk` qui yield 3 chunks à 100 ms d'intervalle. Mesure le timing de réception côté client (Rack::Test) ; assure ≥ 200 ms entre le 1er et le 3ème chunk.

- [x] **3.2 Implémentation par défaut sur `Agent::HybridRetriever`**
  - **Notes** : Ajouter `each_chunk(query, &blk)` au pipeline qui appelle `call(query)` puis yield les chunks de `AgentChatStreamer.chunks_for(response)`. Ainsi chaque retriever bénéficie du contrat sans implémentation spécifique. Les retrievers qui veulent un vrai streaming peuvent override.
  - **Test plan** : Spec sur `Agent::HybridRetriever` : `each_chunk("modbus")` yield ≥ 3 chunks (au moins start/row+done). L'ordre est garanti.

---

## 4. Documentation client

- [x] **4.1 Nouveau `docs/operating/agent-chat-streaming.md`**
  - **Notes** : Documentation opérateur du format SSE émis :
    - Format chunks `start | row | done | ping` avec exemples JSON.
    - Variable `RECONAUT_AGENT_CHAT_HEARTBEAT_S` (défaut 15, =0 pour désactiver).
    - Comportement de cancellation côté client (TCP close → audit `client_gone`).
    - Bonnes pratiques pour SDK (ignorer `event: ping`, rebrancher après TCP close).
  - **Test plan** : `grep -i "event: ping" docs/operating/agent-chat-streaming.md` retourne ≥ 1 match. Présence des 4 types de chunks documentés.

- [x] **4.2 Référence dans `docs/architecture/mcp-first.md`**
  - **Notes** : Ajouter une note dans la section streaming pointant vers le nouveau doc opérateur.
  - **Test plan** : `grep -i "agent-chat-streaming" docs/architecture/mcp-first.md` retourne ≥ 1 match.

---

## 5. Acceptance pour le change dans son ensemble

- [x] **5.1 Aucune régression**
  - Toute la suite RSpec actuelle (489 examples avant ce change) reste verte. Tests TUI Go (`apps/tui/.../subcommands_test.go::TestAgentChat_UsesMCPStreaming`) restent verts — le SDK consommateur ignore `event: ping`.
  - Tous les linters CI (`stack`, `rest_allowlist`, `tui_mcp_only`, `scanner_specialization`, `spdx_headers`, `ssh_probe_no_auth`, `no_billing`) restent verts.

- [x] **5.2 Test de bout-en-bout cancellation**
  - Spec d'intégration `spec/integration/agent_chat_streaming_spec.rb` qui :
    - (a) consomme un stream complet jusqu'au `done` → audit `outcome=completed`, ≥ 1 ping si retriever lent.
    - (b) ferme la TCP mid-stream → audit `outcome=client_gone`, pas d'erreur dans les logs.
    - (c) avec `each_chunk` → réception progressive des rows.

- [x] **5.3 Pas de fuite de threads**
  - Dans le spec, `before` capture `ObjectSpace.each_object(Thread).count` ; `after` re-capture et exige le même count (± 1 pour tolérer les threads internes Rails).
