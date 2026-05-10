# Tâches : add-mcp-engine

Checklist de la fermeture de `init-reconaut-platform` §5.1 : outil MCP `export_report` (json/csv/stix2 + URL signée), linter anti-stdio MCP, test couvrant les 5 tools.

---

## 1. Module exporter

- [x] **1.1 `Reconaut::Exporter` lib**
  - **Notes** : Nouveau fichier `apps/api/app/lib/reconaut/exporter.rb`. Module avec méthodes :
    - `Exporter.export(kind:, format:, limit:, dest_path:)` → `{path, record_count}`
    - `kind` ∈ {scope, hosts, services, scans} ; lit via les stores Registry par défaut.
    - `format` ∈ {json, csv, stix2} ; sérialise selon les règles de la spec.
    - Pas de gem externe ; stdlib `JSON`, `CSV`, `SecureRandom`.
  - **Test plan** : Spec dédiée `spec/lib/reconaut/exporter_spec.rb` :
    - JSON : tableau plat parseable, record_count exact.
    - CSV : RFC4180, headers + data, valeurs avec virgule quotées.
    - STIX2 : bundle valide, type=bundle, id UUID, objects = SCO basiques.
    - limit respecté.

- [x] **1.2 Sérialisation STIX2.1 minimal SCO-only**
  - **Notes** : Pour chaque host, produire :
    - IP (IPv4) → `{type: "ipv4-addr", id: "ipv4-addr--<uuid5>", value: "..."}`
    - FQDN → `{type: "domain-name", id: "domain-name--<uuid5>", value: "..."}`
    - Pour chaque service du host → `{type: "network-traffic", id: "network-traffic--<uuid5>", dst_ref: "<host_id>", dst_port: <port>, protocols: ["<proto>"]}`
    - Bundle wrapper : `{type: "bundle", id: "bundle--<uuid>", objects: [...]}`
    - UUID5 namespace = `Reconaut::Exporter::STIX_UUID_NAMESPACE` figé (cohérence inter-export).
  - **Test plan** : Spec qui valide le bundle contre la forme STIX2.1 (pas de schema validator complet — juste les invariants : type, id format `<type>--<uuid>`, objects array non-vide).

---

## 2. Outil MCP `export_report`

- [x] **2.1 Enregistrement dans `Mcp::CoreTools.register_all!`**
  - **Notes** : Nouveau bloc `ToolRegistry.register(name: "export_report", scopes: [:"read:reports"], ...)` dans `core_tools.rb`. Le block valide les params, appelle `Reconaut::Exporter.export(...)` qui retourne `{path, record_count}`, calcule un token HMAC, retourne `{download_url, token, expires_at, format, record_count}`.
  - **Test plan** : Test request `spec/requests/mcp/export_report_spec.rb` couvre les 7 scenarios de la spec (JSON OK, one-shot, token invalid, CSV RFC4180, STIX2 bundle, limit, scope manquant).

- [x] **2.2 Token HMAC**
  - **Notes** : Méthode privée `Mcp::CoreTools.export_token_for(uuid, expires_at)` qui calcule `OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, "#{uuid}|#{expires_at_iso}")`. Vérification dans `ExportsController#download` avec `Rack::Utils.secure_compare`.
  - **Test plan** : Spec dédiée vérifie : (a) tokens identiques pour mêmes inputs, (b) modification d'un bit invalide la signature, (c) `secure_compare` utilisé (timing-safe).

---

## 3. Route et controller `Mcp::ExportsController`

- [x] **3.1 Route `GET /mcp/exports/:id`**
  - **Notes** : Ajouter dans `config/routes.rb` sous `scope "/mcp"` : `get "/exports/:id", to: "mcp/exports#download"`. Reste sous `/mcp/*` → l'allowlist REST passe sans modification.
  - **Test plan** : `bash scripts/check_rest_allowlist.sh` retourne 0.

- [x] **3.2 Controller `Mcp::ExportsController#download`**
  - **Notes** : Nouveau fichier `apps/api/app/controllers/mcp/exports_controller.rb`. Vérifie : (a) param `token` présent, (b) signature HMAC valide via `secure_compare`, (c) `expires_at` futur, (d) fichier existe sous `RECONAUT_EXPORT_DIR/<uuid>.<ext>`. Si tout OK : send_file + `unlink` après envoi (one-shot). Sinon : 404 Not Found (jamais 401 — pour ne pas leaker l'existence).
  - **Test plan** : Spec request couvre : (a) download OK + suppression, (b) re-download → 404, (c) token altéré → 404, (d) expires_at passé → 404.

---

## 4. Linter anti-stdio MCP

- [x] **4.1 `scripts/check_no_mcp_stdio.sh`**
  - **Notes** : Nouveau script qui grep dans `apps/api`, `apps/scanner`, `apps/tui` pour les patterns suivants :
    - `mcp-rb.*stdio` ou `require ['"]mcp/stdio['"]`
    - `MCP::Stdio` ou `Mcp::Stdio`
    - `STDIO_TRANSPORT` ou `--stdio` (en chaîne, dans CLI args)
    - import Go `"github.com/.*/mcp-go/stdio"` ou similaire
    Tolère les commentaires (filtre `^[^:]+:[0-9]+:[[:space:]]*(//|#)`) et les fichiers _test/_spec.
  - **Test plan** : `scripts/check_no_mcp_stdio_test.sh` :
    - état de base → exit 0
    - injection de `MCP::Stdio.start` dans un fichier de prod → exit ≠ 0
    - injection dans un commentaire → exit 0 (toléré)
    - injection dans `_spec.rb` → exit 0 (toléré)

- [x] **4.2 Wiring CI**
  - **Notes** : Ajouter 2 steps au job `stack-lint` dans `.github/workflows/ci.yml` : `bash scripts/check_no_mcp_stdio.sh` + `bash scripts/check_no_mcp_stdio_test.sh`.
  - **Test plan** : Lecture manuelle du workflow ; les 2 steps sont présentes après les autres `check_*.sh`.

---

## 5. Documentation

- [x] **5.1 `docs/operating/mcp-exports.md`**
  - **Notes** : Documentation opérateur :
    - Format des 3 sorties (JSON, CSV, STIX2) avec exemples.
    - Sécurité : token HMAC, one-shot, expiration 1h.
    - Limitations : 10000 records max par export ; STIX2 minimal SCO-only ; pas de filtre date range en v1.
    - Variables : `RECONAUT_EXPORT_DIR`, `RECONAUT_EXPORT_TTL_S`.
  - **Test plan** : `grep -i "stix2\|HMAC\|one-shot" docs/operating/mcp-exports.md` retourne ≥ 3 matches.

- [x] **5.2 Référence dans `docs/architecture/mcp-first.md`**
  - **Notes** : Ajouter une note dans la section listant les tools MCP : `export_report` est livré, format détaillé dans le doc opérateur.
  - **Test plan** : `grep -i "export_report" docs/architecture/mcp-first.md` retourne ≥ 1 match.

---

## 6. Acceptance pour le change dans son ensemble

- [x] **6.1 Test système : les 5 tools de §5.1 répondent sur HTTP**
  - **Notes** : Spec `spec/integration/mcp_engine_five_tools_spec.rb` exerce `search_hosts`, `get_host`, `request_scan`, `get_scan_status`, `export_report` via `POST /mcp/tools/<name>`. Pour chaque outil : (a) appel avec params valides retourne 200, (b) la liste `GET /mcp/tools` contient le nom.
  - **Test plan** : Le spec passe en 1 run RSpec.

- [x] **6.2 Aucune régression**
  - Toute la suite RSpec actuelle (502 examples avant ce change) reste verte. Tous les linters CI restent verts (y compris le nouveau `check_no_mcp_stdio.sh`).

- [x] **6.3 Tick `init-reconaut-platform` §5.1**
  - **Notes** : Modifier `openspec/changes/init-reconaut-platform/tasks.md` pour cocher §5.1 avec un statut documentant : (a) namespace de routes `/mcp/*` (pas Engine, choix acté), (b) 5 tools listés tous accessibles, (c) linter anti-stdio livré, (d) pas de chemin stdio dans le repo.
  - **Test plan** : `grep -E "^- \[x\] \*\*5\.1" openspec/changes/init-reconaut-platform/tasks.md` retourne 1 match.

- [x] **6.4 Cleanup automatique du répertoire d'exports**
  - **Notes** : `Mcp::CoreTools.export_report` purge **avant** d'écrire son fichier les exports antérieurs à `now - 24h` sous `RECONAUT_EXPORT_DIR`. Ainsi, si plusieurs exports orphelins (download abandonné, crash) s'accumulent, ils sont nettoyés sans cron job dédié.
  - **Test plan** : Spec qui crée un fichier vieux (`File.utime(25h_ago, ...)`) sous `tmp/exports/`, déclenche un nouvel export, et vérifie que le vieux fichier est supprimé.
