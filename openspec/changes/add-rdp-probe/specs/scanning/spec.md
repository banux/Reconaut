# Spec delta : scanning

## ADDED Requirements

### Requirement: RDP Banner and TLS Capture
La plateforme DOIT exposer un sondeur RDP qui, pour un hôte ou une IP **dans le scope déclaré**, ouvre une connexion TCP sur un port configurable (défaut 3389), envoie un **X.224 Connection Request TPDU** porteur d'un **RDP Negotiation Request** (type `0x01`), lit le **X.224 Connection Confirm** et parse le **RDP Negotiation Response** (type `0x02`) ou **RDP Negotiation Failure** (type `0x03`) pour capturer la **version de protocole** et les **flags de sécurité annoncés**. Si la cible annonce `PROTOCOL_SSL` ET que l'opérateur n'a pas explicitement désactivé l'upgrade TLS, le sondeur DOIT initier un handshake TLS sur la connexion existante uniquement pour **capturer le certificat serveur** (SHA-256, SANs, NotAfter), **sans jamais envoyer le moindre paquet MCS, PDU ou de phase d'authentification**.

Le sondeur DOIT respecter ces contraintes :

- **Aucune authentification** n'est tentée. Pas de password, pas de NTLM, pas de Kerberos, pas de CredSSP, pas de smartcard, pas de hash. Une fois le `RDP Negotiation Response` (et éventuellement le TLS handshake) capturé, la connexion DOIT être fermée immédiatement.
- **Aucun message MCS** n'est envoyé (pas de `MCS Connect-Initial`, pas de `Erect Domain Request`, pas d'`Attach User Request`). Le sondeur s'arrête strictement au niveau X.224 / TLS.
- **`outcome`** parmi `success` | `timeout` | `dial_error` | `not_rdp` | `negotiation_failure` | `tls_error`.
  - `not_rdp` quand TCP s'ouvre mais la réponse n'est pas un X.224 Connection Confirm valide dans le timeout.
  - `negotiation_failure` quand la cible répond avec `type=0x03` (RDP Negotiation Failure) : `negotiation_failure_code` capturé.
  - `tls_error` quand `PROTOCOL_SSL` est annoncé mais le handshake TLS échoue.
- **TLS InsecureSkipVerify=true** : on capture le cert même s'il est expiré, self-signed ou pour un autre CN. La validation est faite a posteriori côté Rails.
- **`Cookie` non-identifiant par défaut** : `mstshash=` (chaîne vide après `=`). Configurable. Aucun défaut qui ressemble à un compte légitime (`mstshash=Administrator` interdit dans le code prod).
- **Timeout strict** par sonde via `RECONAUT_RDP_PROBE_TIMEOUT` (secondes, défaut 5).
- **TLS upgrade opt-out** via `RECONAUT_RDP_PROBE_DISABLE_TLS_UPGRADE=true`. Quand désactivé, le sondeur s'arrête après le `RDP Negotiation Response` même si `PROTOCOL_SSL` est annoncé.
- **Aucun effet de bord** : lecture pure côté cible (côté client, écriture des résultats en stdout JSON pour `scanner-service_fingerprint`). Pas d'écriture de fichier, pas de modification système.
- **Pas de dépendance externe** : `crypto/tls`, `encoding/binary`, `net` stdlib uniquement. Aucune lib RDP tierce.

#### Scenario: Negotiation Response capturée sur TCP/3389
- **GIVEN** un hôte `rdp.example.fr` couvert par le scope avec un service RDP qui répond sur TCP/3389 et annonce `PROTOCOL_RDP | PROTOCOL_SSL | PROTOCOL_HYBRID`
- **WHEN** le sondeur est invoqué via `scanner-service_fingerprint` pour cette cible
- **THEN** le résultat persisté contient `protocol_version` (par ex. `0x00080004`), `security_flags=["PROTOCOL_RDP","PROTOCOL_SSL","PROTOCOL_HYBRID"]`, `outcome=success`
- **AND** un test contre un faux serveur RDP local (qui rejoue un X.224 Connection Confirm canonique) confirme que **aucun byte MCS** n'est envoyé par le sondeur après le `RDP Negotiation Request` (le serveur de test inspecte tous les paquets reçus et fail si un byte arrive après le X.224 CR)

#### Scenario: TLS upgrade capture le certificat serveur
- **GIVEN** un faux serveur RDP qui annonce `PROTOCOL_SSL` puis effectue un handshake TLS avec un cert connu (SAN=`rdp.test.fr`, SHA-256 fixe)
- **WHEN** le sondeur reçoit le `RDP Negotiation Response` et procède à l'upgrade TLS (option `TryTLSUpgrade=true`)
- **THEN** le résultat contient `tls_cert_sha256=<sha256>`, `tls_sans=["rdp.test.fr"]`, `tls_not_after=<rfc3339>`, `outcome=success`
- **AND** un test compare le `tls_cert_sha256` au hash calculé par `openssl x509 -fingerprint -sha256` sur le PEM du cert fixture

#### Scenario: TLS upgrade désactivé via env
- **GIVEN** la même cible avec TLS dispo, mais `RECONAUT_RDP_PROBE_DISABLE_TLS_UPGRADE=true`
- **WHEN** le sondeur est invoqué
- **THEN** le résultat contient `security_flags=["PROTOCOL_SSL", ...]` mais `tls_cert_sha256=""`, `tls_sans=[]`, `tls_not_after=""`, `outcome=success`
- **AND** un test contre le faux serveur confirme qu'**aucun ClientHello TLS** n'est envoyé après le `RDP Negotiation Response`

#### Scenario: Port 3389 ouvert mais protocole non-RDP
- **GIVEN** un hôte qui répond sur TCP/3389 avec un autre protocole (HTTP, raw bytes, silence)
- **WHEN** le sondeur tente la sonde
- **THEN** après le timeout configuré (5 s par défaut), le résultat est `outcome=not_rdp` avec `protocol_version=0`, `security_flags=[]`, `tls_cert_sha256=""`
- **AND** aucun crash, le binaire reste prêt à traiter le job suivant

#### Scenario: Hôte injoignable (TCP refused / host unreachable)
- **GIVEN** une cible hors d'usage
- **WHEN** la connexion TCP échoue
- **THEN** le sondeur retourne `outcome=dial_error` avec un détail textuel court (`connection refused`, `no route to host`, etc.)
- **AND** un test contre un port fermé local (par ex. 127.0.0.1:65535) confirme le comportement

#### Scenario: Negotiation Failure capturée et exposée
- **GIVEN** un faux serveur RDP qui répond avec un `RDP Negotiation Failure` (`type=0x03`, `failureCode=SSL_NOT_ALLOWED_BY_SERVER=0x05`)
- **WHEN** le sondeur lit la réponse
- **THEN** le résultat contient `outcome=negotiation_failure`, `negotiation_failure_code=0x05`, `protocol_version=0`, `security_flags=[]`
- **AND** la connexion est fermée immédiatement, aucun byte supplémentaire envoyé

#### Scenario: Aucune authentification jamais tentée (audit statique)
- **GIVEN** le code source de `apps/scanner/internal/rdpprobe/`
- **WHEN** le script `scripts/check_rdp_probe_no_auth.sh` est exécuté en CI
- **THEN** il échoue (exit ≠ 0) si l'un des patterns interdits apparaît dans un fichier `.go` du package : `password`, `credential`, `username`, `\bdomain\b` (hors contexte commentaire/`tld_domain`), `NTLM`, `kerberos`, `CredSSP`, `PasswordCallback`, `gokrb5`, `ntlmssp`
- **AND** un test contre un fixture qui introduit volontairement le mot `password` confirme que le linter détecte l'infraction
- **AND** le linter est exécuté par `scripts/stack-lint.sh` (job CI bloquant)

#### Scenario: Aucun MCS Connect-Initial envoyé (audit runtime)
- **GIVEN** un faux serveur RDP local qui logue chaque byte reçu APRÈS avoir envoyé le `RDP Negotiation Response`
- **WHEN** le sondeur est exécuté contre ce serveur
- **THEN** le serveur de test observe **0 byte** post-negotiation (ou seulement le `Close TLS Notify` si TLS upgrade a eu lieu), confirmant qu'aucun MCS Connect-Initial n'est jamais envoyé
- **AND** ce test est exécuté à chaque CI `go test ./internal/rdpprobe/...`
