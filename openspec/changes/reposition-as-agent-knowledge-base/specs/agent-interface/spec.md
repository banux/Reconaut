# Spec delta : agent-interface

## MODIFIED Requirements

### Requirement: Semantic Search over Indexed Assets
L'agent conversationnel intégré ET les agents IA externes (Claude, GPT, agents maison) DOIVENT pouvoir interroger la **base de connaissance d'actifs** Reconaut via le pipeline de retrieval hybride (vector + graphe). Cette surface est la même qu'elle soit consommée :
- en interne par l'agent conversationnel (`agent_chat` MCP),
- en externe par un agent IA tiers qui invoque `search_hosts`, `get_host`, `agent_chat` ou tout autre outil MCP de lecture,
- en externe par un script ou un connecteur qui parse les réponses JSON.

La plateforme livre l'embedder pluggable (local in-process par défaut, Ollama, Mistral, OpenAI-compatible activables par variable d'environnement — cf. `init-reconaut-platform`) et le retrieval hybride (cf. `add-graph-retrieval`) comme **interface de la base de référence**, pas comme une feature isolée. Chaque résultat DOIT citer son enregistrement de scan source (`host_id`, `scanned_at`, `source`) pour que l'agent ou l'utilisateur vérifie la provenance et puisse distinguer données auto-collectées vs données ingérées.

#### Scenario: Agent IA externe consomme la base via MCP
- **GIVEN** un agent IA externe (par ex. un orchestrateur Claude) avec une clé API scopée `read:hosts` + `agent:chat`
- **WHEN** l'agent invoque `agent_chat({"prompt": "résume les services Modbus exposés"})` via MCP
- **THEN** le pipeline hybride répond en streaming avec citations `(host_id, scanned_at, source)`
- **AND** l'agent peut chaîner des appels `get_host(host_id)` pour expanser chaque résultat sans repasser par l'embedder

#### Scenario: La provenance distingue données internes et ingérées
- **GIVEN** la base contient des hôtes auto-collectés (workers Go internes, `source=internal`) ET des hôtes ingérés (par ex. `source=nmap`)
- **WHEN** un client invoque `search_hosts` avec une requête qui retourne les deux
- **THEN** chaque résultat porte son champ `source` (ou la liste de sources si plusieurs)
- **AND** un test confirme qu'un hôte ingéré seulement a `source=["nmap"]` et un hôte connu des deux côtés a `source=["internal", "nmap"]`
