# Tâches : add-http-probe

Checklist de l'ajout du sondeur HTTP (banner + headers + Server + HTML + ALPN + TLS cert HTTPS, GET/HEAD only). Pattern aligné sur `add-ssh-probe`.

---

## 1. Sondeur Go

- [x] **1.1 Package `apps/scanner/internal/httpprobe/`**
  - **Notes** : Nouveau package Go avec `httpprobe.go` qui expose :
    ```go
    type Config struct {
      Scheme       string        // "http" ou "https" ; défaut "http"
      Port         int           // défaut 80 (http) ou 443 (https)
      Timeout      time.Duration // défaut 5s
      MaxBodyBytes int           // défaut 32768, max 1024*1024
      UserAgent    string        // défaut "Reconaut/<version> (+...)"
    }
    type Result struct {
      Scheme         string            `json:"scheme"`
      Status         int               `json:"status"`
      Headers        map[string]string `json:"headers"`
      Server         string            `json:"server"`
      BodyExcerpt    string            `json:"body_excerpt"`
      BodyBytes      int               `json:"body_bytes"`
      ALPN           []string          `json:"alpn"`
      TLSCertSHA256  string            `json:"tls_cert_sha256"`
      TLSCertDER     []byte            `json:"tls_cert_der"`
      TLSSANs        []string          `json:"tls_sans"`
      TLSNotAfter    string            `json:"tls_not_after"`
      DurationMs     int               `json:"duration_ms"`
      BytesReceived  int               `json:"bytes_received"`
      Outcome        string            `json:"outcome"`
    }
    func Probe(ctx context.Context, target string, cfg Config) (Result, error)
    ```
    - HTTP client custom :
      ```go
      transport := &http.Transport{
        TLSClientConfig: &tls.Config{
          InsecureSkipVerify: true,
          NextProtos: []string{"h2", "http/1.1"},
          VerifyPeerCertificate: func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
            // capture rawCerts[0] -> result.TLSCertDER, SHA-256, SANs, NotAfter
            return nil
          },
        },
      }
      client := &http.Client{
        Transport: transport,
        Timeout:   cfg.Timeout,
        CheckRedirect: func(...) error { return http.ErrUseLastResponse },
      }
      ```
    - `GET /` uniquement.
    - Body lu via `io.LimitReader(resp.Body, cfg.MaxBodyBytes)`.
    - `bytes_received` reflète le `Content-Length` (ou la taille effectivement lue si chunked).
  - **Test plan** : Spec dédiée `httpprobe_test.go` couvre 8 scénarios :
    1. HTTP 200 contre un faux serveur HTTP local → status, headers, server, body_excerpt.
    2. HTTPS 200 contre un faux serveur TLS local → tls_cert_sha256, tls_cert_der, tls_sans, alpn ∋ "http/1.1" ou "h2".
    3. Cert self-signed expiré toujours capturé (InsecureSkipVerify).
    4. Redirect 301 capturé tel quel (pas de suivi).
    5. Body 1 MiB tronqué à 32 KiB ; body_excerpt.length == 32768.
    6. Port fermé → outcome=dial_error.
    7. Timeout sur serveur lent → outcome=timeout.
    8. User-Agent custom respecté.

- [x] **1.2 Faux serveurs HTTP/HTTPS de test (in-process)**
  - **Notes** : Utilise `httptest.NewServer` (HTTP) et `httptest.NewTLSServer` (HTTPS). Pour le cert self-signed expiré, génère manuellement avec `crypto/x509` un cert avec `NotAfter = time.Now().Add(-1 * time.Hour)` et le passe via `tls.Config.Certificates`.
  - **Test plan** : Inclus dans `httpprobe_test.go` ci-dessus.

- [x] **1.3 Linter `scripts/check_http_probe_no_offensive.sh`**
  - **Notes** : Refuse dans `apps/scanner/internal/httpprobe/` les patterns :
    - Méthodes HTTP : `http\.MethodPost|http\.MethodPut|http\.MethodDelete|http\.MethodPatch|http\.MethodOptions|http\.MethodTrace|http\.MethodConnect`
    - Auth/Cookie : `Authorization|Set-Cookie|Cookie:`
    - Path traversal : `\.\./|%2[eE]%2[eE]`
    - Payload weaponisés : `<script|\$\{jndi:|eval\(|__proto__|<iframe`
    - TLS client cert : `tls\.Certificate\{`
    Tolère les commentaires (`^[^:]+:[0-9]+:[[:space:]]*//`) et les fichiers `_test.go` (qui peuvent mentionner ces patterns dans un test négatif).
  - **Test plan** : `scripts/check_http_probe_no_offensive_test.sh` :
    - Clean tree → exit 0
    - Injection de `http.MethodPost` dans un fichier de prod → exit ≠ 0
    - Injection de `Authorization: Bearer` → exit ≠ 0
    - Injection dans commentaire → exit 0 (toléré)
    - Injection dans `_test.go` → exit 0 (toléré)
    - Cleanup → exit 0

---

## 2. Câblage côté binaire `scanner-http_banner`

- [x] **2.1 Interface `scanhandler.HTTPProber` + dispatch**
  - **Notes** : Ajouter dans `apps/scanner/internal/scanhandler/handler.go` :
    ```go
    type HTTPProber interface {
      Probe(ctx context.Context, target string, port int, scheme string) (HTTPProbeResult, error)
    }
    type HTTPProbeResult struct {
      // mappable 1:1 avec httpprobe.Result, sans coupler scanhandler à httpprobe
    }
    ```
    Dispatch quand `scan_kind == "http_banner"`. Choix scheme : `findings` peut indiquer TLS sur le port ; sinon défaut HTTP/80 si port < 443, HTTPS/443 sinon.
  - **Test plan** : Spec `http_handler_test.go` (4 specs) : (a) port 80 + tcp → scheme=http, (b) port 443 + tls → scheme=https, (c) options.protocols=https → scheme=https, (d) résultat persisté en JSON dans Status.

- [x] **2.2 `scanner-http_banner/main.go` injecte httpprobe**
  - **Notes** : Mettre à jour le binaire pour câbler un `httpAdapter` qui implémente `HTTPProber` en délégant à `internal/httpprobe.Probe`. Lit `RECONAUT_HTTP_PROBE_TIMEOUT`, `RECONAUT_HTTP_PROBE_MAX_BODY_KB`, `RECONAUT_HTTP_PROBE_USER_AGENT`.
  - **Test plan** : Spec `cmd/scanner-http_banner/main_test.go` : timeout=300ms respecté contre serveur silencieux ; body cap effectif.

---

## 3. Documentation

- [x] **3.1 Mise à jour `docs/architecture/scan-frontier.md`**
  - **Notes** : Ajouter une section sous `service_fingerprint` indiquant que `scanner-http_banner` est le **deuxième sondeur applicatif livré**. Mentionne les variables d'env, les outcomes, les contraintes (GET only, redirect non suivi, TLS cert capture).
  - **Test plan** : `grep -ic "http\|http_banner" docs/architecture/scan-frontier.md` retourne ≥ 5.

- [x] **3.2 Mise à jour `openspec/project.md`**
  - **Notes** : La section *Workers de scan spécialisés* mentionne désormais que `scanner-http_banner` couvre HTTP et HTTPS (cert TLS, ALPN, Server, body extract).
  - **Test plan** : `grep -ic "http_banner" openspec/project.md` retourne ≥ 1.

---

## 4. Acceptance pour le change dans son ensemble

- [x] **4.1 Tests automatisés**
  - Au moins 8 tests Go pour `httpprobe` couvrant les 8 scénarios listés en §1.1.
  - Au moins 4 tests Go pour `http_handler` (dispatch).
  - Au moins 1 test Go pour le binaire (`main_test.go`).

- [x] **4.2 Linter anti-offensif en CI**
  - `scripts/check_http_probe_no_offensive.sh` + son test wired dans le job `stack-lint`. Une PR qui introduit `http.MethodPost` dans le sondeur est bloquée.

- [x] **4.3 Audit dépendances**
  - `net/http`, `crypto/tls`, `crypto/x509` (stdlib). Aucune nouvelle dépendance externe non-OSI.

- [x] **4.4 Le binaire `scanner-http_banner` build statiquement**
  - `CGO_ENABLED=0 go build -o scanner-http_banner ./cmd/scanner-http_banner` produit un binaire ELF statiquement linké, taille raisonnable (< 20 MB).

- [x] **4.5 Aucune régression**
  - Toute la suite Go (`apps/scanner && go test ./...`) reste verte. Les autres binaires `scanner-<kind>` ne sont pas affectés.
  - Toute la suite RSpec actuelle reste verte (le sondeur est entièrement côté Go).
  - Tous les linters CI restent verts (y compris le nouveau `check_http_probe_no_offensive.sh`).

- [x] **4.6 Cleanup `compose` / Helm si pertinent**
  - Aucun changement requis : le binaire `scanner-http_banner` est déjà câblé dans `docker-compose.yml` (via `add-helm-chart` futur) et `deploy/helm/reconaut/templates/deployment-scanner.yaml` (boucle Helm sur `scanner.kinds`). Ce change n'introduit pas de service nouveau.
