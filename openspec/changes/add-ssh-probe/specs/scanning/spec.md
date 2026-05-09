# Spec delta : scanning

## ADDED Requirements

### Requirement: SSH Banner and Host-Key Probe
La plateforme DOIT exposer un sondeur SSH qui, pour un hôte ou une IP **dans le scope déclaré**, ouvre une connexion TCP sur un port configurable (défaut 22), lit la **bannière SSH** envoyée par le serveur (première ligne du flux, format `SSH-{version}-{software comment?}`), et capture le **fingerprint SHA-256 de la host-key** présentée pendant le KEX, **sans jamais tenter d'authentification**.

Le sondeur DOIT respecter ces contraintes :

- **Aucune authentification** n'est tentée (pas de password, pas de clé, pas de keyboard-interactive, pas de GSSAPI). Une fois la host-key capturée pendant le KEX, la connexion DOIT être fermée immédiatement.
- **Format hostkey** : `sha256:<base64-sans-padding>`, identique au format affiché par OpenSSH (`ssh-keygen -lf`).
- **Timeout** par sonde configurable via `RECONAUT_SSH_PROBE_TIMEOUT` (secondes, défaut 5). Une cible lente ne bloque pas le binaire.
- **`outcome`** parmi `success` | `timeout` | `reset` | `not_ssh` | `dial_error`. `not_ssh` quand le port s'ouvre mais le serveur ne renvoie pas une bannière `SSH-` reconnaissable dans le timeout.
- **Banner brut** : conservé tel quel (chaîne entre `SSH-` et le premier `\r\n` ou `\n`). Pas de parsing version/software côté sondeur.
- **Aucun effet de bord** : la sonde est en lecture pure ; pas d'écriture de fichier, pas de modification du système.

#### Scenario: Bannière SSH + host-key capturées sur TCP/22
- **GIVEN** un hôte `h.example.fr` couvert par le scope avec un OpenSSH qui répond sur TCP/22
- **WHEN** le sondeur est invoqué via `scanner-service_fingerprint` pour cette cible
- **THEN** le résultat persisté contient `banner` (par ex. `SSH-2.0-OpenSSH_8.9p1 Debian-2`) et `hostkey_sha256` au format `sha256:<base64>`
- **AND** un test contre un faux serveur SSH local confirme que **aucun message `SSH_MSG_USERAUTH_REQUEST`** n'est envoyé par le sondeur (le serveur de test inspecte les paquets reçus)
- **AND** le finding final est `outcome=success`

#### Scenario: Port 22 ouvert mais protocole non-SSH
- **GIVEN** un hôte qui répond sur TCP/22 avec un autre protocole (HTTP, raw bytes, silence)
- **WHEN** le sondeur tente la sonde
- **THEN** après le timeout configuré (5 s par défaut), le résultat est `outcome=not_ssh` avec `banner=""` et `hostkey_sha256=""`
- **AND** aucun crash, le binaire reste prêt à traiter le job suivant

#### Scenario: Hôte injoignable (TCP refused / host unreachable)
- **GIVEN** une cible hors d'usage
- **WHEN** la connexion TCP échoue
- **THEN** le sondeur retourne `outcome=dial_error` avec un détail textuel court (`connection refused`, `no route to host`, etc.)
- **AND** un test contre un port fermé local (par ex. 127.0.0.1:65535) confirme le comportement

#### Scenario: Aucune authentification jamais tentée
- **GIVEN** un faux serveur SSH local qui hooke `ServerConfig.PasswordCallback` et `PublicKeyCallback`
- **WHEN** le sondeur exécute sa sonde
- **THEN** **aucun de ces callbacks n'est invoqué** (le client se déconnecte après le KEX, jamais d'auth)
- **AND** un test grep sur `apps/scanner/internal/sshprobe/` confirme l'absence de toute construction `ssh.Password(...)`, `ssh.PublicKeys(...)`, `ssh.KeyboardInteractive(...)` (allowlist : aucune méthode d'auth dans le code).

#### Scenario: Hostkey SHA-256 alignée sur OpenSSH `ssh-keygen -lf`
- **GIVEN** un faux serveur SSH avec une clé hôte connue
- **WHEN** le sondeur capture la host-key
- **THEN** la valeur `hostkey_sha256` retournée est égale au résultat de `ssh-keygen -lf <pubkey>` qui produit `sha256:<base64>` standard OpenSSH
- **AND** un test compare octet-pour-octet la sortie du sondeur à la valeur calculée par la lib `golang.org/x/crypto/ssh.FingerprintSHA256(key)`
