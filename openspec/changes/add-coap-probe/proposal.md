# Change : add-coap-probe

## Pourquoi

`init-reconaut-platform` §2.5 énumère 6 sondeurs applicatifs : HTTP, SSH, RDP, MQTT, **CoAP**, Modbus. Livrés : SSH, HTTP, RDP, MQTT. **CoAP** est le 5e — fingerprint applicatif sur UDP/5683 (et /5684 pour DTLS, différé) pour un opérateur ASM qui veut savoir :

- Quels hôtes exposent un serveur CoAP (largement IoT / OT — capteurs LoRaWAN, sonnerie domotique, dispositifs industriels).
- Quel **discovery resource** (RFC 6690) est annoncé via `GET /.well-known/core` — le standard CoAP de listing des ressources exposées (équivalent IoT du `robots.txt`).
- Quel **content-format** le serveur retourne (application/link-format = 40, etc.).

Le pattern `add-mqtt-probe` est rodé : package Go dédié, dispatch dans `scanner-service_fingerprint`, linter anti-offensif qui empêche toute introduction de mutation (PUT/POST/DELETE/Observe).

Trois trous concrets que ce change ferme :

1. **Aucun fingerprint CoAP** côté Reconaut. Un opérateur qui scanne un /24 IoT doit utiliser `coap-client` externe.
2. **Risque inhérent au protocole** : CoAP supporte des méthodes **mutantes** (PUT, POST, DELETE). Un sondeur naïf pourrait introduire ces méthodes — il faut un linter statique pour le refuser dès l'écriture du code (analogue à `check_http_probe_no_offensive.sh`).
3. **`/.well-known/core`** est l'info la plus actionnable : elle révèle la surface exposée par un device sans déclencher d'effet de bord. La fingerprinter c'est précieux pour un audit ASM.

## Ce qui change

1. **Nouveau package Go `apps/scanner/internal/coapprobe/`**.
   - Exporte `Probe(ctx context.Context, target string, cfg Config) (Result, error)`.
   - `Config` : `Port int` (défaut 5683), `Timeout time.Duration` (défaut 5 s). Pas de DTLS en v1 (différé).
   - `Result` :
     - `ResponseCodeClass uint8` (0-7 : 0=Method, 2=Success, 4=Client Error, 5=Server Error)
     - `ResponseCodeDetail uint8` (0-31)
     - `ResponseCodeMeaning string` (par ex. "2.05 Content", "4.04 Not Found", "5.00 Internal Server Error")
     - `ContentFormat int` (option 12 : `40` = application/link-format, `50` = JSON, `60` = CBOR, etc. ; `-1` si absente)
     - `PayloadExcerpt string` (le link-format dump, plafonné à 4096 bytes)
     - `DurationMs int`, `BytesReceived int`
     - `Outcome string` (`success` | `not_coap` | `timeout` | `dial_error`)
   - Implémentation : (a) `net.ListenUDP` (ou `net.DialUDP`) pour ouvrir un socket UDP. (b) Construire **CoAP GET /.well-known/core** : header (Ver=01, Type=00 CON, TKL=2) + code 0x01 (GET) + Message ID (uint16 BE) + Token (2 bytes random) + Uri-Path option `well-known` + Uri-Path option `core`. (c) Envoyer le paquet via `WriteToUDP`. (d) Lire la réponse via `ReadFromUDP` avec deadline `Timeout`. (e) Parser le header de réponse : extraire code (byte[1]), scanner les options pour trouver Content-Format (option 12), extraire le payload après le marker `0xFF`. (f) Fermer.
   - **Méthode = GET UNIQUEMENT**. Code byte 0x01. **Interdit** dans le code prod : 0x02 (POST), 0x03 (PUT), 0x04 (DELETE).
   - **Option Observe (6) interdite** : Reconaut ne s'abonne JAMAIS à un endpoint pour recevoir des notifications répétées.
   - **Uri-Path fixe** : `/.well-known/core` uniquement. Pas d'énumération de paths.

2. **Câblage dans `scanner-service_fingerprint/main.go`** : ajout d'un `CoAPProber` (parallèle à SSH/RDP/MQTT). Le binaire injecte `coapprobe`-backed adapter. Lit `RECONAUT_COAP_PROBE_TIMEOUT`.

3. **Interface `scanhandler.CoAPProber`** ajoutée. Le dispatch invoque CoAPProber quand `target.kind ∈ {host, ip}` ET `findings.port=5683` OU `options.protocols` contient `"coap"`.

4. **Linter `scripts/check_coap_probe_no_offensive.sh`** : refuse dans `apps/scanner/internal/coapprobe/` (hors `_test.go`) :
   - Patterns interdits : `POST`, `PUT`, `DELETE`, `Observe`, `multicast`, `224.0.1.187` (adresse multicast CoAP all-nodes — broadcast offensif).
   - Allowlist commentaires + chaînes `return "X.YY Meaning"` qui décrivent les codes de réponse.

5. **Spec `scanning` enrichie** d'un Requirement *CoAP Discovery Probe* qui formalise le contrat (GET only, uniquement `/.well-known/core`, pas d'Observe, pas de multicast, pas de mutation).

6. **Variables d'environnement** :
   - `RECONAUT_COAP_PROBE_TIMEOUT` (secondes, défaut 5).

## Contraintes

- **GET uniquement**. Code byte 0x01 (méthode 0.01). Aucun PUT/POST/DELETE dans le code prod (linter statique).
- **`/.well-known/core` uniquement**. Pas d'énumération de paths via brute-force d'URIs ; pas de découverte heuristique.
- **Pas d'option Observe** (option 6). Reconaut ne s'abonne pas — un seul GET, une seule réponse, terminé.
- **Pas de multicast**. La cible est toujours unicast IP ; pas de `coap://224.0.1.187/...`. Refuser les addresses multicast dans le code prod (linter) et au runtime (Probe rejette si target est une multicast IP).
- **Confirmable (CON) request, single shot**. Pas de retransmission, pas de keep-alive. Si la réponse n'arrive pas dans le timeout, c'est `timeout`.
- **Pas de DTLS** en v1. La cible UDP/5684 n'est pas sondée — différé.
- **Timeout strict** par sonde.
- **Pas de dépendance externe**. `encoding/binary` + `net` + `crypto/rand` stdlib uniquement. Aucune lib CoAP tierce (ocf/go-coap, etc.) pour rester audit-AGPL trivial.
- **Payload excerpt plafonné** à 4096 bytes — protège contre un serveur qui répond avec un payload énorme.

## Non-objectifs (hors scope de ce change)

- **Énumération de paths arbitraires** — explicitement INTERDIT. Le sondeur s'arrête à `/.well-known/core`.
- **PUT / POST / DELETE / Observe** — INTERDITS par construction.
- **DTLS / CoAPS sur 5684** — différé à `add-coap-dtls-probe` (DTLS pas en stdlib Go, exigerait pion/dtls ou équivalent ; évaluation sécurité séparée).
- **Block-wise transfer** (option 23) — un serveur qui répond en plusieurs blocs sera tronqué au premier bloc. Acceptable pour la v1 (le link-format reste utile en premier bloc).
- **Multicast discovery** (envoyer à 224.0.1.187 pour découvrir tous les CoAP nodes du LAN) — interdit, offensif.
- **MQTT-SN** (Message Queue Telemetry Transport for Sensor Networks) — protocole distinct, pas inclus.

## Décisions prises

1. **Pas de scan_kind dédié `coap_probe`**. Le sondeur CoAP est invoqué par `scanner-service_fingerprint` quand le port 5683 est ciblé, exactement comme SSH/RDP/MQTT.
2. **stdlib uniquement**. `encoding/binary` (big-endian MID) + `crypto/rand` (token) + `net.UDPConn`. Aucune lib CoAP externe.
3. **UDP par défaut**. CoAP standard sur UDP/5683. DTLS sur 5684 différé.
4. **Token 2 bytes**, random. Standard CoAP pour matcher la réponse à la requête.
5. **Message ID random**. Pour résister à un faux serveur qui réutiliserait un MID statique.
6. **Confirmable (CON) plutôt que NON-confirmable**. CON force le serveur à ACK — meilleure fiabilité pour le diagnostic. Pas de retransmission côté Reconaut quand même.
7. **Linter séparé** `check_coap_probe_no_offensive.sh` (pattern un linter par invariant).

## Différé (non bloquant, parqué pour plus tard)

- **`add-coap-dtls-probe`** : sondage CoAPS sur UDP/5684 avec capture cert (exigerait pion/dtls ou DTLS natif Go ; pas en stdlib).
- **`add-coap-blockwise`** : support transfer block-wise (option 23) pour récupérer des link-format > MTU.
- **`add-coap-vulnerability-mapping`** : map du discovery → CVE connues (Tasmota, ESP-NOW, etc.).
- **`add-modbus-probe`** : 6e et dernier sondeur applicatif (§2.5).
