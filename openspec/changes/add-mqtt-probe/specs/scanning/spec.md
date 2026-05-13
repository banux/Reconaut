# Spec delta : scanning

## ADDED Requirements

### Requirement: MQTT Broker Probe
La plateforme DOIT exposer un sondeur MQTT qui, pour un hôte ou une IP **dans le scope déclaré**, ouvre une connexion TCP sur un port configurable (défaut 1883, 8883 pour TLS), envoie un **paquet MQTT CONNECT** sans aucun credential, lit le **CONNACK** et capture la **version protocolaire annoncée** + le **return code** + le **session_present flag**. Le sondeur DOIT respecter ces contraintes :

- **Aucune authentification**. Les bits 6 (password) et 7 (username) des connect flags DOIVENT être à 0. Aucun champ `Username` / `Password` n'apparaît dans le payload CONNECT.
- **Aucun Will**. Le bit 2 des connect flags DOIT être à 0. Le broker ne reçoit aucun message à republier au départ du sondeur.
- **Clean session = 1**. Le bit 1 des connect flags est toujours à 1 — le sondeur ne crée AUCUNE session persistante.
- **Aucun PUBLISH / SUBSCRIBE / UNSUBSCRIBE / PINGREQ**. Le sondeur s'arrête après CONNACK puis envoie DISCONNECT (`0xE0 0x00`) avant de fermer la connexion TCP.
- **client_id non-identifiant**. Défaut vide (le broker doit en assigner un s'il accepte) ou une string courte non-corporate. Interdit dans le code prod : `admin`, `root`, ou tout ID qui mime un client légitime.
- **`Outcome`** parmi `success` | `timeout` | `dial_error` | `not_mqtt` | `tls_error`.
- **TLS InsecureSkipVerify=true** pour capturer le cert même invalide. Validation a posteriori côté Rails.
- **MQTT 3.1.1 (level 0x04)** par défaut.
- **Timeout strict** par sonde via `RECONAUT_MQTT_PROBE_TIMEOUT` (secondes, défaut 5).
- **TLS upgrade** : activé par défaut sur port 8883, désactivable via `RECONAUT_MQTT_PROBE_DISABLE_TLS_UPGRADE=true`.
- **Aucune dépendance externe**. `crypto/tls` + `encoding/binary` + `net` stdlib uniquement.

#### Scenario: CONNECT + CONNACK accepted (return code 0)
- **GIVEN** un broker MQTT sur TCP/1883 qui accepte les connexions anonymes
- **WHEN** le sondeur est invoqué via `scanner-service_fingerprint` avec `findings.port=1883`
- **THEN** le résultat persisté contient `protocol_level=4`, `return_code=0`, `return_code_meaning="accepted"`, `session_present=false`, `outcome="success"`
- **AND** un test contre un faux broker local confirme que **aucun byte autre que CONNECT puis DISCONNECT** n'a été envoyé par le sondeur (en particulier, AUCUN PUBLISH / SUBSCRIBE / PINGREQ).

#### Scenario: CONNECT rejected (return code 5 = not_authorized)
- **GIVEN** un broker MQTT qui refuse les connexions anonymes avec return code 5
- **WHEN** le sondeur envoie un CONNECT (sans username/password)
- **THEN** le résultat contient `return_code=5`, `return_code_meaning="not_authorized"`, `outcome="success"` (la sonde a réussi à fingerprint le broker, même si l'auth a été refusée)
- **AND** le sondeur N'ESSAIE PAS de retry avec des credentials.

#### Scenario: CONNECT rejected (return code 1 = unacceptable protocol version)
- **GIVEN** un broker MQTT qui refuse MQTT 3.1.1 (broker v5.0 only par ex.)
- **WHEN** le sondeur envoie un CONNECT avec protocol_level=0x04
- **THEN** le résultat contient `return_code=1`, `return_code_meaning="unacceptable_protocol_version"`, `outcome="success"`
- **AND** le sondeur N'ESSAIE PAS de re-tenter avec MQTT 5.0 en v1 (différé à `add-mqtt-v5-probe`).

#### Scenario: TLS upgrade sur 8883 capture le certificat
- **GIVEN** un faux broker MQTT-over-TLS sur 8883 avec un cert de test (SAN=`mqtt.test.fr`)
- **WHEN** le sondeur est invoqué avec `findings.port=8883` (TryTLSUpgrade activé par défaut)
- **THEN** le résultat contient `tls_cert_sha256=<sha256>`, `tls_sans=["mqtt.test.fr"]`, `tls_not_after=<rfc3339>` ET `return_code=0` (le CONNECT/CONNACK passent dans le canal TLS)
- **AND** un test compare `tls_cert_sha256` au hash calculé par `openssl x509 -fingerprint -sha256`.

#### Scenario: TLS désactivé via env
- **GIVEN** un broker TLS sur 8883 et `RECONAUT_MQTT_PROBE_DISABLE_TLS_UPGRADE=true`
- **WHEN** le sondeur est invoqué
- **THEN** le résultat contient `outcome="tls_error"` ou `outcome="not_mqtt"` (le broker n'accepte pas le CONNECT en clair sur 8883) ET `tls_cert_sha256=""`
- **AND** un test confirme qu'**aucun ClientHello TLS** n'a été envoyé par le sondeur.

#### Scenario: Port 1883 ouvert mais protocole non-MQTT
- **GIVEN** un hôte qui répond sur TCP/1883 avec un autre protocole (HTTP, SSH, raw bytes, silence)
- **WHEN** le sondeur tente la sonde
- **THEN** après le timeout configuré (5 s par défaut), le résultat est `outcome="not_mqtt"` avec `return_code=0`, `protocol_level=0`, `tls_cert_sha256=""`
- **AND** aucun crash, le binaire reste prêt à traiter le job suivant.

#### Scenario: Hôte injoignable
- **GIVEN** une cible hors d'usage (port fermé)
- **WHEN** la connexion TCP échoue
- **THEN** le sondeur retourne `outcome="dial_error"` avec un détail textuel court (`connection refused`, etc.).

#### Scenario: Aucune authentification jamais tentée (audit statique)
- **GIVEN** le code source de `apps/scanner/internal/mqttprobe/`
- **WHEN** le script `scripts/check_mqtt_probe_no_auth.sh` est exécuté en CI
- **THEN** il échoue (exit ≠ 0) si l'un des patterns interdits apparaît dans un fichier `.go` non-test : `password`, `credential`, `username`, `WillTopic`, `WillMessage`, `Publish(`, `Subscribe(`, `Unsubscribe(`
- **AND** un test contre un fixture qui introduit volontairement `var password = "x"` confirme la détection
- **AND** le linter est wired dans `scripts/stack-lint.sh` / `.github/workflows/ci.yml`.

#### Scenario: Aucun byte post-CONNACK autre que DISCONNECT (audit runtime)
- **GIVEN** un faux broker MQTT local qui logue chaque byte reçu APRÈS avoir envoyé le CONNACK
- **WHEN** le sondeur est exécuté contre ce broker
- **THEN** le serveur de test observe **uniquement 2 bytes** post-CONNACK : `0xE0 0x00` (DISCONNECT), puis EOF
- **AND** ce test est exécuté à chaque CI `go test ./internal/mqttprobe/...`.
