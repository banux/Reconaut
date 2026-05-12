# Change : add-rdp-probe

## Pourquoi

`init-reconaut-platform` §2.5 énumère les sondeurs prévus : HTTP(S), SSH, RDP, MQTT, CoAP, Modbus. SSH (`add-ssh-probe`) et HTTP (`add-http-probe`) sont livrés. **RDP** est le 3e maillon — fingerprint applicatif sur TCP/3389 pour un opérateur ASM qui veut savoir :

- Quels hôtes exposent un RDP (signal de risque connu — surface bruteforcée / cible BlueKeep / etc.).
- Quels protocoles de sécurité sont annoncés (RDP standard, TLS, CredSSP, RDSTLS).
- Si TLS est négociable, capturer le certificat (SAN, NotAfter, SHA-256) — utile pour détecter cert self-signed ou rotation suspecte.

Le pattern `add-ssh-probe` est rodé : package Go dédié, dispatch dans `scanner-service_fingerprint`, linter anti-auth qui empêche toute introduction d'authentification dans le code de prod. Ce change applique le même pattern à RDP — le 3e sondeur applicatif, premier protocole binaire (vs SSH/HTTP qui sont textuels).

Trois trous concrets que ce change ferme :

1. **Aucun fingerprint RDP** côté Reconaut. Un opérateur qui veut savoir si son /16 expose des RDP doit utiliser nmap externe + ingest manuel.
2. **Pas de garde anti-bruteforce RDP**. SSH a son `check_ssh_probe_no_auth.sh`. Sans équivalent RDP, un futur change pourrait introduire `ssh.PasswordAuth`-style credentials dans le code RDP — invisible jusqu'à l'audit.
3. **Pas de capture cert TLS quand RDP/TLS est annoncé**. Inférence sécurité utile (cert rotation, CN/SAN suspects).

## Ce qui change

1. **Nouveau package Go `apps/scanner/internal/rdpprobe/`**.
   - Exporte `Probe(ctx context.Context, target string, cfg Config) (Result, error)`.
   - `Config` : `Port int` (défaut 3389), `Timeout time.Duration` (défaut 5 s), `TryTLSUpgrade bool` (défaut true), `Cookie string` (défaut `mstshash=`, valeur générique non-identifiante).
   - `Result` : `ProtocolVersion uint32`, `SecurityFlags []string` (parmi `PROTOCOL_RDP`, `PROTOCOL_SSL`, `PROTOCOL_HYBRID`, `PROTOCOL_RDSTLS`, `PROTOCOL_HYBRID_EX`), `NegotiationFailureCode uint32`, `TLSCertSHA256 string`, `TLSSANs []string`, `TLSNotAfter string`, `DurationMs int`, `BytesReceived int`, `Outcome string` (`success` | `not_rdp` | `dial_error` | `timeout` | `tls_error` | `negotiation_failure`).
   - Implémentation : (a) ouverture TCP/3389, (b) envoi d'un **X.224 Connection Request TPDU** avec `RDP Negotiation Request` (`type=0x01`, `requestedProtocols=PROTOCOL_RDP|SSL|HYBRID|RDSTLS|HYBRID_EX` pour maximiser la réponse), (c) lecture du **X.224 Connection Confirm** + parsing du `RDP Negotiation Response` (type `0x02`) ou `RDP Negotiation Failure` (type `0x03`), (d) si `PROTOCOL_SSL` flag positionné dans la réponse ET `TryTLSUpgrade=true` : upgrade TLS via `tls.Client(conn, &tls.Config{InsecureSkipVerify: true})`, capture du cert via `VerifyPeerCertificate`, **arrêt immédiat après le handshake** (pas de MCS Connect-Initial, pas de PDU, pas d'auth).
   - **Aucun MCS/PDU**, **aucune phase userauth**, **aucun mot de passe / NTLM / Kerberos / CredSSP credential** envoyé.

2. **Câblage dans `scanner-service_fingerprint/main.go`** : ajout d'un `RDPProber` (parallèle à `SSHProber`). Le binaire injecte `rdpprobe`-backed adapter. Lit `RECONAUT_RDP_PROBE_TIMEOUT`, `RECONAUT_RDP_PROBE_DISABLE_TLS_UPGRADE`.

3. **Interface `scanhandler.RDPProber`** ajoutée. Le dispatch `scan_kind=service_fingerprint` invoque RDPProber quand `target.kind ∈ {host, ip}` ET (a) `findings.port=3389` OU (b) `options.protocols` contient `"rdp"`. Symétrique à `shouldProbeSSH` (cf. add-ssh-probe §2.1).

4. **Linter `scripts/check_rdp_probe_no_auth.sh`** : refuse dans `apps/scanner/internal/rdpprobe/` :
   - Patterns `password|credential|username|domain[^_]|NTLM|kerberos|credssp\.|hash[A-Z]|ntlmssp` (case-insensitive, sauf TLS qui peut mentionner `kerberos` dans une CertificateRequest type — on filtre par contexte).
   - Plus simple : refuse tout import qui pourrait servir l'auth (par ex. `golang.org/x/crypto/ssh/.*PasswordCallback`, `github.com/jcmturner/gokrb5`, etc.).
   - Wired in CI stack-lint.

5. **Spec `scanning` enrichie** d'un Requirement *RDP Banner and TLS Capture* qui formalise le contrat (X.224 only, pas de MCS, pas d'auth, TLS upgrade opt-in pour capture cert).

6. **Variables d'environnement** :
   - `RECONAUT_RDP_PROBE_TIMEOUT` (secondes, défaut 5)
   - `RECONAUT_RDP_PROBE_DISABLE_TLS_UPGRADE` (`true` pour désactiver l'upgrade ; défaut activé)

## Contraintes

- **Aucune authentification ni énumération**. Pas de password, pas de NTLM, pas de Kerberos, pas de CredSSP. Le sondeur s'arrête après le `RDP Negotiation Response` (+ éventuel TLS handshake). Aucun message MCS Connect-Initial n'est envoyé.
- **Pas de PoC BlueKeep ni de payload weaponisé**. Le sondeur ne déclenche aucun chemin de code exploitable. Read-only sur le segment de protocole exposé en première seconde.
- **`Cookie` non-identifiant par défaut**. Valeur `"mstshash="` (cookie standard vide, équivalent à un client Microsoft RDC qui n'a pas encore négocié de nom). Configurable via `Cookie` champ de Config.
- **TLS InsecureSkipVerify=true** pour capturer le cert même invalide. Validation a posteriori côté Rails (même pattern qu'add-http-probe).
- **Timeout strict** par sonde. Une cible lente ne bloque pas le binaire.
- **Pas de redirect / pas de re-connect**. Le sondeur fait UN seul handshake, capture, ferme la connexion.
- **Pas d'auth dans le code source**. Linter `check_rdp_probe_no_auth.sh` enforce statiquement.
- **Scope-driven** : Rails + scopechecker Go valident la cible AVANT que Probe ne soit invoqué.
- **Dépendance** : `crypto/tls` + `encoding/binary` stdlib uniquement. Pas de lib RDP externe (pour rester audit-AGPL trivial).

## Non-objectifs (hors scope de ce change)

- **MCS Connect-Initial / Erect Domain Request / userauth** — explicitement INTERDIT en v1. Tout ce qui dépasse le `RDP Negotiation Response` est différé à un futur change après évaluation sécurité approfondie.
- **Détection BlueKeep / CVE-2019-0708** — relève d'`add-vulnerability-mapping` (mapping `protocol_version + security_flags` → CVE).
- **Capture screenshot RDP** — exigerait MCS + GCC + I/O channels. Hors scope définitif.
- **Bruteforce / authentication probing** — exclu par construction.
- **Détection NLA (Network Level Authentication)** activée/désactivée — déductible des `SecurityFlags` (`PROTOCOL_HYBRID` ou `PROTOCOL_HYBRID_EX` indique NLA actif). Pas de probing supplémentaire.
- **Capture ALPN sur le TLS upgrade** — RDP/TLS n'utilise pas ALPN négocié comme HTTPS ; on capture juste le cert.
- **Support de RDP-over-UDP (RDPUDP)** — différé. La v1 cible TCP/3389 standard.

## Décisions prises

1. **Pas de scan_kind dédié `rdp_probe`**. Le sondeur RDP est invoqué par `scanner-service_fingerprint` quand le port 3389 est ciblé, exactement comme SSH (cf. add-ssh-probe). Cohérent avec la spec `scanning` qui parle de *« fingerprinting de ports/services »* comme capacité unifiée.
2. **stdlib uniquement**. `encoding/binary` (big-endian X.224 TPKT framing) + `crypto/tls` + `net`. Aucune lib RDP externe (par ex. `github.com/c-sto/recang` ou autres) — audit AGPL trivial, surface d'attaque minimale.
3. **TLS upgrade opt-in par défaut**. Activé sauf si `RECONAUT_RDP_PROBE_DISABLE_TLS_UPGRADE=true`. Permet à un opérateur prudent de désactiver complètement le TLS handshake (par ex. en environnement sensible où même un handshake TLS pourrait être logué côté cible).
4. **Cookie générique `mstshash=`**. Pas d'usurpation d'identité (`mstshash=Administrator` qui mimerait un domaine corp), pas de fingerprint Reconaut spécifique (qui rendrait le sondeur trivialement détectable et trivialement bloquable). Choix neutre : cookie vide standard.
5. **TLS cert capture obligatoire quand l'upgrade réussit**. Pas de mode "upgrade TLS mais ne capture pas le cert" — si on TLS, on capture (cohérent avec `add-http-probe` HTTPS).
6. **Linter séparé** `check_rdp_probe_no_auth.sh` (pattern *un linter par invariant* déjà établi par SSH).

## Différé (non bloquant, parqué pour plus tard)

- **`add-rdp-vulnerability-mapping`** : map `(version, security_flags)` → CVE connues (BlueKeep, DejaBlue, etc.).
- **`add-rdpudp-probe`** : sondage RDP-over-UDP / RDP Gateway.
- **`add-rdp-deep-inspection`** : capture des channels MCS sans auth (analytics-only).
- **`add-mqtt-probe`** : suite §2.5 — 4e sondeur applicatif.
- **`add-coap-probe`** : 5e sondeur.
- **`add-modbus-probe`** : 6e sondeur.
