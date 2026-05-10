# Change : add-http-probe

## Pourquoi

`init-reconaut-platform` §2.5 énumère les sondeurs de protocole prévus : HTTP(S), SSH, RDP, MQTT, CoAP, Modbus. La spec `scanning` impose le scénario explicite *« Service HTTPS détecté sur TCP/443 »* avec capture du certificat TLS feuille (DER + SHA-256 + SAN + `not_after`), des entrées ALPN, des en-têtes de réponse, du token `Server`, et d'un extrait HTML plafonné à 32 KiB. Le scénario *« Service HTTP détecté sur TCP/80 »* (sans TLS) est implicite — banner + Server + HTML.

`add-ssh-probe` a établi le pattern : un package Go dédié sous `apps/scanner/internal/<protocol>probe/`, câblé via le binaire `scanner-<scan_kind>`, avec un linter anti-offensif et un timeout strict configurable. Ce change applique le même pattern à HTTP — c'est le **deuxième sondeur applicatif** livré, et il valide que l'architecture des probes s'étend correctement à un protocole plus complexe (TLS, ALPN, robots.txt, multi-port).

Trois trous concrets que ce change ferme :

1. **`scanner-http_banner` est un squelette no-op.** Le binaire existe (`apps/scanner/cmd/scanner-http_banner/main.go`) mais délègue au runtime générique sans aucun sondeur HTTP — un job `scan:http_banner` ne fait rien.
2. **Pas de capture TLS feuille.** Le scénario *Service HTTPS détecté sur TCP/443* exige le DER complet + SHA-256 + SANs + `not_after`. Aucune infrastructure ne le permet aujourd'hui.
3. **Pas de garde anti-offensif HTTP.** SSH a son linter `check_ssh_probe_no_auth.sh`. HTTP a besoin d'un équivalent : pas de POST, pas d'auth, pas de payload weaponisé, pas de path traversal — *« banner uniquement »*.

## Ce qui change

1. **Nouveau package Go `apps/scanner/internal/httpprobe/`**.
   - Exporte `Probe(ctx context.Context, target string, cfg Config) (Result, error)`.
   - `Config` porte `Port int` (défaut 80 ou 443 selon `Scheme`), `Scheme string` (`"http"` ou `"https"`), `Timeout time.Duration` (défaut 5 s), `MaxBodyBytes int` (défaut 32768).
   - `Result` porte : `Scheme`, `Status int`, `Headers map[string]string`, `Server string`, `BodyExcerpt string` (≤ 32 KiB), `BodyBytes int`, `ALPN []string`, `TLSCertSHA256 string`, `TLSCertDER []byte`, `TLSSANs []string`, `TLSNotAfter time.Time`, `DurationMs int`, `BytesReceived int`, `Outcome string` (`success` | `timeout` | `reset` | `dial_error` | `tls_error`).
   - Implémentation : (a) HTTP client custom avec `Transport` qui hooke `tls.Config.VerifyPeerCertificate` pour capturer le DER, (b) `NextProtos = ["h2", "http/1.1"]` pour ALPN, (c) `GET /` uniquement (pas d'autres paths en v1), (d) lecture du body plafonnée à `MaxBodyBytes`, (e) `User-Agent: Reconaut/<version> (+https://github.com/banux/Reconaut)`.

2. **Câblage dans `scanner-http_banner/main.go`** : équivalent au pattern SSH. Le binaire injecte un `HTTPProber` adapter dans `scanhandler.Options`, lit `RECONAUT_HTTP_PROBE_TIMEOUT` et `RECONAUT_HTTP_PROBE_MAX_BODY_KB`.

3. **Interface `scanhandler.HTTPProber`** ajoutée dans `internal/scanhandler/handler.go`. Le dispatch `scan_kind=http_banner` invoque le prober pour les targets `host`, `ip`, `domain`. Mode HTTP par défaut (port 80) ; HTTPS quand `findings` indique TLS sur le port (typiquement 443).

4. **Linter `scripts/check_http_probe_no_offensive.sh`** : refuse dans `apps/scanner/internal/httpprobe/` :
   - Méthodes HTTP autres que `GET` et `HEAD` (pas de `POST`, `PUT`, `DELETE`, `PATCH`, etc.).
   - Path traversal patterns (`../`, `%2e%2e`, `..%2f`).
   - Auth headers fabriqués (`Authorization: Basic`, `Bearer`).
   - Payload weaponisés (mention de patterns connus : `eval(`, `<script`, `${jndi:`, `__proto__`).
   - Wired in CI stack-lint.

5. **Spec `scanning` enrichie** d'un Requirement *HTTP Banner and TLS Capture* qui formalise le contrat : champs renvoyés, contraintes (GET only, body capped, robots.txt informational), comportement HTTP vs HTTPS.

6. **Variables d'environnement** :
   - `RECONAUT_HTTP_PROBE_TIMEOUT` (secondes, défaut 5)
   - `RECONAUT_HTTP_PROBE_MAX_BODY_KB` (KiB, défaut 32, max 1024)
   - `RECONAUT_HTTP_PROBE_USER_AGENT` (override, défaut `Reconaut/<version> (+https://github.com/banux/Reconaut)`)

7. **ScanJobV1 enrichi** : ajouter à l'enum `target.kind` la prise en charge déjà existante de `host` / `ip` / `domain` pour `http_banner`. Aucun champ schema nouveau.

## Contraintes

- **GET / uniquement en v1**. Pas de path enumeration, pas de POST, pas de form submission. Une future change `add-http-path-enum` pourra ajouter le scan de paths configurables AVEC enforcement strict de `robots.txt`.
- **Body plafonné à 32 KiB par défaut**. Configurable via env mais avec un cap dur à 1 MiB (1024 KiB) pour éviter qu'un opérateur ne se mette en risque mémoire.
- **`HEAD` accepté** mais pas par défaut. Permet à un futur path-enum de vérifier l'existence d'un fichier sans le télécharger. Le linter autorise `http.MethodGet` et `http.MethodHead` uniquement.
- **Pas de redirect suivi**. `Client.CheckRedirect = func(...) error { return http.ErrUseLastResponse }` — on capture la réponse exacte du serveur (incluant 301/302/307/308 + Location), pas la cible finale. Évite de scanner involontairement un host hors scope.
- **Pas d'auth jamais**. Le client n'envoie ni `Authorization` header, ni cookie, ni credentials TLS client. Linter le vérifie statiquement.
- **TLS InsecureSkipVerify=true** par défaut pour le scan (objectif : capturer le certificat même s'il est invalide / expiré / self-signed). Le validation est faite a posteriori par la couche d'analyse Rails.
- **Scope-driven** : la cible passée à `Probe` est supposée déjà validée par `Reconaut::ScanEnqueuer` côté Rails ET par `scopechecker` côté Go (cf. add-ssh-probe + init §2.2). Le sondeur ne re-vérifie pas.
- **Dépendance** : `net/http` + `crypto/tls` stdlib. Pas de gem externe.

## Non-objectifs (hors scope de ce change)

- **Path enumeration** (`/admin`, `/login`, `/.git`, etc.) — relève d'`add-http-path-enum` qui devra strictement respecter `robots.txt`.
- **HTTP/3 / QUIC** — relève d'`add-http3-probe` quand QUIC sera mainstream.
- **WebSocket detection** — relève d'`add-websocket-probe`.
- **Form / API enumeration** (auto-détection d'OpenAPI, Swagger, GraphQL introspection) — relève d'`add-api-enum`.
- **Vulnerability mapping** (CVE OpenSSH-style mapping `Server: nginx/1.18.0` → CVE) — relève d'`add-vulnerability-mapping`.
- **Sondeurs RDP / MQTT / CoAP / Modbus** — chacun fera l'objet d'un change dédié.
- **Rate limiting** par cible / AS — relève d'`add-scanner-rate-limiting` (cf. init §2.3).

## Décisions prises

1. **Pas de scan_kind dédié `https_capture`**. Le sondeur HTTP couvre HTTP et HTTPS via le param `Scheme`. Cohérent avec le tableau scan_kind (un seul `http_banner`). Le `tls_capture` existant reste indépendant : il capture le cert TLS sans toucher à HTTP (utilisable pour SMTP+STARTTLS, IMAP+TLS, etc. — pas seulement HTTPS).
2. **`InsecureSkipVerify=true`** au TLS handshake. Objectif : capturer le cert même invalide. Le scanner n'a pas à juger de la validité — la couche d'analyse Rails le fait avec contexte (CA bundle, chain validation).
3. **`net/http` stdlib** plutôt qu'une lib externe (`fasthttp`, `colly`, etc.). stdlib couvre tout le besoin (custom Transport, hook TLS, ALPN). Ajouter une lib externe = surface d'attaque + audit AGPL non justifié.
4. **`User-Agent` identifiable** par défaut `Reconaut/<version> (+https://github.com/banux/Reconaut)`. Permet à un opérateur scanné de remonter à Reconaut. Override via env si l'opérateur veut anonymiser ou personnaliser. Pas d'usurpation d'identité (`Mozilla/5.0`) par défaut.
5. **Pas de redirect suivi**. Cohérent avec scope-driven : un redirect peut pointer hors scope. On capture la réponse 30x telle quelle ; un futur scan peut être déclenché sur la cible du redirect APRÈS validation scope.
6. **Linter anti-offensif séparé** (`check_http_probe_no_offensive.sh`) plutôt que d'étendre `check_ssh_probe_no_auth.sh`. Cohérent avec le pattern *un linter par invariant*.

## Différé (non bloquant, parqué pour plus tard)

- **`add-http-path-enum`** : path enumeration avec respect strict de `robots.txt`.
- **`add-http3-probe`** : sondage QUIC / HTTP/3.
- **`add-websocket-probe`** : détection des endpoints WebSocket.
- **`add-api-enum`** : auto-détection OpenAPI / GraphQL.
- **`add-vulnerability-mapping`** : map `Server: nginx/X.Y.Z` → CVE.
- **`add-tls-fingerprint-extended`** : JA3, JA3S, JARM (TLS fingerprinting actif).
- **`add-rdp-probe`**, **`add-mqtt-probe`**, **`add-coap-probe`**, **`add-modbus-probe`** : suite des sondeurs §2.5.
