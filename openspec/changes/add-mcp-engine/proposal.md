# Change : add-mcp-engine

## Pourquoi

`init-reconaut-platform` §5.1 demande un *Engine Rails dédié au MCP partageant la pile de middlewares (HTTP+SSE uniquement)* avec les outils `search_hosts`, `get_host`, `request_scan`, `get_scan_status`, `export_report` exposés comme controllers Rails. La spec précise « Engine **ou** namespace de routes » — la version actuelle a choisi le namespace (`scope "/mcp"`) et l'a livré progressivement (mcp-as-primary-entrypoint, single-user-only, add-agent-chat-streaming).

Quatre des cinq outils nommés sont câblés (`search_hosts`, `get_host`, `request_scan`, `get_scan_status`). **Le cinquième, `export_report`, manque** — c'est le bloqueur principal pour clore §5.1. Le test plan §5.1 exige aussi *un test additionnel qui assure qu'aucun binaire de la plateforme n'expose un point d'entrée stdio MCP (grep/scan d'imports)* — ce linter n'existe pas encore.

Trois trous concrets que ce change ferme :

1. **`export_report` n'existe pas.** Aucun moyen d'exporter le scope/hosts/services/scans pour audit, conformité, ou échange avec un outil externe (SIEM, tableur). La spec parente impose 3 formats : JSON, CSV, STIX2.1.
2. **Pas de linter anti-stdio MCP.** Reconaut a délibérément exclu le transport stdio (cf. project.md) au profit de HTTP+SSE — mais aucune garde mécanique ne vérifie qu'un futur change ne réintroduit pas un point d'entrée stdio (par exemple via la gem `mcp-rb` qui supporte les deux).
3. **§5.1 n'est pas tickable** sans (1) et (2). Le change le clôt proprement.

## Ce qui change

1. **Outil MCP `export_report`** : `(filter:, format:)` → `{download_url, token, expires_at}`. Le filtre accepte `kind: "scope" | "hosts" | "services" | "scans"` et un `limit` optionnel (défaut 1000, max 10000). Le format ∈ `{json, csv, stix2}` (spec parente). Le serveur génère le fichier sous `tmp/exports/<uuid>.<ext>` (chemin configurable via `RECONAUT_EXPORT_DIR`), retourne une URL signée à 1 heure et un token HMAC-SHA256.

2. **Module `Reconaut::Exporter`** : sérialise les data en JSON, CSV, STIX2.1.
   - **JSON** : un tableau plat des records.
   - **CSV** : RFC4180, 1 ligne par record, première ligne = headers.
   - **STIX2** : un `bundle` STIX2.1 minimal — chaque host devient un `observed-data` SCO `ipv4-addr` ou `domain-name` ; chaque service devient un `network-traffic`. Pas de mapping STIX2 complet (objets `indicator`, `relationship`, etc.) — différé à `add-stix2-full-mapping`.

3. **Route `GET /mcp/exports/:id`** : nouvelle route sous `/mcp/*` (passe l'allowlist REST cf. `mcp-as-primary-entrypoint`). Le controller `Mcp::ExportsController#download` vérifie le token HMAC, streame le fichier, puis le supprime (téléchargement one-shot). Si le token est invalide ou expiré → 404 (plutôt que 401, pour ne pas leaker l'existence du fichier).

4. **Linter `check_no_mcp_stdio.sh`** : refuse tout import d'une lib MCP qui exposerait un transport stdio (`mcp-rb` avec mode stdio, `python-mcp` stdio, etc.) ainsi que toute occurrence de patterns explicites comme `MCP::Stdio`, `STDIO_TRANSPORT`, `--stdio`. Wired dans le job `stack-lint` de la CI.

5. **Test système `tools_spec.rb` étendu** : exerce chacun des 5 tools listés dans §5.1 (`search_hosts`, `get_host`, `request_scan`, `get_scan_status`, `export_report`) via HTTP+SSE in-process. Pour `export_report`, le test fait : (a) appel POST → reçoit `download_url + token`, (b) GET sur `/mcp/exports/:id?token=...` → reçoit le contenu, (c) GET à nouveau → 404 (one-shot consommé).

6. **Documentation `docs/operating/mcp-exports.md`** : format des 3 sorties (avec exemples), TTL des URL signées, sécurité (HMAC, one-shot, suppression).

7. **Init `5.1` tické** dans `init-reconaut-platform/tasks.md` — la décision « namespace plutôt qu'Engine » est documentée dans le statut, et le test additionnel anti-stdio est livré.

## Contraintes

- **Pas de réintroduction de routes REST hors `/mcp/*`**. La nouvelle route `GET /mcp/exports/:id` reste dans le namespace `/mcp` ; le linter `check_rest_allowlist.sh` reste vert sans modification (le pattern `,[[:space:]]*to:[[:space:]]*"mcp/` couvre déjà la nouvelle route).
- **Pas de stdio MCP**. Le linter `check_no_mcp_stdio.sh` rejette toute introduction. Cohérent avec project.md *« HTTP+SSE uniquement »*.
- **Storage filesystem uniquement**. Pas de S3, pas de stockage objet — cohérent avec l'invariant *« pas de stockage objet S3-compatible »* d'`init-reconaut-platform`. Le chemin par défaut est `Rails.root.join("tmp/exports")` ; surchargeable via `RECONAUT_EXPORT_DIR`.
- **Token HMAC, pas de session**. Pas de cookie, pas de session Rails — le token est calculé sur `(uuid || expires_at_iso)` avec `Rails.application.secret_key_base` et vérifié au temps constant (Rack::Utils.secure_compare).
- **One-shot download par défaut**. Une fois téléchargé, le fichier est `unlink`-é. Un retry après crash réseau côté client doit re-générer. Cette politique réduit la fenêtre d'exposition d'une URL volée.
- **Mode mono-user**. Pas de filtre `tenant_id` dans l'export. Un seul opérateur, un seul périmètre.
- **Pas de gem externe d'export**. La sérialisation utilise `JSON` (stdlib), `CSV` (stdlib), et `JSON` pour STIX2 (juste un Hash structuré). Pas de `roo`, pas de `prawn-pdf`, pas de gem STIX dédiée — la décision STIX2 est un Hash en Ruby pur.
- **Pas de Rails Engine au sens strict**. La spec dit *« Engine OU namespace »* — le namespace `/mcp` reste, c'est le choix architectural acté. Un futur `add-mcp-rails-engine` pourra extraire un vrai `Rails::Engine` quand le besoin émergera (multi-mount, isolation totale, gem réutilisable).

## Non-objectifs (hors scope de ce change)

- **Vrai Rails Engine** sous `apps/api/engines/mcp/` — relève de `add-mcp-rails-engine` futur. Le namespace actuel est suffisant pour §5.1.
- **Mapping STIX2 complet** (Indicator, Malware, ThreatActor, Relationship, Sighting…) — relève de `add-stix2-full-mapping`. Ce change livre uniquement les SCO de base (ipv4-addr, domain-name, network-traffic).
- **Streaming d'exports via SSE** — pour les très gros exports (> 100k lignes), un streaming chunked serait utile. Différé à `add-export-streaming`.
- **URLs signées CDN-friendly** — la v1 sert le fichier directement depuis Rails. Si un opérateur veut router via CloudFront, ça relève de `add-export-signed-cdn`.
- **Re-téléchargement multi-utilisateur** — one-shot par token. Un utilisateur qui veut un re-download doit relancer l'export. Différé à `add-export-multi-download`.
- **Authentification utilisateur du download** — le token suffit en mono-user. En multi-user (hors v1), il faudrait croiser token + identité du caller.
- **Filtrage avancé** (date range, type de service, country code, etc.) — la v1 supporte `kind` + `limit` uniquement. Filtres riches relèvent de `add-export-filters`.

## Décisions prises

1. **`export_report` retourne une URL signée plutôt qu'inline**. Cohérent avec la spec parente. Les exports peuvent être MB-sized ; inline forcerait à charger en mémoire côté client. L'URL `/mcp/exports/:id` reste sous `/mcp/*` pour passer l'allowlist REST.
2. **HMAC-SHA256 pour la signature**, pas JWT. JWT introduirait une gem ou ~50 LOC de codage base64. HMAC sur `(uuid || expires_at)` est suffisant — on n'a pas de claims complexes à transporter.
3. **One-shot download** plutôt que multi-download pendant 1h. Réduit la surface d'attaque ; un token volé ne peut servir qu'une fois. L'opérateur qui veut un re-download relance l'export — coût négligeable.
4. **STIX2 minimal SCO-only**. Mapping complet STIX2 est un projet de plusieurs jours (relations, indicators, threats). La v1 livre les SCO bruts (ipv4-addr, domain-name, network-traffic) qui couvrent 90% des cas d'usage SIEM/threat intel.
5. **Pas de Rails Engine refactor**. La spec autorise « namespace de routes » et c'est ce qui est livré. Refactorer en Engine touche 20+ fichiers sans bénéfice fonctionnel — décision pragmatique.
6. **Linter `check_no_mcp_stdio.sh` séparé** plutôt que d'étendre `check_stack.sh`. Cohérent avec le pattern *un linter par invariant* déjà établi (check_no_billing, check_ssh_probe_no_auth, check_rest_allowlist, etc.).

## Différé (non bloquant, parqué pour plus tard)

- **`add-mcp-rails-engine`** : extraction d'un vrai Rails::Engine quand le besoin émergera (sandbox isolé, packaging gem).
- **`add-stix2-full-mapping`** : mapping STIX2.1 complet (Indicator, Relationship, Sighting, etc.).
- **`add-export-streaming`** : streaming chunked SSE pour les très gros exports (> 100k lignes).
- **`add-export-signed-cdn`** : URLs S3-style pour CDN, en alternative au serving Rails direct.
- **`add-export-filters`** : filtres riches (date range, country, service type) au lieu du simple `kind + limit`.
- **`add-export-multi-download`** : URL valide N téléchargements pendant la fenêtre, plutôt que one-shot.
