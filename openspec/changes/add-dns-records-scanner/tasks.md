# Tâches : add-dns-records-scanner

Checklist de l'ajout d'un scanner DNS spécialisé qui résout A/AAAA/MX/NS/TXT/CAA/SOA/CNAME pour un domaine couvert par le scope. Chaque tâche inclut des notes d'implémentation et un test plan qui DOIT passer avant de cocher la case.

---

## 1. Étendre le contrat ScanJobV1

- [x] **1.1 Ajouter `dns_records` à l'enum `scan_kind` dans le schéma JSON**
  - **Notes** : Modifier [`packages/job-schema/scan_job_v1.json`](../../../packages/job-schema/scan_job_v1.json) pour inclure `"dns_records"` dans l'enum `scan_kind`. Pas de bump de `schema_version` (extension non-breaking ; un client qui ignore la nouvelle valeur reste fonctionnel).
  - **Test plan** : Spec Ruby `spec/lib/job_schema/registry_spec.rb` (ou test existant équivalent) : un payload avec `scan_kind="dns_records"` est accepté par `JobSchema::Registry.validate("ScanJobV1", payload)`. Test Go `internal/jobschema/jobschema_test.go` : idem côté Go.

- [x] **1.2 Étendre l'enum `scan_kind` du tool MCP `request_scan`**
  - **Notes** : Dans `apps/api/app/lib/mcp/core_tools.rb`, ajouter `dns_records` au `params_schema` du tool `request_scan` (`values: %w[tcp_probe tls_capture http_banner subdomain_enum service_fingerprint dns_records]`).
  - **Test plan** : Spec request `spec/requests/mcp/request_scan_spec.rb` : un appel `request_scan` avec `scan_kind="dns_records"` et une cible domaine dans le scope retourne `200 + ok=true`. Un `scan_kind` hors enum (par ex. `dns_zonewalk`) renvoie `param_invalid`.

- [x] **1.3 Validation : `dns_records` exige target_kind ∈ {domain, host}**
  - **Notes** : Dans `Reconaut::ScanEnqueuer#call` (ou dans le tool `request_scan` directement), rejeter avec `InvalidPayloadError` quand `scan_kind="dns_records"` et `target_kind ∈ {ip, cidr}`. Le message doit nommer la contrainte (`dns_records requires target_kind in {domain, host}`).
  - **Test plan** : Spec : `request_scan({scan_kind: "dns_records", target_kind: "ip", target_value: "192.0.2.1"})` renvoie `{ ok: false, error: "invalid_target" }` avec un message lisible. `target_kind=domain` réussit. `target_kind=host` réussit.

---

## 2. Binaire `scanner-dns_records`

- [x] **2.1 Squelette du binaire sous `apps/scanner/cmd/scanner-dns_records/`**
  - **Notes** : Reproduire le pattern des binaires existants (`scanner-tcp_probe/main.go`) : `os.Exit(runtime.Run(runtime.Config{ScanKind: "dns_records", Args: os.Args[1:]}))`. Le runtime partagé câble la queue `scan:dns_records` et le handler scanhandler générique. La logique DNS spécifique vit dans un nouveau package `apps/scanner/internal/dnsprobe/` (cf. §2.2).
  - **Test plan** : `find apps/scanner/cmd -name main.go` renvoie 6 fichiers (les 5 existants + dns_records). `go build ./...` passe. `apps/scanner/cmd/scanner-dns_records/scanner-dns_records --version` exit 0.

- [x] **2.2 Sondeur DNS dans `apps/scanner/internal/dnsprobe/`**
  - **Notes** : Nouveau package Go `dnsprobe` qui expose `Resolve(ctx context.Context, target string, cfg Config) (Records, error)`. `Config` porte `Resolver string` (host:port, vide = système), `Timeout time.Duration` (défaut 5 s), `Types []string` (défaut A, AAAA, MX, NS, TXT, CAA, SOA, CNAME). Implémenter avec `net.Resolver` de la stdlib (configurable via `Dial`). Pas d'AXFR, jamais.
  - **Test plan** : Test unitaire `dnsprobe_test.go` qui démarre un faux résolveur DNS local (ex: `github.com/miekg/dns` server in-process — autorisé, MIT) et vérifie : (a) chaque type est interrogé une fois, (b) AXFR/IXFR ne sont jamais formés, (c) timeout par requête respecté, (d) un type qui timeout n'empêche pas les autres.

- [x] **2.3 Handler `dns_records` dans `scanhandler.New`**
  - **Notes** : Étendre le `scanhandler.New` (ou créer une variante `scanhandler.NewDNS`) qui, après validation `ScanJobV1`, appelle `dnsprobe.Resolve` et insère un `Result` par type d'enregistrement résolu dans le `results.Store`. Le `findings` agrégé est sérialisé en JSON dans le `ScanResultV1` qui sera ingéré côté Rails (chemin `ingest_scan_result`, déjà livré).
  - **Test plan** : Test d'intégration : enqueue un job `dns_records` avec un faux résolveur ; le handler appelle `dnsprobe.Resolve`, persiste un `Result` dont `Status="ok"` ; le `findings` contient autant d'entrées que de records résolus. Test `target_kind=ip` : le handler renvoie une erreur `invalid_target` sans appeler le résolveur.

---

## 3. Linter et CI

- [x] **3.1 `check_scanner_specialization.sh` couvre `dns_records`**
  - **Notes** : Ajouter `dns_records` à `EXPECTED_KINDS` dans `scripts/check_scanner_specialization.sh`. Mettre à jour `scripts/check_scanner_specialization_test.sh` : le test "current scanner cmd tree → exit 0" vérifie maintenant 6 binaires.
  - **Test plan** : `bash scripts/check_scanner_specialization.sh` passe sur HEAD avec les 6 binaires. Test : suppression de `apps/scanner/cmd/scanner-dns_records/main.go` → linter échoue avec un message nommant le binaire manquant.

- [x] **3.2 Le job CI `tui-go` / `scanner-go` build le nouveau binaire**
  - **Notes** : Le job `scanner-go` du `.github/workflows/ci.yml` utilise déjà `go build ./...` qui couvre tous les binaires. Vérifier qu'il continue de passer avec le 6ème binaire (test : check local `cd apps/scanner && go build ./...` après ajout).
  - **Test plan** : `cd apps/scanner && go build ./... && go test ./... && go vet ./...` passent.

---

## 4. Documentation

- [x] **4.1 Mettre à jour `openspec/project.md`**
  - **Notes** : La liste des `scan_kind` mentionne désormais 6 binaires : ajouter `scanner-dns_records` au paragraphe *Workers de scan spécialisés*.
  - **Test plan** : `grep -i "scanner-dns_records" openspec/project.md` renvoie ≥ 1 match.

- [x] **4.2 Mettre à jour `docs/positioning/agent-knowledge-base.md`**
  - **Notes** : La section *Alimentation hybride* peut mentionner que les enregistrements DNS d'un domaine connu sont collectés par `scanner-dns_records`. Pas de réécriture lourde, juste une ligne dans le tableau.
  - **Test plan** : `grep -i "dns_records\|enregistrement DNS" docs/positioning/agent-knowledge-base.md` renvoie ≥ 1 match.

- [x] **4.3 Mettre à jour `docs/architecture/scan-frontier.md`**
  - **Notes** : La page liste les `scan_kind` ; ajouter `dns_records` avec sa cible (`domain`/`host`) et sa queue `scan:dns_records`.
  - **Test plan** : `grep -i "dns_records" docs/architecture/scan-frontier.md` renvoie ≥ 1 match.

- [x] **4.4 Mettre à jour `docs/integrations/external-scanners.md`**
  - **Notes** : Mentionner que `dns_records` peut aussi être ingéré via `ingest_scan_result` (un opérateur qui exécute `dig` ou un script maison peut formater un `ScanResultV1` avec `findings` typé `dns_record` et le pousser via MCP).
  - **Test plan** : `grep -i "dns_records" docs/integrations/external-scanners.md` renvoie ≥ 1 match.

---

## 5. Acceptance pour le change dans son ensemble

- [x] **5.1 Tests automatisés du nouveau Requirement**
  - Au moins quatre specs : (a) request_scan happy path avec `dns_records`, (b) target_kind=ip rejeté, (c) target hors scope rejeté, (d) résolution avec faux résolveur retourne les records attendus, (e) AXFR jamais formé.

- [x] **5.2 Linter `check_scanner_specialization.sh` actif en CI avec 6 binaires**
  - Le check tourne sur chaque PR. La fusion d'une PR qui supprime ou casse `scanner-dns_records` est bloquée.

- [x] **5.3 Audit anti-AXFR**
  - Test grep : `grep -RnE "(AXFR|IXFR)" apps/scanner/internal/dnsprobe/` renvoie zéro occurrence (hors commentaires explicitement marqués comme « interdit »).

- [x] **5.4 Le binaire `scanner-dns_records` build statiquement**
  - `CGO_ENABLED=0 go build -o scanner-dns_records ./apps/scanner/cmd/scanner-dns_records` produit un binaire statique. `file scanner-dns_records` confirme un binaire ELF statiquement linké.

- [x] **5.5 La routine `system_doctor` reste cohérente**
  - Pas de régression sur `Reconaut::Doctor`. Optionnel : ajouter un check info-level `dns_resolver_configured` qui rapporte la valeur de `RECONAUT_DNS_RESOLVER` (sans la résoudre, juste pour exposer la config courante).
