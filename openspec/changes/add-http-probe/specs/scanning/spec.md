# Spec delta : scanning

## ADDED Requirements

### Requirement: HTTP Banner and TLS Capture
La plateforme DOIT exposer un sondeur HTTP qui, pour un hôte ou une IP **dans le scope déclaré**, ouvre une connexion TCP sur un port configurable (défaut 80 pour HTTP, 443 pour HTTPS), envoie une requête `GET /` lecture-seule, et capture les en-têtes de réponse, le token `Server`, un extrait HTML plafonné, les ALPN entries (HTTPS), et le certificat TLS feuille (HTTPS uniquement) — **sans jamais tenter d'authentification, de POST, ni de path traversal**.

Le sondeur DOIT respecter ces contraintes :

- **Méthodes HTTP** : `GET` et `HEAD` UNIQUEMENT. Toute mention de `POST`, `PUT`, `DELETE`, `PATCH`, etc. dans le code du sondeur DOIT faire échouer la CI via le linter `check_http_probe_no_offensive.sh`.
- **Pas d'authentification** : aucun header `Authorization`, aucun cookie, aucun client cert. Vérifié statiquement par le linter.
- **Pas de payload weaponisé** : pas de `eval(`, `<script`, `${jndi:`, `__proto__`, `../`, `%2e%2e`, etc. dans les chaînes envoyées par le sondeur.
- **Pas de redirect suivi** : `Client.CheckRedirect` retourne `http.ErrUseLastResponse` ; on capture la réponse 30x telle quelle (statut, Location, body partiel).
- **Body plafonné** : par défaut 32 KiB (`RECONAUT_HTTP_PROBE_MAX_BODY_KB=32`), max dur 1 MiB (1024 KiB). Au-delà, le body est tronqué et `bytes_received` reflète la taille avant troncation.
- **Timeout strict** : par défaut 5 s (`RECONAUT_HTTP_PROBE_TIMEOUT=5`). Une cible lente ne bloque pas le binaire.
- **TLS InsecureSkipVerify=true** pour le scan : on capture le certificat même s'il est invalide / expiré / self-signed. La validation est faite a posteriori par la couche d'analyse Rails avec un CA bundle.
- **`outcome`** parmi `success` | `timeout` | `reset` | `dial_error` | `tls_error`. `tls_error` quand le handshake TLS échoue avant qu'on capture le cert (rare avec InsecureSkipVerify).
- **`User-Agent` identifiable** par défaut : `Reconaut/<version> (+https://github.com/banux/Reconaut)`. Override via `RECONAUT_HTTP_PROBE_USER_AGENT`.

#### Scenario: Service HTTP détecté sur TCP/80
- **GIVEN** un hôte `example.fr` couvert par le scope avec un nginx qui répond sur TCP/80
- **WHEN** le sondeur est invoqué via `scanner-http_banner` avec `scheme=http` port 80
- **THEN** le résultat persisté contient `status=200` (ou autre 2xx/3xx/4xx selon le serveur), `headers` map non-vide, `server="nginx/1.18.0"` (extrait du header `Server`), `body_excerpt` ≤ 32768 octets
- **AND** `outcome=success`
- **AND** `tls_cert_sha256` est vide (HTTP sans TLS)

#### Scenario: Service HTTPS détecté sur TCP/443
- **GIVEN** un hôte `example.fr` couvert par le scope avec un serveur HTTPS valide sur TCP/443
- **WHEN** le sondeur est invoqué avec `scheme=https` port 443
- **THEN** le résultat contient `tls_cert_sha256` (hex 64 chars), `tls_cert_der` (octets DER complets), `tls_sans` (Array de SAN), `tls_not_after` (RFC3339)
- **AND** `alpn` contient au moins une entrée parmi `h2`, `http/1.1`
- **AND** `body_excerpt` ≤ 32768 octets, `server` extrait du header `Server`
- **AND** `outcome=success`

#### Scenario: Cert TLS expiré ou self-signed est quand même capturé
- **GIVEN** un hôte HTTPS avec un certificat self-signed expiré
- **WHEN** le sondeur tente la sonde
- **THEN** `tls_cert_der` ET `tls_cert_sha256` sont quand même capturés (validation a posteriori)
- **AND** `outcome=success` (le scan a réussi à observer le service ; la (in)validité est métadonnée à analyser côté Rails)

#### Scenario: Pas de redirect suivi (réponse 30x capturée telle quelle)
- **GIVEN** un hôte qui retourne `301 Location: https://other.example.com/`
- **WHEN** le sondeur effectue `GET /`
- **THEN** la réponse capturée a `status=301` et `headers["Location"]="https://other.example.com/"`
- **AND** AUCUN suivi de redirect — la cible `other.example.com` n'est PAS scannée (relèverait du scope-driven enforcement avant un nouveau scan)

#### Scenario: Body capped à 32 KiB
- **GIVEN** un hôte qui retourne 1 MiB de HTML
- **WHEN** le sondeur effectue `GET /` avec `MaxBodyBytes=32768` (défaut)
- **THEN** `body_excerpt` fait exactement 32768 octets
- **AND** `bytes_received` reflète la taille totale lue (≥ 32768) avec une indication de troncation

#### Scenario: Connexion refusée → dial_error
- **GIVEN** un port fermé sur l'hôte cible (ex. TCP/8080 fermé)
- **WHEN** le sondeur tente la sonde
- **THEN** `outcome=dial_error`
- **AND** aucun body, aucun cert capturés

#### Scenario: Aucune méthode HTTP autre que GET/HEAD utilisée
- **GIVEN** le code source du sondeur sous `apps/scanner/internal/httpprobe/`
- **WHEN** un test grep cherche `http.MethodPost|http.MethodPut|http.MethodDelete|http.MethodPatch|MethodOptions|MethodTrace|MethodConnect`
- **THEN** **aucun** match dans le code de prod (les fichiers `_test.go` peuvent les mentionner pour vérifier l'invariant)
- **AND** un linter CI `check_http_probe_no_offensive.sh` enforce cet invariant

#### Scenario: Pas d'auth header fabriqué
- **GIVEN** le code source du sondeur
- **WHEN** un test grep cherche `Authorization|Set-Cookie|Cookie|tls.Certificate{`
- **THEN** **aucun** match dans le code de prod
- **AND** le linter le confirme (allowlist : aucune)

#### Scenario: Pas de payload weaponisé
- **GIVEN** le code source du sondeur
- **WHEN** un test grep cherche les patterns `\.\./|%2e%2e|<script|\${jndi:|eval\(|__proto__|<iframe`
- **THEN** **aucun** match dans le code de prod
- **AND** le linter `check_http_probe_no_offensive.sh` rejette une PR qui en introduit
