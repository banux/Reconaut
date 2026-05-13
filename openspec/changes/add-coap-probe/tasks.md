# Tâches : add-coap-probe

Checklist du sondeur CoAP (GET /.well-known/core, pas de mutation, pas d'Observe, pas de multicast). Chaque tâche inclut notes d'implémentation + test plan.

---

## 1. Sondeur Go

- [x] **1.1 Package `apps/scanner/internal/coapprobe/`**
  - **Notes** : `coapprobe.go` expose :
    ```go
    type Config struct { Port int; Timeout time.Duration }
    type Result struct {
      ResponseCodeClass  uint8  `json:"response_code_class"`
      ResponseCodeDetail uint8  `json:"response_code_detail"`
      ResponseCodeMeaning string `json:"response_code_meaning"`
      ContentFormat      int    `json:"content_format"`
      PayloadExcerpt     string `json:"payload_excerpt"`
      DurationMs         int    `json:"duration_ms"`
      BytesReceived      int    `json:"bytes_received"`
      Outcome            string `json:"outcome"`
    }
    func Probe(ctx context.Context, target string, cfg Config) (Result, error)
    ```
  - Implémentation : (a) Refuse multicast targets (24.x → 239.x, ff00::/8) au runtime. (b) `net.DialUDP`. (c) Construire GET `/.well-known/core` (header CON+GET, Uri-Path "well-known" + "core"). (d) `WriteToUDP` + `ReadFromUDP` avec deadline. (e) Parser réponse : code byte, scanner options pour Content-Format (option 12), extraire payload après `0xFF` marker. (f) Plafonner payload excerpt à 4096 bytes.
  - **Aucun PUT/POST/DELETE/Observe/multicast** dans le code prod.
  - **Test plan** : 7 tests Go : (a) 2.05 Content, (b) 4.04 Not Found, (c) not_coap garbage, (d) timeout silence, (e) dial_error (UDP unreachable), (f) multicast refused, (g) payload excerpt plafonné.

- [x] **1.2 Faux serveur CoAP de test (in-process UDP)**
  - **Notes** : Listener UDP local scriptable : lit le GET, renvoie un response code scriptable (2.05/4.04/etc.) + content-format optionnel + payload optionnel. Log les paquets reçus après le 1er pour assurer qu'aucune retransmission/2e GET n'arrive.
  - **Test plan** : `t.Fatal` si > 1 paquet reçu.

- [x] **1.3 Linter anti-offensif CoAP**
  - **Notes** : `scripts/check_coap_probe_no_offensive.sh` qui grep `apps/scanner/internal/coapprobe/` (hors `_test.go`) avec patterns interdits : `POST`, `PUT`, `DELETE`, `Observe`, `multicast`, `224.0.1.187`. Allowlist commentaires + chaînes `return "<class>.<detail> <meaning>"` qui décrivent les codes.
  - **Test plan** : `_test.sh` jumeau qui injecte chaque pattern interdit → exit ≠ 0.

---

## 2. Câblage côté binaire `scanner-service_fingerprint`

- [x] **2.1 Handler dispatch vers coapprobe quand port=5683**
  - **Notes** : Étendre `apps/scanner/internal/scanhandler/handler.go` avec une option `CoAPProber`. Dispatch quand `target.kind ∈ {host, ip}` ET `findings.port=5683` OU `options.protocols` inclut `"coap"`.
  - **Test plan** : port 5683 → CoAPProber appelé ; autre port → pas appelé ; cohabitation avec SSH/RDP/MQTT.

- [x] **2.2 ENV var `RECONAUT_COAP_PROBE_TIMEOUT`**
  - **Notes** : Lu par `scanner-service_fingerprint/main.go`, passé à `coapprobe.Config`.
  - **Test plan** : `RECONAUT_COAP_PROBE_TIMEOUT=300ms` → sonde abandonne après 300ms.

---

## 3. Documentation

- [x] **3.1 `docs/architecture/scan-frontier.md`**
  - **Notes** : Mentionner que `service_fingerprint` couvre désormais SSH + RDP + MQTT + **CoAP** (UDP/5683). GET /.well-known/core only, pas de mutation, pas d'Observe.
  - **Test plan** : `grep -i "coap" docs/architecture/scan-frontier.md` ≥ 1 match.

- [x] **3.2 `openspec/project.md`**
  - **Notes** : Bullet *Workers de scan spécialisés* — `scanner-service_fingerprint` couvre désormais SSH + RDP + MQTT + CoAP.
  - **Test plan** : `grep -i "coap" openspec/project.md` ≥ 1 match.

---

## 4. Acceptance

- [x] **4.1 Tests automatisés**
  - 7 tests Go (cf. §1.1). Test runtime : 0 paquet UDP après le 1er GET.

- [x] **4.2 Linter en CI**
  - `scripts/check_coap_probe_no_offensive.sh` + `_test.sh` jumeau dans le job `stack-lint`.

- [x] **4.3 Audit dépendances**
  - Aucune nouvelle dep externe. `go mod tidy` → aucun changement.

- [x] **4.4 Build statique**
  - `CGO_ENABLED=0 go build` → ELF statique < 20 MB.

- [x] **4.5 Aucune régression**
  - `cd apps/scanner && go test ./...` reste vert. SSH + RDP + MQTT intacts.
