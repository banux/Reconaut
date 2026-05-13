# Tâches : add-mqtt-probe

Checklist de l'ajout du sondeur MQTT (CONNECT + CONNACK capture, sans auth, ni PUBLISH/SUBSCRIBE). Chaque tâche inclut notes d'implémentation + test plan qui DOIT passer avant de cocher la case.

---

## 1. Sondeur Go

- [x] **1.1 Package `apps/scanner/internal/mqttprobe/`**
  - **Notes** : Nouveau package Go avec `mqttprobe.go` qui expose :
    ```go
    type Config struct {
      Port           int           // défaut 1883 (8883 pour TLS)
      Timeout        time.Duration // défaut 5s
      TryTLSUpgrade  bool          // défaut true sur port 8883, false sinon
      ClientID       string        // défaut ""
    }
    type Result struct {
      ProtocolLevel     uint8    `json:"protocol_level"`
      ReturnCode        uint8    `json:"return_code"`
      ReturnCodeMeaning string   `json:"return_code_meaning"`
      SessionPresent    bool     `json:"session_present"`
      TLSCertSHA256     string   `json:"tls_cert_sha256"`
      TLSSANs           []string `json:"tls_sans"`
      TLSNotAfter       string   `json:"tls_not_after"`
      DurationMs        int      `json:"duration_ms"`
      BytesReceived     int      `json:"bytes_received"`
      Outcome           string   `json:"outcome"`
    }
    func Probe(ctx context.Context, target string, cfg Config) (Result, error)
    ```
  - Implémentation : (a) `net.DialContext` TCP + deadline. (b) Si port 8883 OU `TryTLSUpgrade=true` : `tls.Client` + handshake + capture cert. (c) Construire CONNECT MQTT 3.1.1 : `0x10` + remaining_length + protocol_name "MQTT" (length-prefixed) + protocol_level `0x04` + connect_flags `0x02` (clean session only) + keep_alive `0x003C` + client_id (length-prefixed). (d) Lire 4 octets CONNACK : `0x20`, `0x02`, session_present, return_code. (e) Envoyer DISCONNECT `0xE0 0x00`. (f) Fermer.
  - **Aucun username/password / Will / Publish / Subscribe**.
  - **Test plan** : `go test ./internal/mqttprobe/` couvre 7 scenarios (cf. spec.md) : success rc=0, rc=5 (not_authorized), rc=1 (unacceptable_protocol), TLS capture sur 8883, TLS désactivé via env, not_mqtt sur HTTP, dial_error.

- [x] **1.2 Faux broker MQTT de test (in-process)**
  - **Notes** : Listener TCP local qui (a) lit le CONNECT envoyé par le client, (b) renvoie un CONNACK scriptable (rc=0, rc=1, rc=5, ou silence pour test timeout), (c) si TLS demandé : présente un cert ECDSA fixture, (d) **logue tout byte reçu après le CONNACK et fait échouer le test si > 2 bytes** (les 2 attendus sont DISCONNECT `0xE0 0x00`).
  - **Test plan** : panique `t.Fatal` si un byte PUBLISH/SUBSCRIBE/PINGREQ est observé.

- [x] **1.3 Linter anti-auth MQTT**
  - **Notes** : `scripts/check_mqtt_probe_no_auth.sh` qui grep `apps/scanner/internal/mqttprobe/` avec patterns interdits : `password`, `credential`, `username`, `WillTopic`, `WillMessage`, `Publish(`, `Subscribe(`, `Unsubscribe(`. Allowlist commentaires uniquement.
  - **Test plan** : `_test.sh` jumeau qui injecte successivement chaque pattern interdit → exit ≠ 0.

---

## 2. Câblage côté binaire `scanner-service_fingerprint`

- [x] **2.1 Handler dispatch vers mqttprobe quand port=1883 ou 8883**
  - **Notes** : Étendre `apps/scanner/internal/scanhandler/handler.go` avec une option `MQTTProber`. Le handler dispatche quand `target.kind ∈ {host, ip}` ET `findings.port ∈ {1883, 8883}` OU `options.protocols` inclut `"mqtt"`. Pattern aligné sur `shouldProbeSSH` / `shouldProbeRDP`.
  - **Test plan** : Test unitaire : port 1883 → MQTTProber appelé ; port 8883 → MQTTProber appelé avec TryTLS=true ; port 443 → MQTTProber pas appelé ; cohabitation SSH/RDP/MQTT correcte.

- [x] **2.2 ENV vars `RECONAUT_MQTT_PROBE_*`**
  - **Notes** : `RECONAUT_MQTT_PROBE_TIMEOUT` (s, défaut 5). `RECONAUT_MQTT_PROBE_DISABLE_TLS_UPGRADE` (`true`/`1` désactive). Lu par `scanner-service_fingerprint/main.go`, passé à `mqttprobe.Config`.
  - **Test plan** : Test : timeout=300ms → sonde abandonne après 300ms sur broker silencieux. `DISABLE_TLS=true` → pas de ClientHello.

---

## 3. Documentation

- [x] **3.1 `docs/architecture/scan-frontier.md`**
  - **Notes** : Mentionner que `service_fingerprint` couvre désormais SSH + RDP + **MQTT** (TCP/1883 et /8883). Préciser : CONNECT only, pas de PUBLISH/SUBSCRIBE, pas d'auth.
  - **Test plan** : `grep -i "mqtt" docs/architecture/scan-frontier.md` ≥ 1 match.

- [x] **3.2 `openspec/project.md`**
  - **Notes** : Bullet *Workers de scan spécialisés* — `scanner-service_fingerprint` couvre désormais SSH + RDP + MQTT.
  - **Test plan** : `grep -i "mqtt" openspec/project.md` ≥ 1 match.

---

## 4. Acceptance

- [x] **4.1 Tests automatisés**
  - Au moins 7 tests Go : success rc=0, rc=5, rc=1, TLS capture, TLS désactivé, not_mqtt, dial_error.
  - Test runtime confirme **0 byte post-CONNACK autre que DISCONNECT**.

- [x] **4.2 Linter en CI**
  - `scripts/check_mqtt_probe_no_auth.sh` tourne dans le job `stack-lint` ; `_test.sh` jumeau aussi.

- [x] **4.3 Audit dépendances**
  - Aucune nouvelle dep externe. `go mod tidy` ne montre AUCUN changement après l'ajout.

- [x] **4.4 Build statique**
  - `CGO_ENABLED=0 go build` produit un binaire ELF statiquement linké, < 20 MB.

- [x] **4.5 Aucune régression**
  - `cd apps/scanner && go test ./...` reste vert. SSH + RDP intacts.
