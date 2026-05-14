# Tâches : add-worker-modbus

Checklist du sondeur Modbus TCP (Read Device Identification + fallback Read Holding Registers, pas de write, pas de Diagnostics). Chaque tâche inclut notes + test plan.

---

## 1. Sondeur Go

- [x] **1.1 Package `apps/scanner/internal/modbusprobe/`**
  - **Notes** : `modbusprobe.go` expose :
    ```go
    type Config struct { Port int; Timeout time.Duration; UnitID byte }
    type Result struct {
      VendorName         string `json:"vendor_name"`
      ProductCode        string `json:"product_code"`
      MajorMinorRevision string `json:"major_minor_revision"`
      FunctionCode       uint8  `json:"function_code"`
      ExceptionCode      uint8  `json:"exception_code"`
      ExceptionMeaning   string `json:"exception_meaning"`
      IsModbus           bool   `json:"is_modbus"`
      DurationMs         int    `json:"duration_ms"`
      BytesReceived      int    `json:"bytes_received"`
      Outcome            string `json:"outcome"`
    }
    func Probe(ctx context.Context, target string, cfg Config) (Result, error)
    ```
  - Implémentation :
    - Constantes : `fnReadHoldingRegisters = 0x03`, `fnReadDeviceID = 0x2B` (mei_type 0x0E).
    - MBAP header (7 bytes) : `transaction_id (u16) | protocol_id (u16=0) | length (u16) | unit_id (u8)`.
    - PDU Read Device ID : `0x2B 0x0E 0x01 0x00` (function | mei_type | read_device_id_code=basic | object_id=0x00).
    - PDU Read Holding Registers fallback : `0x03 0x0000 0x0001` (function | starting_address | quantity).
    - Parser réponse : si `function_code & 0x80` → exception ; sinon décode les objects (id, length, value bytes) jusqu'à object_id 0x02.
    - Refuse multicast targets au runtime (par cohérence avec coapprobe, même si Modbus TCP n'a pas de multicast standard).
  - **Test plan** : 7 tests Go : (a) Read Device ID success → vendor/product/revision parsés ; (b) exception 0xAB sur 0x2B → fallback Read Holding réussit, is_modbus=true ; (c) exception sur les deux → is_modbus=true mais vendor vide ; (d) not_modbus garbage ; (e) timeout silence ; (f) dial_error port fermé ; (g) au plus 2 paquets envoyés.

- [x] **1.2 Faux serveur Modbus TCP de test (in-process)**
  - **Notes** : Listener TCP local scriptable :
    - Lit le MBAP header (7 bytes) + PDU (variable selon function).
    - Renvoie une réponse scriptable : `success` avec objets device-id, exception (function | 0x80) + code, ou silence.
    - **Log chaque paquet reçu** ; le test panique si > 2 paquets sont observés sur la même connexion (ou si plus d'1 quand le scénario "1st request succeeds").
  - **Test plan** : panique `t.Fatal` si > 2 paquets reçus.

- [x] **1.3 Linter anti-write Modbus**
  - **Notes** : `scripts/check_modbus_probe_no_write.sh` qui grep `apps/scanner/internal/modbusprobe/` (hors `_test.go`) avec patterns interdits : `WriteSingleCoil`, `WriteMultipleCoils`, `WriteSingleRegister`, `WriteMultipleRegisters`, `MaskWriteRegister`, `ReadWriteMultipleRegisters`, `Diagnostics`, `Restart`, `ForceCoil`, `PresetRegister`. Allowlist : commentaires + chaînes `return "..."` pour les exception_meaning.
  - **Test plan** : `_test.sh` jumeau qui injecte chaque pattern → exit ≠ 0.

---

## 2. Câblage côté binaire `scanner-service_fingerprint`

- [x] **2.1 Handler dispatch vers modbusprobe quand port=502**
  - **Notes** : Étendre `apps/scanner/internal/scanhandler/handler.go` avec une option `ModbusProber`. Dispatch quand `target.kind ∈ {host, ip}` ET `findings.port=502` OU `options.protocols` inclut `"modbus"`. Pattern aligné sur `shouldProbeSSH` / `shouldProbeRDP` / `shouldProbeMQTT` / `shouldProbeCoAP`.
  - **Test plan** : Test : port 502 → ModbusProber appelé ; autre port → pas appelé ; cohabitation 5/6 sondeurs (SSH/RDP/MQTT/CoAP/Modbus).

- [x] **2.2 ENV vars `RECONAUT_MODBUS_PROBE_*`**
  - **Notes** : `RECONAUT_MODBUS_PROBE_TIMEOUT` (s, défaut 5). `RECONAUT_MODBUS_PROBE_UNIT_ID` (1-255, défaut 1).
  - **Test plan** : Test : timeout=300ms → sonde abandonne après 300ms. unit_id=255 → MBAP contient 0xFF.

---

## 3. Documentation

- [x] **3.1 `docs/architecture/scan-frontier.md`**
  - **Notes** : Mentionner que `service_fingerprint` couvre désormais SSH + RDP + MQTT + CoAP + **Modbus** (TCP/502). READ functions only (0x03, 0x2B), pas de write, pas de Diagnostics.
  - **Test plan** : `grep -i "modbus" docs/architecture/scan-frontier.md` ≥ 1 match.

- [x] **3.2 `openspec/project.md`**
  - **Notes** : Bullet *Workers de scan spécialisés* — `scanner-service_fingerprint` couvre désormais SSH + RDP + MQTT + CoAP + Modbus. Section §2.5 init-reconaut-platform désormais complète (6/6 sondeurs).
  - **Test plan** : `grep -i "modbus" openspec/project.md` ≥ 1 match.

- [x] **3.3 Cocher §2.5 dans `openspec/changes/init-reconaut-platform/tasks.md`**
  - **Notes** : La task "2.5 Sondeurs de protocole : HTTP(S), SSH, RDP, MQTT, CoAP, Modbus" peut désormais être cochée — tous les sondeurs sont livrés.
  - **Test plan** : `grep "Sondeurs de protocole" openspec/changes/init-reconaut-platform/tasks.md` retourne une ligne `[x]`.

---

## 4. Acceptance

- [x] **4.1 Tests automatisés**
  - 7 tests Go (cf. §1.1). Test runtime : ≤ 2 paquets envoyés par sonde.

- [x] **4.2 Linter en CI**
  - `scripts/check_modbus_probe_no_write.sh` + `_test.sh` jumeau dans le job `stack-lint`.

- [x] **4.3 Audit dépendances**
  - Aucune nouvelle dep externe. `go mod tidy` → aucun changement.

- [x] **4.4 Build statique**
  - `CGO_ENABLED=0 go build` → ELF statique < 20 MB.

- [x] **4.5 Aucune régression**
  - `cd apps/scanner && go test ./...` reste vert. SSH + RDP + MQTT + CoAP intacts.
