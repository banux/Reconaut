# Change : add-mqtt-probe

## Pourquoi

`init-reconaut-platform` §2.5 énumère les sondeurs prévus : HTTP, SSH, RDP, MQTT, CoAP, Modbus. Livrés : SSH (`add-ssh-probe`), HTTP (`add-http-probe`), RDP (`add-rdp-probe`). **MQTT** est le 4e maillon — fingerprint applicatif sur TCP/1883 pour un opérateur ASM qui veut savoir :

- Quels hôtes exposent un broker MQTT (souvent IoT / OT / capteurs industriels — signal de risque non négligeable, surface bruteforcée connue).
- Quel niveau de protocole le broker annonce (3.1.1 vs 5.0).
- Si la connexion anonyme est acceptée (CONNACK return code 0) ou refusée (codes 4, 5 = mauvaise auth / non autorisé) — révèle la posture d'auth du broker sans tenter aucun credential.
- En option : capture du certificat TLS sur le port 8883 (MQTT-over-TLS).

Le pattern `add-rdp-probe` est rodé : package Go dédié, dispatch dans `scanner-service_fingerprint`, linter anti-auth qui empêche toute introduction de credential.

Trois trous concrets que ce change ferme :

1. **Aucun fingerprint MQTT** côté Reconaut. Un opérateur qui scanne un /24 IoT doit utiliser nmap + scripts NSE externes.
2. **Pas de garde anti-bruteforce MQTT**. SSH/RDP ont leur linter, MQTT doit en avoir un — un futur change pourrait introduire `username` / `password` dans le CONNECT (interdit).
3. **Pas de différenciation broker accepte-anonymous vs broker refuse-anonymous**, alors que c'est l'info la plus actionnable pour un audit ASM.

## Ce qui change

1. **Nouveau package Go `apps/scanner/internal/mqttprobe/`**.
   - Exporte `Probe(ctx context.Context, target string, cfg Config) (Result, error)`.
   - `Config` : `Port int` (défaut 1883), `Timeout time.Duration` (défaut 5 s), `TryTLSUpgrade bool` (défaut false ; TLS MQTT se fait classiquement sur un port distinct 8883, le sondeur le détecte par `cfg.Port` ou un flag explicite), `ClientID string` (défaut `""` — empty client ID, le broker doit en assigner un s'il accepte).
   - `Result` :
     - `ProtocolLevel uint8` (3 = MQTT 3.1, 4 = MQTT 3.1.1, 5 = MQTT 5.0)
     - `ReturnCode uint8` (CONNACK code : 0 = accepted, 1-5 = différentes refus standardisés)
     - `ReturnCodeMeaning string` ("accepted" / "unacceptable_protocol_version" / "identifier_rejected" / "server_unavailable" / "bad_username_or_password" / "not_authorized" / "unknown")
     - `SessionPresent bool` (bit du CONNACK qui dit si une session précédente est restaurée — toujours false pour Reconaut puisqu'on envoie clean_session=true)
     - `TLSCertSHA256 string`, `TLSSANs []string`, `TLSNotAfter string` (si port 8883 ou TryTLSUpgrade=true)
     - `DurationMs int`, `BytesReceived int`
     - `Outcome string` (`success` | `not_mqtt` | `dial_error` | `timeout` | `tls_error`)
   - Implémentation : (a) `net.DialContext` TCP + deadline `Timeout`. (b) Si port 8883 ou TLS demandé : `tls.Client(conn, &tls.Config{InsecureSkipVerify: true, ServerName: target})` + `HandshakeContext`, capture cert. (c) Construire **CONNECT MQTT 3.1.1** : Fixed header (`0x10`, remaining length) + Variable header (protocol name "MQTT", protocol level `0x04`, connect flags `0x02` = clean session only, keep alive 60s) + Payload (client_id length-prefixed, vide ou non-identifiant). (d) Lire **CONNACK** : 4 octets — `0x20`, `0x02`, session_present byte, return code byte. (e) **Fermer immédiatement** la connexion via DISCONNECT (`0xE0 0x00`) puis close TCP.
   - **Aucun username/password** dans CONNECT (connect flags bit 6/7 toujours à 0). **Aucun PUBLISH / SUBSCRIBE / UNSUBSCRIBE**.

2. **Câblage dans `scanner-service_fingerprint/main.go`** : ajout d'un `MQTTProber` (parallèle à `SSHProber` et `RDPProber`). Le binaire injecte `mqttprobe`-backed adapter. Lit `RECONAUT_MQTT_PROBE_TIMEOUT`.

3. **Interface `scanhandler.MQTTProber`** ajoutée. Le dispatch `scan_kind=service_fingerprint` invoque MQTTProber quand `target.kind ∈ {host, ip}` ET (a) `findings.port ∈ {1883, 8883}` OU (b) `options.protocols` contient `"mqtt"`. Symétrique à `shouldProbeSSH` / `shouldProbeRDP`.

4. **Linter `scripts/check_mqtt_probe_no_auth.sh`** : refuse dans `apps/scanner/internal/mqttprobe/` :
   - Patterns interdits : `password`, `credential`, `username`, `WillTopic`, `WillMessage` (les "will" sont des payloads que le broker republie — Reconaut ne doit JAMAIS en envoyer).
   - Patterns interdits d'API : `Publish(`, `Subscribe(`, `Unsubscribe(` (en code prod, hors commentaires).
   - Wired in CI stack-lint.

5. **Spec `scanning` enrichie** d'un Requirement *MQTT Broker Probe* qui formalise le contrat (CONNECT only, pas de PUBLISH / SUBSCRIBE, pas d'auth, capture du return code, TLS opt-in sur 8883).

6. **Variables d'environnement** :
   - `RECONAUT_MQTT_PROBE_TIMEOUT` (secondes, défaut 5)
   - `RECONAUT_MQTT_PROBE_DISABLE_TLS_UPGRADE` (`true` pour désactiver capture cert sur 8883 ; défaut activé sur 8883)

## Contraintes

- **Aucune authentification**. Connect flags bits 6 (password) et 7 (username) toujours à 0. Aucun credential dans le code prod (linter statique).
- **Aucun PUBLISH / SUBSCRIBE / UNSUBSCRIBE / PINGREQ**. Le sondeur s'arrête après CONNACK + DISCONNECT.
- **Aucun Will**. Bit 2 des connect flags toujours à 0. Le broker ne publie rien à notre départ.
- **Clean session = 1** systématiquement (bit 1 des connect flags). Le sondeur ne crée pas de session persistante.
- **Client_id non-identifiant**. Défaut vide (le broker doit en générer un s'il accepte) ou une string courte non-corporate. **Interdit** : `"admin"`, `"root"`, ou tout ID qui mime un client légitime.
- **TLS InsecureSkipVerify=true** pour capturer le cert même invalide. Validation a posteriori côté Rails.
- **Timeout strict** par sonde.
- **MQTT 3.1.1** par défaut (level 0x04). MQTT 5.0 peut être tenté en fallback si CONNACK return code 1 (unacceptable_protocol_version).
- **Pas de dépendance externe**. `encoding/binary` + `net` + `crypto/tls` stdlib uniquement. Aucune lib MQTT tierce (eclipse/paho, etc.) pour rester audit-AGPL trivial.

## Non-objectifs (hors scope de ce change)

- **PUBLISH / SUBSCRIBE / lecture de topics** — explicitement INTERDIT. Exigerait d'écouter sur des topics, possiblement de lire des données sensibles (capteurs industriels, etc.). Hors scope définitif sans une décision opérateur explicite (potentiel `add-mqtt-deep-inspection` futur, mais probablement refusé pour des raisons éthiques).
- **Énumération de topics** — relève de la même catégorie : on lirait du contenu utilisateur. Pas en v1.
- **MQTT-over-WebSocket** (port 80/443) — différé. La v1 cible TCP/1883 et TCP/8883 standard.
- **Bruteforce / credential testing** — exclu par construction.
- **MQTT 5.0 reason codes étendus** — en v1 on supporte 3.1.1 nativement. 5.0 retombe sur `ReturnCodeMeaning="unknown"` si on l'utilise.
- **Détection des brokers spécifiques** (Mosquitto, EMQX, HiveMQ) via la signature des CONNACK — différé. Le `Outcome` indique juste "success" + le code retour.

## Décisions prises

1. **Pas de scan_kind dédié `mqtt_probe`**. Le sondeur MQTT est invoqué par `scanner-service_fingerprint` quand le port 1883 (ou 8883) est ciblé, exactement comme SSH / RDP. Cohérent avec la spec `scanning`.
2. **stdlib uniquement**. `encoding/binary` (big-endian MQTT framing) + `crypto/tls` + `net`. Aucune lib MQTT externe (eclipse/paho ferait l'affaire mais inutile pour CONNECT/CONNACK seulement).
3. **TLS upgrade opt-in conditionnel au port**. Sur 8883 (port TLS standard), upgrade activé par défaut. Sur 1883, pas d'upgrade tenté (pas de STARTTLS dans MQTT 3.1.1). Override possible via env.
4. **Client_id par défaut vide**. Choix neutre : ne mime aucun client légitime, ne porte aucune signature Reconaut. Le broker assigne un ID temporaire s'il accepte (sinon il refuse avec return code 2 — qui est lui-même une info utile).
5. **CONNECT MQTT 3.1.1 (level 0x04) par défaut**. C'est le protocole le plus déployé. MQTT 5.0 sera un fallback si return code 1 reçu — différé.
6. **DISCONNECT envoyé avant TCP close**. Trame propre (`0xE0 0x00`) qui signale au broker qu'on s'en va — évite que le broker ne logue une connexion brutalement coupée comme suspicious.
7. **Linter séparé** `check_mqtt_probe_no_auth.sh` (pattern un linter par invariant — déjà établi par SSH/RDP).

## Différé (non bloquant, parqué pour plus tard)

- **`add-mqtt-vulnerability-mapping`** : map `(protocol_level, return_code)` → CVE connues côté brokers (CVE Mosquitto, EMQX, etc.).
- **`add-mqtt-v5-probe`** : support MQTT 5.0 natif + reason codes étendus.
- **`add-mqtt-over-websocket`** : sondage MQTT sur port 80/443 via Upgrade WS.
- **`add-coap-probe`** : 5e sondeur applicatif (§2.5).
- **`add-modbus-probe`** : 6e sondeur applicatif (§2.5).
