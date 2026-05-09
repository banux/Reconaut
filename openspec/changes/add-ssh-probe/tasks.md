# Tâches : add-ssh-probe

Checklist de l'ajout du sondeur SSH (banner + host-key SHA-256, sans authentification). Chaque tâche inclut des notes d'implémentation et un test plan qui DOIT passer avant de cocher la case.

---

## 1. Sondeur Go

- [x] **1.1 Package `apps/scanner/internal/sshprobe/`**
  - **Notes** : Nouveau package Go avec `sshprobe.go` qui expose :
    ```go
    type Config struct {
      Port    int           // défaut 22
      Timeout time.Duration // défaut 5s
    }
    type Result struct {
      Banner        string `json:"banner"`
      HostKeySHA256 string `json:"hostkey_sha256"` // format "sha256:<base64>"
      DurationMs    int    `json:"duration_ms"`
      BytesReceived int    `json:"bytes_received"`
      Outcome       string `json:"outcome"` // success | timeout | reset | not_ssh | dial_error
    }
    func Probe(ctx context.Context, target string, cfg Config) (Result, error)
    ```
  - Implémentation : (a) ouvrir TCP avec `net.DialContext` + deadline `Timeout`, (b) lire la première ligne via `bufio.Reader.ReadString('\n')`, (c) si la ligne ne commence pas par `SSH-`, retourner `outcome=not_ssh`, (d) sinon, écrire notre propre bannière `SSH-2.0-Reconaut\r\n` puis utiliser `ssh.NewClientConn` avec un `HostKeyCallback` qui capture la clé et retourne `errKeyCaptured`, (e) calculer `ssh.FingerprintSHA256(key)`.
  - **Pas d'authentification** : `ClientConfig.Auth = nil` (slice vide, pas de méthode déclarée).
  - **Test plan** : `go test ./internal/sshprobe/` couvre 5 scénarios (cf. spec) : success contre un faux serveur, not_ssh sur un service HTTP, dial_error sur port fermé, timeout sur un serveur silencieux, fingerprint identique à `ssh.FingerprintSHA256`.

- [x] **1.2 Faux serveur SSH de test (in-process)**
  - **Notes** : Le test démarre un serveur SSH local via `ssh.NewServerConn` avec `ServerConfig{NoClientAuth: false, PasswordCallback: t.Fatal-on-call, PublicKeyCallback: t.Fatal-on-call}`. Génère une clé hôte ECDSA P-256 fraîche pour chaque test (rapide, ~ms). Ferme proprement après que le client se soit déconnecté.
  - **Test plan** : Le serveur ne reçoit JAMAIS de message `userauth-request` (les callbacks ne sont jamais invoqués). Le test panique si l'un des callbacks est appelé — preuve que le sondeur ne tente aucune auth.

- [x] **1.3 Audit anti-auth (linter / grep CI)**
  - **Notes** : `scripts/check_ssh_probe_no_auth.sh` qui exécute `grep -RnE 'ssh\.Password|ssh\.PublicKeys|ssh\.KeyboardInteractive|ssh\.RetryableAuthMethod' apps/scanner/internal/sshprobe/` et fait échouer le check si une occurrence est trouvée. Allowlist : aucune.
  - **Test plan** : Le linter passe sur HEAD après §1.1. Test : injecter `ssh.Password("x")` dans `sshprobe.go` → linter échoue.

---

## 2. Câblage côté binaire `scanner-service_fingerprint`

- [x] **2.1 Handler dispatch vers sshprobe quand port=22**
  - **Notes** : Étendre `apps/scanner/internal/scanhandler/handler.go` avec une option `SSHProber` (interface `Probe(ctx, target, port) (Result, error)`). Le binaire `scanner-service_fingerprint` injecte un adaptateur backé par `internal/sshprobe`. Le handler invoque le SSHProber quand `target.kind=host` ET le payload `findings` contient `{port:22}` (ou quand `options.protocols` inclut `"ssh"`).
  - **Test plan** : Test unitaire : payload avec port 22 → SSHProber.Probe est appelé une fois avec target.value en argument. Payload sans port 22 → SSHProber jamais appelé.

- [x] **2.2 Variables d'environnement `RECONAUT_SSH_PROBE_*`**
  - **Notes** : `RECONAUT_SSH_PROBE_TIMEOUT` (secondes, défaut 5). Le binaire `scanner-service_fingerprint/main.go` lit la variable et la passe à `sshprobe.Config{Timeout}`.
  - **Test plan** : Test unitaire : `RECONAUT_SSH_PROBE_TIMEOUT=2` → la sonde abandonne après 2 s sur un serveur silencieux.

---

## 3. Documentation

- [x] **3.1 Mettre à jour `docs/architecture/scan-frontier.md`**
  - **Notes** : Ajouter une note dans la section *scan_kind* indiquant que `service_fingerprint` invoque maintenant un sondeur SSH quand le port 22 est ciblé.
  - **Test plan** : `grep -i "ssh" docs/architecture/scan-frontier.md` renvoie ≥ 1 match.

- [x] **3.2 Mettre à jour `openspec/project.md`**
  - **Notes** : La section *Workers de scan spécialisés* mentionne désormais que `scanner-service_fingerprint` couvre SSH (premier sondeur applicatif livré).
  - **Test plan** : `grep -i "ssh" openspec/project.md` renvoie ≥ 1 match.

---

## 4. Acceptance pour le change dans son ensemble

- [x] **4.1 Tests automatisés**
  - Au moins cinq tests Go : (a) success contre un faux serveur SSH local, (b) not_ssh contre un service HTTP, (c) dial_error sur port fermé, (d) timeout, (e) fingerprint identique à `ssh.FingerprintSHA256`.

- [x] **4.2 Linter anti-auth en CI**
  - `scripts/check_ssh_probe_no_auth.sh` tourne dans le job `stack-lint`. Une PR qui introduit `ssh.Password(...)` ou équivalent est bloquée.

- [x] **4.3 Audit dépendances**
  - `golang.org/x/crypto/ssh` est sous BSD-3 (compatible AGPL). Aucune nouvelle dépendance externe non-OSI introduite.

- [x] **4.4 Le binaire `scanner-service_fingerprint` build statiquement**
  - `CGO_ENABLED=0 go build -o scanner-service_fingerprint ./apps/scanner/cmd/scanner-service_fingerprint` produit un binaire ELF statiquement linké, taille raisonnable (< 20 MB).

- [x] **4.5 Aucune régression**
  - Toute la suite Go (`apps/scanner && go test ./...`) reste verte. Les autres binaires `scanner-<kind>` ne sont pas affectés (l'adaptateur `SSHProber` est nil pour eux).
