# Change : add-worker-modbus

## Pourquoi

`init-reconaut-platform` §2.5 énumère 6 sondeurs applicatifs : HTTP, SSH, RDP, MQTT, CoAP, **Modbus**. Livrés : SSH (`add-ssh-probe`), HTTP (`add-http-probe`), RDP (`add-rdp-probe`), MQTT (`add-mqtt-probe`), CoAP (`add-coap-probe`). **Modbus** est le **6e et dernier maillon** — fingerprint applicatif sur TCP/502 pour un opérateur ASM qui veut savoir :

- Quels hôtes exposent un automate ou un device industriel parlant Modbus TCP.
- Quel **vendor / produit / révision** (via la fonction `Read Device Identification`, 0x2B/0x0E) — l'info la plus actionnable pour un audit OT.
- Si le device est joignable mais ne supporte pas l'identification, un fallback `Read Holding Registers` (0x03) à l'adresse 0 confirme au moins que c'est un endpoint Modbus.

Modbus est **le protocole OT le plus déployé** (PLC industriels, capteurs IoT, contrôleurs HVAC, onduleurs solaires…) et **historiquement le plus exposé à internet** sans authentification — les rapports Shodan en remontent des dizaines de milliers en accès direct. C'est précisément le genre de surface qu'un outil ASM doit aider à identifier.

Trois trous concrets que ce change ferme :

1. **Aucun fingerprint Modbus** côté Reconaut. Un opérateur qui scanne un /24 industriel doit utiliser nmap NSE externe + scripts ad-hoc.
2. **Risque inhérent au protocole** : Modbus supporte des fonctions **mutantes terribles** : `Write Single Coil` (0x05), `Write Multiple Registers` (0x10), `Diagnostics/Restart` (0x08 sub-fn 0x01 — reset le device !). Un sondeur naïf pourrait introduire ces fonctions et **causer un arrêt industriel** ou pire. Il faut un linter statique brutal qui refuse leur présence dès l'écriture.
3. **Pas de captation `vendor/product/revision`**, alors que c'est l'info qui permet de croiser avec une base CVE OT (Schneider, Siemens, Rockwell…) et faire un audit ASM utile.

Le pattern `add-coap-probe` est rodé : package Go dédié, dispatch dans `scanner-service_fingerprint`, linter anti-offensif brutal.

## Ce qui change

1. **Nouveau package Go `apps/scanner/internal/modbusprobe/`**.
   - Exporte `Probe(ctx context.Context, target string, cfg Config) (Result, error)`.
   - `Config` : `Port int` (défaut 502), `Timeout time.Duration` (défaut 5 s), `UnitID byte` (défaut 1 — adresse de l'esclave par défaut, généralement 1 ou 255).
   - `Result` :
     - `VendorName string` (par ex. `"Schneider Electric"`)
     - `ProductCode string` (par ex. `"BMENOC0301"`)
     - `MajorMinorRevision string` (par ex. `"2.10"`)
     - `FunctionCode uint8` (la fonction qui a réussi : 0x2B si identification a marché, 0x03 si fallback Read Holding Registers, 0 si rien)
     - `ExceptionCode uint8` (0 = pas d'exception ; 1-11 si le serveur a renvoyé une exception)
     - `ExceptionMeaning string` (par ex. `"Illegal Function"`)
     - `IsModbus bool` (true si on a reçu une réponse MBAP valide, même en exception)
     - `DurationMs int`, `BytesReceived int`
     - `Outcome string` (`success` | `not_modbus` | `timeout` | `dial_error`)
   - Implémentation : (a) `net.DialContext` TCP + deadline `Timeout`. (b) Tentative 1 — envoyer un **MBAP + PDU = Read Device Identification** (function 0x2B, sub-function 0x0E, ReadDeviceIDCode=0x01 basic). Parser la réponse : si function code = 0x2B → extraire vendor/product/revision (chaînes typées par object_id 0x00, 0x01, 0x02). (c) Si function code = 0xAB (0x2B | 0x80 = exception sur 0x2B) → fallback : envoyer un **Read Holding Registers** (function 0x03) à l'adresse 0, quantity 1. Si réponse 0x03 → IsModbus=true mais sans détails identification. (d) Fermer immédiatement.
   - **Méthodes acceptées en code prod** : `0x03` (Read Holding Registers, read-only), `0x2B` (Encapsulated Interface Transport — Read Device Identification, read-only). **Tout le reste interdit** par le linter.

2. **Câblage dans `scanner-service_fingerprint/main.go`** : ajout d'un `ModbusProber` (parallèle à SSH/RDP/MQTT/CoAP). Lit `RECONAUT_MODBUS_PROBE_TIMEOUT` et `RECONAUT_MODBUS_PROBE_UNIT_ID`.

3. **Interface `scanhandler.ModbusProber`** ajoutée. Dispatch quand `target.kind ∈ {host, ip}` ET (a) `findings.port=502` OU (b) `options.protocols` contient `"modbus"`.

4. **Linter `scripts/check_modbus_probe_no_write.sh`** : refuse dans `apps/scanner/internal/modbusprobe/` (hors `_test.go`) :
   - Patterns interdits : `WriteSingleCoil`, `WriteMultipleCoils`, `WriteSingleRegister`, `WriteMultipleRegisters`, `MaskWriteRegister`, `ReadWriteMultipleRegisters`, `Diagnostics`, `Restart`, `ForceCoil`, `PresetRegister`.
   - Patterns interdits par **opcode** : `0x05`, `0x06`, `0x0F`, `0x10`, `0x17`, `0x08` dans le contexte « function code » (allowlist via regex pour les contextes non function-code, par ex. `len < 0x10` qui est un test de taille).
   - Pour simplifier, je n'interdis pas les opcodes par valeur (trop de faux positifs) — je m'appuie sur les noms symboliques. Le code prod n'utilise que `fnReadHoldingRegisters = 0x03` et `fnReadDeviceID = 0x2B`. Tout autre nom symbolique est suspect.

5. **Spec `scanning` enrichie** d'un Requirement *Modbus TCP Device Fingerprint* qui formalise le contrat (READ functions only, pas de Diagnostics, pas de mutations).

6. **Variables d'environnement** :
   - `RECONAUT_MODBUS_PROBE_TIMEOUT` (secondes, défaut 5).
   - `RECONAUT_MODBUS_PROBE_UNIT_ID` (1-255, défaut 1).

## Contraintes

- **READ functions uniquement**. Les fonctions de classe 0x05/0x06/0x0F/0x10/0x17 (writes) et 0x08 (Diagnostics — peut **reset le device !**) sont INTERDITES par construction. Linter statique.
- **Tentatives limitées à 2 paquets max**. Une seule tentative `Read Device Identification`, puis au max une tentative fallback `Read Holding Registers`. Pas de retry, pas de scan d'adresses multiples.
- **Pas d'énumération de Unit IDs**. Une seule sonde par target avec `UnitID` fixe (défaut 1). Pas de boucle de 1..255.
- **Pas de discovery par broadcast**. Modbus TCP est unicast par construction (contrairement à CoAP où le multicast existe), donc pas de surface multicast — mais on documente l'invariant.
- **Pas de Modbus RTU/ASCII**. Seul Modbus **TCP** est sondé. RTU exigerait un port série, hors scope ASM internet.
- **Timeout strict** par sonde.
- **Pas de DTLS / TLS**. Modbus TCP n'est jamais chiffré en pratique ; le standard `Modbus/TCP Security` existe (CASIA-Crypto) mais quasiment jamais déployé. Différé.
- **Pas de dépendance externe**. `encoding/binary` + `net` stdlib uniquement. Aucune lib Modbus externe (par ex. `goburrow/modbus`) — surface minimale, audit AGPL trivial.
- **Lecture du Read Device Identification plafonnée** au "basic" set (object_id 0..2 : VendorName, ProductCode, MajorMinorRevision). Les sets "regular" et "extended" exposent plus d'objets mais sont moins universellement supportés.

## Non-objectifs (hors scope de ce change)

- **Toutes les fonctions write** (0x05, 0x06, 0x0F, 0x10, 0x17) — INTERDITES par construction.
- **Diagnostics (0x08)** — INTERDITE (peut reset/silence un device).
- **Modbus RTU et Modbus ASCII** (séries) — hors scope.
- **Modbus over UDP** — non standard, ignoré.
- **Énumération multi Unit-ID** (1..255) — différé. Risque de stress device + bruit.
- **Énumération de registres** (lire 1..N) au-delà d'un single fallback (0..0) — exclu, ce serait une cartographie offensive.
- **Modbus/TCP Security (CASIA-Crypto)** — différé à un futur `add-modbus-tcp-security`.
- **Détection vendor-spécifique** (Schneider, Siemens, Rockwell) avec heuristiques sur les chaînes — différé. Le sondeur expose juste les chaînes brutes, l'analyse côté Rails / agent IA fera le mapping.
- **Probing via Modbus encapsulé dans HTTP/Modbus-RTU-over-TCP** (pas le vrai Modbus TCP, mais variantes parfois rencontrées) — exclu.

## Décisions prises

1. **Pas de scan_kind dédié `modbus_probe`**. Le sondeur Modbus est invoqué par `scanner-service_fingerprint` quand le port 502 est ciblé, exactement comme SSH/RDP/MQTT/CoAP.
2. **stdlib uniquement**. `encoding/binary` (big-endian MBAP) + `net.DialContext`. Pas de lib externe.
3. **Unit ID défaut = 1**. Convention la plus universelle pour Modbus TCP (l'adresse esclave est rarement non-1 en TCP, mais certains gateways utilisent 255).
4. **Tentative Read Device Identification d'abord, fallback Read Holding Registers**. L'identification est l'info la plus actionnable ; le fallback garantit qu'on détecte un device Modbus même s'il ne supporte pas l'identification.
5. **Linter par noms symboliques** plutôt que par opcodes hex. Les noms (`WriteSingleCoil`, etc.) sont sans ambiguïté ; les opcodes (`0x05`) auraient trop de faux positifs.
6. **Pas de retry du MBAP**. Un single shot. Modbus TCP au-dessus de TCP — la retransmission est gérée par TCP lui-même ; pas besoin de retransmission applicative.
7. **Object_id basic only (0x00, 0x01, 0x02)**. VendorName, ProductCode, MajorMinorRevision. Suffisant pour la v1.

## Différé (non bloquant, parqué pour plus tard)

- **`add-modbus-tcp-security`** : support Modbus/TCP Security (CASIA-Crypto sur TLS).
- **`add-modbus-cve-mapping`** : mapping `(vendor, product, revision)` → CVE connues côté brokers OT (NVD CISA ICS feeds).
- **`add-modbus-rtu-probe`** : Modbus RTU sur série / serial-to-IP. Niche, mais utile pour audits internes.
- **`add-modbus-extended-objects`** : Read Device Identification sets `regular` (0x02) et `extended` (0x03) pour récupérer URL produit, nom utilisateur, etc.
- **Modbus est le DERNIER sondeur §2.5**. Après ce change, la section §2.5 d'init-reconaut-platform est entièrement couverte (HTTP / SSH / RDP / MQTT / CoAP / Modbus). On peut alors cocher `2.5` dans init-reconaut-platform/tasks.md.
