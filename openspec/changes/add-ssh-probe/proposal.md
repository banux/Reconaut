# Change : add-ssh-probe

## Pourquoi

Le change `init-reconaut-platform` §2.5 énumère les sondeurs de protocole prévus : HTTP(S), SSH, RDP, MQTT, CoAP, Modbus. La spec `scanning` impose le scénario explicite « Bannière SSH capturée sur TCP/22 » :

> **WHEN** TCP/22 est ouvert sur un hôte
> **THEN** la bannière de protocole SSH (par ex. `SSH-2.0-OpenSSH_8.9p1`) et le fingerprint de la host-key (SHA-256) sont enregistrés ; aucune tentative d'authentification n'est effectuée

Le binaire `scanner-service_fingerprint` est livré sous forme de squelette (cf. `replace-web-with-tui` §3.1), mais ne contient encore aucun sondeur de protocole concret — il appelle le `scanhandler` no-op du runtime partagé. Ce change livre **le premier sondeur applicatif** : SSH banner + host-key fingerprint, sans authentification.

L'angle SSH est volontairement le premier de la série :

1. **Surface étroite** : un seul port (22 par défaut), un protocole texte simple en début de session.
2. **Pas d'écho HTML 32 KiB** ni d'ALPN comme HTTP : le résultat tient en deux champs (`banner`, `hostkey_sha256`).
3. **Bibliothèque stdlib-friendly** : `golang.org/x/crypto/ssh` couvre l'intégralité du KEX nécessaire pour récupérer la clé hôte, sans authentification, sous BSD-3.
4. **Cas d'usage à valeur immédiate** pour un opérateur ASM : un SSH avec une bannière connue (`OpenSSH 7.6p1 Ubuntu` qui révèle un host non patché) ou une host-key qui change d'une fois sur l'autre est un signal de risque concret.

## Ce qui change

1. **Nouveau package Go : `apps/scanner/internal/sshprobe/`**.
   - Exporte `Probe(ctx context.Context, target string, cfg Config) (Result, error)`.
   - `Config` porte `Port int` (défaut 22), `Timeout time.Duration` (défaut 5 s).
   - `Result` porte `Banner string`, `HostKeySHA256 string` (hex sans préfixe), `DurationMs int`, `BytesReceived int`, `Outcome string` (`success` | `timeout` | `reset` | `not_ssh` | `dial_error`).
   - Implémentation : (a) ouverture TCP, (b) lecture de la première ligne (banner), (c) `ssh.NewClientConn` avec un `HostKeyCallback` qui capture la clé puis renvoie une erreur volontaire pour court-circuiter l'authentification, (d) calcul du SHA-256 sur les octets marshalés (`ssh.MarshalAuthorizedKey` → octets de `key.Marshal()`).
   - **Pas d'authentification** : `ClientConfig.Auth = nil` ; le test vérifie qu'aucun `AuthLogCallback` du serveur de test n'est invoqué (seul le KEX a lieu).

2. **Câblage dans `scanner-service_fingerprint`** : le binaire utilise désormais un `DispatchHandler` qui, pour `scan_kind=service_fingerprint` et un payload portant `findings[port=22]` ou simplement `target.kind=host`, invoque `sshprobe.Probe` et persiste un finding typé. Le no-op précédent reste pour les autres ports — un autre change introduira HTTP, etc.

3. **Spec `scanning` enrichie** par un Requirement « SSH Banner and Host-Key Probe » qui formalise le contrat (champs renvoyés, contraintes : pas d'auth, jamais d'AXFR/IXFR équivalent — pas de `ssh-userauth` invoqué).

4. **Variables d'environnement** : `RECONAUT_SSH_PROBE_TIMEOUT` (secondes, défaut 5) — alignée sur le motif `RECONAUT_DNS_TIMEOUT`.

## Contraintes

- **Aucune authentification SSH n'est tentée**. Pas de password, pas de clé, pas de keyboard-interactive, pas de GSSAPI. Le sondeur capture uniquement le banner et la host-key, puis se déconnecte.
- **Lecture banner en mode best-effort** : si le serveur ne renvoie pas la ligne SSH-2.0-… dans le timeout, `Outcome=not_ssh` (port ouvert mais protocole inconnu).
- **Timeout strict** par sonde (5 s par défaut). Une cible lente ne bloque pas le binaire.
- **Hostkey SHA-256 = `sha256:<base64>`** alignée sur le format affiché par OpenSSH (`ssh-keygen -lf` produit ce format). Permet la comparaison directe avec ce que voit l'opérateur dans son `~/.ssh/known_hosts`.
- **Pas de tentative de version downgrade**. Le client annonce SSH-2.0 ; les serveurs SSH-1.x reçoivent `not_ssh`.
- **Pas d'écriture de fichier ou d'effet de bord** : la sonde est en lecture pure.
- **Scope-driven** : la cible passée à `Probe` est supposée être déjà validée par `Reconaut::ScanEnqueuer` côté Rails (qui rejette hors scope avant enqueue). Le sondeur ne re-vérifie pas — c'est le pacte établi par le model mono-user.
- **Dépendance** : `golang.org/x/crypto/ssh` (BSD-3, compatible AGPL). Déjà dans `go.sum` transitivement (via miekg/dns).

## Non-objectifs (hors scope de ce change)

- **Sondeurs HTTP/RDP/MQTT/CoAP/Modbus** — chacun fera l'objet d'un change dédié (`add-http-probe`, `add-rdp-probe`, etc.).
- **Détection de version OpenSSH vulnérable** ni mapping CVE — relève d'`ai-optimization` / d'un futur `add-vulnerability-mapping`.
- **Bruteforce ou tentative d'authentification** — exclu définitivement par le projet (cf. *Pas de scan offensif* dans `project.md`).
- **Capture de l'algorithme de KEX choisi, des HostKeyAlgorithms supportés, des MACs** — délibérément différé pour garder ce change focalisé. Un futur `add-ssh-fingerprint-extended` ajoutera ces champs.
- **Multi-hôte parallèle** dans le sondeur — la parallélisation vit dans `goodjob.Loop` (un binaire = N goroutines via la file). Le sondeur lui-même reste mono-cible.
- **TLS au-dessus de SSH (par ex. `https://...:22`)** : le sondeur tente SSH directement sur TCP, pas d'enveloppe TLS.

## Décisions prises

1. **Pas de scan_kind dédié `ssh_probe`**. Le sondeur SSH est invoqué par `scanner-service_fingerprint` quand le port 22 est ciblé. Cohérent avec la spec `scanning` qui parle de « fingerprinting de ports/services » comme une capacité unifiée. Ajouter un 7e binaire pour SSH seul serait du sur-engineering.
2. **`golang.org/x/crypto/ssh` plutôt qu'une implémentation maison du KEX**. La lib est BSD-3, maintenue par l'équipe Go, déjà testée contre des milliers de serveurs SSH en production. Réimplémenter le KEX serait à la fois risqué et inutile.
3. **HostKeyCallback qui rejette** : on récupère la clé puis on retourne une erreur ("captured") qui annule la suite du handshake. Pas de session SSH ouverte, pas de risque d'auth tenté. Cohérent avec le scénario v1 « jamais d'authentification ».
4. **Format hostkey_sha256 = `sha256:<base64-no-padding>`** (style OpenSSH) plutôt que hex. Permet à l'opérateur de comparer directement avec sa sortie `ssh-keygen -lf` ou `ssh -o VisualHostKey=yes`.
5. **Banner brut conservé tel quel** (sans parsing version/software). Le parsing sémantique (`OpenSSH_8.9p1` → `software=OpenSSH version=8.9p1`) sera fait par la couche d'analyse côté Rails — le sondeur reste une couche transport.

## Différé (non bloquant, parqué pour plus tard)

- **Sondeur HTTP banner** — change `add-http-probe`.
- **Mapping CVE OpenSSH** — change `add-vulnerability-mapping`.
- **Capture des algorithmes KEX/HostKey/MAC** — change `add-ssh-fingerprint-extended`.
- **Détection de hostkey rotation** : alerte quand la SHA-256 change entre deux scans du même host — relève de la couche d'analyse anomalie (`ai-optimization` §3.3), pas du sondeur.
- **Configuration de port non-standard** (`Port=2222` etc.) : le sondeur l'accepte déjà via `Config.Port`, mais l'orchestration (quand l'invoquer ? qui le décide ?) sera pilotée par `scanner-service_fingerprint` à mesure que les sondeurs s'ajoutent.
