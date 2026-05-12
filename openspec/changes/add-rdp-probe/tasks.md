# Tâches : add-rdp-probe

Checklist de l'ajout du sondeur RDP (X.224 Negotiation + capture TLS cert, sans auth). Chaque tâche inclut des notes d'implémentation et un test plan qui DOIT passer avant de cocher la case.

---

## 1. Sondeur Go

- [ ] **1.1 Package `apps/scanner/internal/rdpprobe/`**
  - **Notes** : Nouveau package Go avec `rdpprobe.go` qui expose :
    ```go
    type Config struct {
      Port           int           // défaut 3389
      Timeout        time.Duration // défaut 5s
      TryTLSUpgrade  bool          // défaut true
      Cookie         string        // défaut "mstshash="
    }
    type Result struct {
      ProtocolVersion        uint32   `json:"protocol_version"`
      SecurityFlags          []string `json:"security_flags"`           // PROTOCOL_RDP|SSL|HYBRID|RDSTLS|HYBRID_EX
      NegotiationFailureCode uint32   `json:"negotiation_failure_code"`
      TLSCertSHA256          string   `json:"tls_cert_sha256"`
      TLSSANs                []string `json:"tls_sans"`
      TLSNotAfter            string   `json:"tls_not_after"`
      DurationMs             int      `json:"duration_ms"`
      BytesReceived          int      `json:"bytes_received"`
      Outcome                string   `json:"outcome"` // success | timeout | dial_error | not_rdp | negotiation_failure | tls_error
    }
    func Probe(ctx context.Context, target string, cfg Config) (Result, error)
    ```
  - Implémentation : (a) `net.DialContext` TCP + deadline `Timeout`, (b) construire le **X.224 Connection Request TPDU** : TPKT header `03 00 <len:u16>` + X.224 CR `<len> E0 00 00 00 00 00`, suivi du **cookie** `"Cookie: mstshash=\r\n"`, puis du **RDP Negotiation Request** `01 00 08 00 <requestedProtocols:u32-le>` avec `PROTOCOL_RDP|SSL|HYBRID|RDSTLS|HYBRID_EX = 0x1F`. (c) Lire le X.224 Connection Confirm via `bufio.Reader` (header TPKT 4 bytes → length → suite). (d) Parser `RDP Negotiation Response` (type `0x02`, length `0x0008`) ou `Failure` (type `0x03`). (e) Si `PROTOCOL_SSL` annoncé ET `TryTLSUpgrade=true` : `tls.Client(conn, &tls.Config{InsecureSkipVerify: true, ServerName: target})` + `Handshake(ctx)`, lire `ConnectionState().PeerCertificates[0]`, capturer SHA-256 / SANs / NotAfter. **FERMER immédiatement**, ne JAMAIS écrire après.
  - **Pas d'authentification** : aucune phase MCS, aucun PDU, aucun credential.
  - **Test plan** : `go test ./internal/rdpprobe/` couvre 6 scénarios (cf. spec.md) : success avec cert capture, success avec TLS désactivé, not_rdp sur service HTTP, dial_error sur port fermé, timeout sur serveur silencieux, negotiation_failure sur code `0x05`.

- [ ] **1.2 Faux serveur RDP de test (in-process)**
  - **Notes** : Le test démarre un listener TCP local qui (a) attend de recevoir un X.224 Connection Request, (b) renvoie un X.224 Connection Confirm scriptable (variantes : success+SSL, success sans SSL, failure code `0x05`, silence, raw HTTP), (c) si SSL annoncé et upgrade tenté, présente un cert fixture ECDSA P-256 généré à la volée, (d) **logue tout byte reçu après le X.224 Negotiation Response et fait échouer le test si > 0 byte (hors close-notify TLS).**
  - **Test plan** : Le serveur de test panique (`t.Fatal`) si un byte MCS est observé. Confirme qu'aucun Connect-Initial n'est envoyé.

- [ ] **1.3 Audit anti-auth (linter / grep CI)**
  - **Notes** : `scripts/check_rdp_probe_no_auth.sh` qui exécute `grep -RniE` sur `apps/scanner/internal/rdpprobe/` avec patterns interdits : `password`, `credential`, `username`, `NTLM`, `kerberos`, `CredSSP`, `PasswordCallback`, `gokrb5`, `ntlmssp`. Allowlist : commentaires en début de fichier qui documentent l'interdiction (déclarés en allowlist par regex `^\s*//.*(forbidden|interdit|never|jamais)`).
  - **Test plan** : Le linter passe sur HEAD après §1.1. Test : injecter `var password = "x"` dans `rdpprobe.go` → linter échoue (exit 1). Test : commentaire `// no password ever sent` reste autorisé.

---

## 2. Câblage côté binaire `scanner-service_fingerprint`

- [ ] **2.1 Handler dispatch vers rdpprobe quand port=3389**
  - **Notes** : Étendre `apps/scanner/internal/scanhandler/handler.go` avec une option `RDPProber` (interface `Probe(ctx, target, port) (Result, error)`). Le binaire `scanner-service_fingerprint` injecte un adaptateur backé par `internal/rdpprobe`. Le handler invoque le RDPProber quand `target.kind ∈ {host, ip}` ET (a) `findings.port=3389` OU (b) `options.protocols` inclut `"rdp"`.
  - **Test plan** : Test unitaire : payload avec port 3389 → RDPProber.Probe est appelé une fois avec target.value. Payload sans port 3389 → RDPProber jamais appelé. Cohabitation avec SSHProber : port 22 → SSH, port 3389 → RDP, les deux n'interagissent pas.

- [ ] **2.2 Variables d'environnement `RECONAUT_RDP_PROBE_*`**
  - **Notes** : `RECONAUT_RDP_PROBE_TIMEOUT` (secondes, défaut 5). `RECONAUT_RDP_PROBE_DISABLE_TLS_UPGRADE` (`true`/`1` → désactive le TLS upgrade ; défaut activé). Le binaire `scanner-service_fingerprint/main.go` lit les variables et construit `rdpprobe.Config` en conséquence.
  - **Test plan** : Test unitaire : `RECONAUT_RDP_PROBE_TIMEOUT=2` → la sonde abandonne après 2 s sur un serveur silencieux. `RECONAUT_RDP_PROBE_DISABLE_TLS_UPGRADE=true` → aucun ClientHello envoyé même si SSL annoncé.

---

## 3. Documentation

- [ ] **3.1 Mettre à jour `docs/architecture/scan-frontier.md`**
  - **Notes** : Ajouter une note dans la section *scan_kind* indiquant que `service_fingerprint` couvre désormais RDP (TCP/3389) en plus de SSH (TCP/22). Préciser : pas d'auth, pas de MCS, capture TLS cert opt-out.
  - **Test plan** : `grep -i "rdp" docs/architecture/scan-frontier.md` renvoie ≥ 1 match.

- [ ] **3.2 Mettre à jour `openspec/project.md`**
  - **Notes** : La section *Workers de scan spécialisés* mentionne désormais que `scanner-service_fingerprint` couvre SSH **et RDP** (2e sondeur applicatif livré).
  - **Test plan** : `grep -iE "ssh.*rdp|rdp.*ssh" openspec/project.md` renvoie ≥ 1 match.

---

## 4. Acceptance pour le change dans son ensemble

- [ ] **4.1 Tests automatisés**
  - Au moins six tests Go : (a) success avec cert capturé via TLS upgrade, (b) success sans TLS upgrade (env désactivée), (c) not_rdp contre un service HTTP, (d) dial_error sur port fermé, (e) timeout sur serveur silencieux, (f) negotiation_failure sur code `0x05`.
  - Un test runtime confirme **0 byte envoyé après le X.224 Negotiation Request** (hors TLS handshake quand upgrade actif et close-notify).

- [ ] **4.2 Linter anti-auth en CI**
  - `scripts/check_rdp_probe_no_auth.sh` tourne dans le job `stack-lint` (cf. `scripts/stack-lint.sh`). Une PR qui introduit un pattern interdit dans `apps/scanner/internal/rdpprobe/` est bloquée.

- [ ] **4.3 Audit dépendances**
  - Aucune nouvelle dépendance externe : `crypto/tls`, `encoding/binary`, `net`, `bufio` stdlib uniquement. Confirme via `go mod tidy && git diff go.mod go.sum` ne montre AUCUN changement.

- [ ] **4.4 Le binaire `scanner-service_fingerprint` build statiquement**
  - `CGO_ENABLED=0 go build -o scanner-service_fingerprint ./apps/scanner/cmd/scanner-service_fingerprint` produit un binaire ELF statiquement linké, taille raisonnable (< 20 MB).

- [ ] **4.5 Aucune régression**
  - Toute la suite Go (`cd apps/scanner && go test ./...`) reste verte. SSH probe (`add-ssh-probe`) intacte. Les autres binaires `scanner-<kind>` ne sont pas affectés (l'adaptateur `RDPProber` est nil pour eux).
