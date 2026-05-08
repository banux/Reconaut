# Change : replace-web-with-tui

## Pourquoi
La stack initiale figée par `add-tech-stack` prévoit un frontend Vue 3 + Vite. À l'usage, ce choix est en tension avec deux invariants déjà actés :

1. **Auto-hébergement sans condition** (cf. `project.md`). Une SPA Vue impose une chaîne de build Node (Vite, npm/pnpm, plugins), un serveur statique distinct (ou un asset pipeline Rails) et une posture CORS / CSP à durcir. Trois sources de complexité opérationnelle pour un opérateur SOC qui veut juste lancer Reconaut dans son réseau.
2. **Public cible = équipe sécurité** (analystes, SOC, ingénieurs). C'est un public qui vit déjà dans le terminal (tmux, ssh, vim, k9s, lazygit, lazydocker) et pour qui une TUI bien conçue est plus rapide qu'une SPA — moins de chargement, scriptable, fonctionne en SSH sur des bastions sans X.

Ce change retire la SPA Vue 3 + Vite et la remplace par un binaire Go fournissant une **TUI** (Terminal User Interface) + sous-commandes one-shot. Le binaire consomme la même API HTTP+SSE Rails que les agents MCP — c'est le périmètre IPC qui est mutualisé, pas l'UI elle-même.

Le message « workers séparés et spécialisés » de l'utilisateur est par ailleurs explicité dans la spec : un binaire Go par `scan_kind` (TCP probe, TLS capture, HTTP banner, subdomain enum, service fingerprint), chacun consommant sa propre queue GoodJob et compilé avec uniquement les sondeurs qui lui sont nécessaires.

## Ce qui change

1. **Retrait du frontend web Vue 3 + Vite**. Suppression de l'app `apps/web/`, des jobs CI `web-eslint` / `web-vitest`, des règles de stack-linter relatives à React/Angular/Svelte/Nuxt (devenues sans objet), de tout chemin d'asset pipeline statique côté Rails servant un bundle SPA, des scénarios de spec « Bundle de production servi aux utilisateurs ».
2. **Ajout d'un binaire Go `reconautctl`** sous `apps/tui/` : TUI bubbletea (Charm) + sous-commandes one-shot. Le binaire parle au backend Rails via HTTPS+SSE (clé API personnelle stockée localement après login interactif).
3. **Spécialisation explicite des workers de scan** : un binaire Go par `scan_kind`, sous `apps/scanner-<kind>/`. Chaque worker s'abonne à sa propre queue GoodJob nommée `scan:<kind>`. Rails enqueue avec le `queue_name` correspondant au `scan_kind` du payload. Cette séparation réduit la surface d'attaque par binaire (chaque scanner ne contient que les parsers de son protocole) et permet à l'opérateur de scaler chaque type indépendamment.
4. **Mise à jour des changes dépendants** : `add-tech-stack` (Frontend Framework requirement modifié), `init-reconaut-platform` / `platform` (auth scenarios reformulés sans hypothèse de browser), `open-source-governance` (Reproducible Container Distribution : le périmètre de release passe de `api/web/scanner` à `api/tui/scanner-<kind>`).

## Contraintes

- **Pas de framework web livré** dans le cœur en v1. Pas de SPA, pas de SSR, pas de WebView embarquée. Si un opérateur veut bricoler une UI web par-dessus l'API Rails, c'est son problème, pas celui du projet.
- **Le binaire `reconautctl` est un client de l'API**. Il ne contient aucune logique métier (validation de scope, vérification de scan, RBAC, audit) qui ne soit pas dupliquée côté Rails. Une compromission du binaire opérateur ne bypasse pas les invariants du serveur.
- **Bibliothèque TUI = bubbletea / lipgloss / bubbles** (Charm) sous licence MIT, compatible AGPL-3.0-only.
- **Auth local-first préservée** : `reconautctl login` invite à entrer email + mot de passe locaux, échange ces credentials contre une clé API personnelle hashée côté Rails, stocke le clear-text de la clé sous `$XDG_CONFIG_HOME/reconaut/credentials` (mode `0600`). Aucune dépendance OIDC pour utiliser le binaire en local.
- **Workers spécialisés** : chaque scanner DOIT être un binaire séparé qui n'importe que les packages Go nécessaires à son `scan_kind`. Pas de scanner « universel » qui dispatch sur tous les types.
- **Tout ce qui passait par la SPA passe maintenant par le binaire ou par MCP**. Pas de feature qui aurait été « visible UI uniquement ».

## Non-objectifs (hors scope de ce change)

- **Réintroduction d'une UI web** ultérieure — rien n'empêche un futur change `add-web-dashboard` si la demande émerge, mais ce change le ferme volontairement pour la v1.
- **Distribution d'un installer (Homebrew, apt, etc.)** — la release publie des binaires statiques OCI + tar.gz signés ; l'empaquetage distro est externe.
- **Sondeurs de protocole concrets** (HTTP/SSH/TLS/RDP/MQTT/CoAP/Modbus) — ils sont implémentés dans les changes ultérieurs `scan-engine-<protocol>`. Ce change pose seulement le squelette d'un binaire par `scan_kind`.
- **Mode batch / non-interactif avancé** (jobs scriptés, formats de sortie alternatifs au-delà de JSON / table) — peut faire l'objet d'un change ultérieur.
- **Internationalisation de la TUI** — anglais en v1, traductions à l'usage.

## Décisions prises

1. **TUI plutôt que SPA web.** Justifié par (a) la cohérence avec l'auto-hébergement (pas de chaîne de build Node ni de serveur statique à déployer), (b) le profil de l'utilisateur cible (SOC/analyste qui vit en terminal), (c) la simplicité (un seul binaire statique multi-arch).
2. **Bubbletea (Charm) plutôt qu'autre framework TUI** (tcell, gocui, termui, tview…). Justifié par la maturité de l'écosystème Charm (lipgloss pour le styling, bubbles pour les composants, glamour pour le rendu markdown), la licence MIT compatible AGPL, et le pattern Elm-like (Init/Update/View) qui rend le code testable.
3. **Workers spécialisés par `scan_kind`.** Justifié par la sécurité (surface d'attaque réduite par binaire), la compilation (binaires plus petits), la scalabilité opérationnelle (chaque type scale indépendamment), et la séparation des dépendances (un parser Modbus n'est pas chargé dans le scanner HTTP).
4. **Une seule queue GoodJob par `scan_kind`** (`scan:tcp_probe`, `scan:tls_capture`, etc.) plutôt qu'une queue `scan` partagée avec dispatch interne. Permet à GoodJob de pousser le routage côté SQL (les workers ne lisent que leur queue) et d'observer la profondeur par type dans le dashboard GoodJob.
5. **Pas de composant web réintroduit subrepticement** — le `bin/doctor` reste une rake task Rails ou un sous-commande TUI ; il n'expose pas une page web `/doctor.html` qui ressusciterait la SPA.

## Différé (non bloquant, parqué pour plus tard)

- **Choix précis du modèle de stockage des credentials TUI** : fichier plat protégé (`0600`) vs intégration keyring OS (libsecret, macOS Keychain, etc.). Fichier plat en v1, keyring possible plus tard.
- **Mode « lecture seule » du binaire** pour un opérateur sans rôle `analyst+` (juste `viewer`) — la TUI doit gracieusement masquer les actions interdites, à formaliser à l'implémentation.
- **Tests interactifs de la TUI** : `vhs` (Charm) pour produire des GIFs reproductibles vs tests d'intégration purs. À acter à l'implémentation.
- **Docker-compose updaté** : retirer le service `web` s'il existe, ne pas embarquer la TUI dans une image (le binaire se distribue séparément).
