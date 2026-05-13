# Spec delta : scanning

## ADDED Requirements

### Requirement: CoAP Discovery Probe
La plateforme DOIT exposer un sondeur CoAP qui, pour un hôte ou une IP **dans le scope déclaré**, ouvre un socket UDP sur un port configurable (défaut 5683), envoie un **paquet CoAP GET `/.well-known/core`** confirmable (RFC 6690), lit la réponse et capture le **response code** + le **content-format** + un **excerpt** du payload (le link-format dump).

Le sondeur DOIT respecter ces contraintes :

- **Méthode = GET UNIQUEMENT** (code byte `0x01`). Aucun PUT/POST/DELETE dans le code prod (linter statique).
- **Uri-Path fixe** à `/.well-known/core`. Aucune énumération de paths.
- **Pas d'option Observe** (option 6). Le sondeur N'EST PAS un client persistant.
- **Pas d'envoi à des adresses multicast** (`224.0.1.187` etc.). Le target est toujours unicast. Refusé statiquement par linter ET au runtime.
- **Confirmable (CON), single shot**. Pas de retransmission, pas de keep-alive. Timeout strict via `RECONAUT_COAP_PROBE_TIMEOUT` (défaut 5 s).
- **Pas de DTLS en v1** — différé.
- **Pas de dépendance externe** : `net`, `encoding/binary`, `crypto/rand` stdlib uniquement.
- **Payload excerpt plafonné** à 4096 bytes.
- **`Outcome`** parmi `success` | `not_coap` | `timeout` | `dial_error`.

#### Scenario: GET /.well-known/core retourne 2.05 Content avec link-format
- **GIVEN** un serveur CoAP sur UDP/5683 qui répond `2.05 Content` avec content-format=40 (application/link-format) au path `/.well-known/core`
- **WHEN** le sondeur est invoqué via `scanner-service_fingerprint` avec `findings.port=5683`
- **THEN** le résultat persisté contient `response_code_class=2`, `response_code_detail=5`, `response_code_meaning="2.05 Content"`, `content_format=40`, `payload_excerpt` non vide, `outcome="success"`
- **AND** un test contre un faux serveur CoAP local confirme qu'**aucun paquet ne suit le premier GET** envoyé par le sondeur (pas de retransmission, pas de second GET).

#### Scenario: Réponse 4.04 Not Found (pas de /.well-known/core mais service CoAP)
- **GIVEN** un serveur CoAP qui n'expose pas `/.well-known/core` et répond `4.04 Not Found`
- **WHEN** le sondeur envoie sa requête
- **THEN** le résultat contient `response_code_class=4`, `response_code_detail=4`, `response_code_meaning="4.04 Not Found"`, `outcome="success"` (la sonde a réussi à fingerprint le service, même si la ressource standard n'est pas là)
- **AND** `payload_excerpt` peut être vide ou contenir un message d'erreur.

#### Scenario: Port 5683 ouvert mais protocole non-CoAP
- **GIVEN** un service qui répond sur UDP/5683 avec du raw garbage ou silence
- **WHEN** le sondeur tente la sonde
- **THEN** après le timeout (5 s par défaut), `outcome` est `not_coap` (réponse parsée invalide) ou `timeout` (silence)
- **AND** aucun crash, le binaire reste prêt.

#### Scenario: Hôte injoignable (UDP n'a pas de connexion mais le timeout déclenche)
- **GIVEN** une cible avec port UDP/5683 fermé (ICMP port unreachable) ou silencieuse
- **WHEN** le sondeur envoie son GET
- **THEN** le résultat est `outcome="dial_error"` (si ICMP unreachable arrive) ou `outcome="timeout"` (si silence pur).

#### Scenario: Aucune méthode mutante ni Observe (audit statique)
- **GIVEN** le code source de `apps/scanner/internal/coapprobe/`
- **WHEN** `scripts/check_coap_probe_no_offensive.sh` est exécuté en CI
- **THEN** il échoue (exit ≠ 0) si l'un des patterns interdits apparaît dans un `.go` non-test : `POST`, `PUT`, `DELETE`, `Observe`, `multicast`, `224.0.1.187`
- **AND** un test contre une injection de chaque pattern confirme la détection
- **AND** le linter est wired dans `.github/workflows/ci.yml`.

#### Scenario: Adresse multicast refusée au runtime
- **GIVEN** un target ayant pour valeur `224.0.1.187` (all-CoAP-nodes multicast)
- **WHEN** le sondeur est invoqué
- **THEN** il rejette la cible et retourne `outcome="dial_error"` avec un détail "multicast forbidden", SANS jamais ouvrir de socket UDP
- **AND** un test unitaire vérifie l'invariant.

#### Scenario: Payload excerpt plafonné
- **GIVEN** un serveur CoAP qui retourne 10 KB de link-format
- **WHEN** le sondeur lit la réponse
- **THEN** `payload_excerpt` ne dépasse PAS 4096 bytes
- **AND** un test fixture vérifie le plafond.
