# Spec delta : scanning

## ADDED Requirements

### Requirement: Modbus TCP Device Fingerprint
La plateforme DOIT exposer un sondeur Modbus TCP qui, pour un hôte ou une IP **dans le scope déclaré**, ouvre une connexion TCP sur un port configurable (défaut 502), envoie un **Modbus TCP MBAP+PDU** porteur de la fonction **Read Device Identification (0x2B / sub-function 0x0E)** avec ReadDeviceIDCode=0x01 (basic), parse la réponse pour extraire `vendor_name`, `product_code`, `major_minor_revision`, et **si cette fonction n'est pas supportée** par le device, fait UN seul fallback vers **Read Holding Registers (0x03)** à l'adresse 0, quantity 1 pour au moins confirmer que c'est un endpoint Modbus.

Le sondeur DOIT respecter ces contraintes :

- **READ functions uniquement**. Codes acceptés en code prod : `0x03` (Read Holding Registers, read-only) et `0x2B` (Encapsulated Interface Transport, read-only). Codes INTERDITS : `0x05` (Write Single Coil), `0x06` (Write Single Register), `0x0F` (Write Multiple Coils), `0x10` (Write Multiple Registers), `0x17` (Read/Write Multiple Registers, partie write), `0x08` (Diagnostics — peut reset le device).
- **Pas d'énumération de Unit IDs**. Une seule sonde par target avec un `UnitID` fixe (défaut 1, configurable via `RECONAUT_MODBUS_PROBE_UNIT_ID`).
- **Au plus 2 paquets envoyés** par sonde : 1 Read Device Identification, optionnellement 1 fallback Read Holding Registers si exception. Pas de retry au niveau applicatif.
- **Pas de Modbus RTU/ASCII** ni Modbus over UDP. Modbus TCP unicast standard uniquement.
- **`Outcome`** parmi `success` | `not_modbus` | `timeout` | `dial_error`. Un device qui renvoie une exception Modbus (`function_code | 0x80`) reste `outcome=success` ET `is_modbus=true` (la sonde a réussi à fingerprint le device, même si l'identification a été refusée).
- **Timeout strict** par sonde via `RECONAUT_MODBUS_PROBE_TIMEOUT` (secondes, défaut 5).
- **Pas de dépendance externe** : `net` + `encoding/binary` stdlib uniquement. Aucune lib Modbus tierce.

#### Scenario: Read Device Identification réussit → vendor + product + revision capturés
- **GIVEN** un device Modbus TCP sur 502 qui supporte la fonction 0x2B/0x0E avec vendor="Schneider Electric", product="BMENOC0301", revision="2.10"
- **WHEN** le sondeur est invoqué via `scanner-service_fingerprint` avec `findings.port=502`
- **THEN** le résultat contient `function_code=0x2B`, `vendor_name="Schneider Electric"`, `product_code="BMENOC0301"`, `major_minor_revision="2.10"`, `is_modbus=true`, `outcome="success"`
- **AND** un test contre un faux serveur Modbus local confirme qu'**EXACTEMENT UN paquet** est envoyé après la TCP handshake (le Read Device ID — pas de fallback Read Holding nécessaire puisque la 1ère a réussi).

#### Scenario: Read Device Identification refusée (exception 0xAB) → fallback Read Holding
- **GIVEN** un device Modbus TCP qui ne supporte PAS la fonction 0x2B (renvoie exception code 0x01 "Illegal Function" sur 0xAB) MAIS supporte 0x03 Read Holding Registers
- **WHEN** le sondeur tente la sonde
- **THEN** le résultat contient `function_code=0x03` (le fallback qui a réussi), `is_modbus=true`, `outcome="success"`, vendor/product/revision vides
- **AND** un test contre le faux serveur confirme qu'**EXACTEMENT 2 paquets** ont été envoyés (la 1ère tentative + le fallback) et aucun autre.

#### Scenario: Device ne supporte ni 0x2B ni 0x03 → outcome=success mais is_modbus=true
- **GIVEN** un device qui renvoie exception pour les deux fonctions (devices très restrictifs)
- **WHEN** le sondeur tente la sonde puis le fallback
- **THEN** `is_modbus=true`, `exception_code` non-zéro, `outcome="success"`
- **AND** vendor/product/revision sont vides.

#### Scenario: Port 502 ouvert mais protocole non-Modbus
- **GIVEN** un service qui répond sur TCP/502 avec un autre protocole (HTTP, raw, silence)
- **WHEN** le sondeur tente la sonde
- **THEN** après timeout ou réponse invalide, `outcome="not_modbus"` et `is_modbus=false`.

#### Scenario: Hôte injoignable
- **GIVEN** une cible avec port 502 fermé
- **WHEN** la connexion TCP échoue
- **THEN** `outcome="dial_error"`.

#### Scenario: Timeout silence pur
- **GIVEN** un service qui ouvre TCP mais n'écrit jamais
- **WHEN** le sondeur attend la réponse
- **THEN** `outcome="timeout"`, pas de crash.

#### Scenario: Aucune méthode write ni Diagnostics (audit statique)
- **GIVEN** le code source de `apps/scanner/internal/modbusprobe/`
- **WHEN** `scripts/check_modbus_probe_no_write.sh` est exécuté en CI
- **THEN** il échoue (exit ≠ 0) si l'un des patterns interdits apparaît dans un `.go` non-test : `WriteSingleCoil`, `WriteMultipleCoils`, `WriteSingleRegister`, `WriteMultipleRegisters`, `MaskWriteRegister`, `ReadWriteMultipleRegisters`, `Diagnostics`, `Restart`, `ForceCoil`, `PresetRegister`
- **AND** un test contre l'injection successive de chaque pattern interdit confirme la détection
- **AND** le linter est wired dans `.github/workflows/ci.yml`.

#### Scenario: Au plus 2 paquets envoyés par sonde (audit runtime)
- **GIVEN** un faux serveur Modbus qui logue chaque paquet TCP reçu
- **WHEN** le sondeur est exécuté contre ce serveur (n'importe quel scénario)
- **THEN** le serveur observe **AU PLUS 2 paquets** Modbus (le 1er Read Device ID + l'éventuel fallback Read Holding) — jamais plus
- **AND** ce test est exécuté à chaque CI `go test ./internal/modbusprobe/...`.
