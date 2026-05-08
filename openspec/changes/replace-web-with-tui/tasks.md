# Tâches : replace-web-with-tui

Checklist de la bascule SPA Vue → TUI Go + spécialisation des workers de scan. Chaque tâche inclut des notes d'implémentation et un test plan qui DOIT passer avant de cocher la case.

---

## 1. Retrait du frontend Vue 3 + Vite

- [ ] **1.1 Supprimer `apps/web/`**
  - **Notes** : Retirer le répertoire entier (`apps/web/src/`, `apps/web/package.json`, `apps/web/package-lock.json`, `apps/web/vite.config.js`, `apps/web/index.html`, `apps/web/README.md`). Mettre à jour `bin/test` et `bin/setup` pour ne plus référencer `apps/web/`. Mettre à jour `.github/workflows/ci.yml` pour retirer les jobs `web-vitest` (et tout `pnpm install`/`pnpm test`).
  - **Test plan** : `find apps/ -name "*.vue" -o -name "*.jsx" -o -name "*.tsx"` ne renvoie aucun fichier. `bin/test` ne déclenche plus de tentative pnpm/vitest. La CI passe sans le job `web-vitest`.

- [ ] **1.2 Retirer les règles de stack-linter relatives au web**
  - **Notes** : Dans `scripts/check_stack.sh`, les règles « rejette tout fichier `.jsx`/`.tsx` ou import `react`/`@angular`/`svelte` dans `apps/web/` » deviennent obsolètes. Les remplacer par une règle plus large : « rejette toute introduction d'un répertoire `apps/web/` ou de tout fichier `.vue`/`.jsx`/`.tsx`/`.svelte` dans le repo », pour empêcher la résurgence d'une SPA.
  - **Test plan** : `scripts/check_stack.sh` passe sur HEAD (apps/web/ supprimé). Test : créer un fichier `apps/web/Bad.vue` → exit ≠ 0 avec message `frontend-stack-violation`. Idem pour un `.svelte` ailleurs dans le repo.

- [ ] **1.3 Confirmer l'absence d'asset pipeline web côté Rails**
  - **Notes** : Vérifier qu'`apps/api/Gemfile` ne contient pas `propshaft`, `importmap-rails`, `sprockets-rails`, `webpacker`, `jsbundling-rails`, `cssbundling-rails`. Vérifier que `apps/api/app/javascript/` n'existe pas. Vérifier qu'aucune route Rails ne renvoie de HTML SPA.
  - **Test plan** : Ajouter le pattern à `scripts/check_stack.sh` pour rejeter ces gems / chemins. Test : ajouter `gem "propshaft"` au Gemfile → linter échoue.

---

## 2. Squelette du binaire `reconautctl`

- [ ] **2.1 Layout `apps/tui/` avec bubbletea**
  - **Notes** : Nouveau module Go `apps/tui/` (chemin `github.com/banux/Reconaut/apps/tui`) avec :
    - `cmd/reconautctl/main.go` : entrypoint, parsing des sous-commandes (cobra ou stdlib `flag` + dispatch maison).
    - `internal/tui/` : modèles bubbletea pour les vues interactives (`agent`, `hosts`, `scope`).
    - `internal/api/` : client HTTP+SSE typé contre l'API Rails (réutilise les schémas de `packages/job-schema/` quand pertinent).
    - `internal/auth/` : stockage de la clé API (`$XDG_CONFIG_HOME/reconaut/credentials`, mode `0600`).
  - **Test plan** : `cd apps/tui && go test ./...` exécute un smoke test trivial qui passe. `go build ./cmd/reconautctl` produit un binaire exécutable. `reconautctl --version` imprime une version + exit 0.

- [ ] **2.2 Sous-commande `reconautctl login`**
  - **Notes** : Prompt interactif pour email + mot de passe (lipgloss + bubbles/textinput). Appel `POST /auth/sessions` (ou endpoint équivalent existant côté Rails) puis génération d'une clé API personnelle via `POST /auth/api_keys`. Stockage de la clé sous `$XDG_CONFIG_HOME/reconaut/credentials` (créer le répertoire avec `0700` et le fichier avec `0600`). Le mot de passe N'EST PAS persisté.
  - **Test plan** : Test e2e avec un Rails mock : `reconautctl login` reçoit email/password en mode batch (drapeau `--email`/`--password` pour les tests, refusé en mode interactif standard), assure (a) la requête API est envoyée avec les bons headers, (b) la clé API renvoyée est stockée, (c) le fichier credentials a `0600`, (d) le mot de passe n'apparaît dans aucun fichier disque ou variable d'env exportée.

- [ ] **2.3 Sous-commandes `reconautctl scope list|add|revoke`**
  - **Notes** : Wrappers HTTP autour de `GET /scopes`, `POST /scopes`, `DELETE /scopes/{id}`. La sortie par défaut est une table (lipgloss/table). Drapeau `--json` pour la sortie machine. Les actions destructrices (`revoke`) demandent confirmation `[y/N]` sauf si `--yes` est passé.
  - **Test plan** : Test fixture-driven avec un serveur HTTP de test : (a) `scope list` rend le tableau attendu, (b) `scope add` envoie le body attendu et imprime le résultat, (c) `scope revoke <id>` sans `--yes` lit stdin et abandonne sur input vide, (d) `scope revoke <id> --yes` envoie `DELETE` directement.

- [ ] **2.4 Sous-commande `reconautctl scan request|status|list`**
  - **Notes** : Mappe sur `POST /scans`, `GET /scans/{id}`, `GET /scans`. La validation du scope reste côté Rails ; le binaire affiche les erreurs `out-of-scope` telles qu'elles arrivent du serveur sans logique locale.
  - **Test plan** : Test e2e contre un Rails mock qui renvoie `out-of-scope` ; assure que la TUI affiche l'erreur sans tenter de retry ni de bypass. Test additionnel : audit du code Go cherche un fichier `scope_validator.go` dans `apps/tui/` → doit être absent.

- [ ] **2.5 Sous-commande TUI `reconautctl agent`**
  - **Notes** : Vue bubbletea avec champ de saisie en bas + zone de réponse streaming en haut. Connexion SSE à `POST /agent/chat` (la connexion HTTP utilise le header `Accept: text/event-stream`). Chaque message arrive en chunks ; le rendu utilise glamour pour formater le markdown. Citations `(host_id, scanned_at)` rendues en bas de chaque réponse.
  - **Test plan** : Test e2e avec un mock SSE : envoyer une requête, recevoir 5 chunks, assurer que le rendu cumulatif égale la concaténation des chunks. Test additionnel : déconnexion serveur en cours de stream → la TUI affiche un message d'erreur et reste utilisable.

- [ ] **2.6 Sous-commande `reconautctl doctor`**
  - **Notes** : Appel `GET /admin/doctor` (ou équivalent à exposer côté Rails) qui renvoie le rapport JSON de `Reconaut::Doctor`. Le binaire formate la sortie en table colorée (vert pour `:ok`, rouge pour `:fail`, jaune pour `:unknown`/`:info`).
  - **Test plan** : Test e2e avec un mock qui renvoie un rapport contenant tous les statuts ; vérifier que la sortie inclut chaque check avec la bonne couleur de status.

---

## 3. Spécialisation des workers de scan

- [ ] **3.1 Refactor `apps/scanner/` en `apps/scanner-<kind>/`**
  - **Notes** : Pour chaque `scan_kind` listé dans `ScanJobV1` (`tcp_probe`, `tls_capture`, `http_banner`, `subdomain_enum`, `service_fingerprint`), créer `apps/scanner-<kind>/cmd/scanner-<kind>/main.go`. Chaque main importe `internal/goodjob` + `internal/jobschema` + uniquement les sondeurs de son protocole. Le `queue_name` consommé est `scan:<kind>` (constante par binaire).
  - **Test plan** : `find apps/ -name "main.go" -path "*scanner*"` renvoie au moins 5 fichiers, un par `scan_kind`. Pour chaque binaire, `go list -deps ./...` confirme qu'il n'importe pas les packages des autres protocoles (par ex. `scanner-tcp` n'importe pas `crypto/tls`, `scanner-dns` n'importe pas `net/http`).

- [ ] **3.2 Rails enqueue avec `queue_name` dérivé de `scan_kind`**
  - **Notes** : Dans `apps/api/app/jobs/scan_job.rb`, dériver `queue_as` dynamiquement depuis le payload : `queue_as { "scan:#{arguments.first['scan_kind']}" }`. Mettre à jour les tests existants pour assurer que la queue est bien spécialisée.
  - **Test plan** : Test RSpec `expect { ScanJob.perform_later(payload) }.to have_enqueued_job(ScanJob).on_queue("scan:tcp_probe")` pour un payload TCP, et `"scan:tls_capture"` pour TLS, etc.

- [ ] **3.3 Linter qui vérifie la spécialisation des binaires**
  - **Notes** : Script CI `scripts/check_scanner_specialization.sh` qui pour chaque `apps/scanner-<kind>/` exécute `go list -deps` et confirme que les imports respectent une allowlist propre au protocole. Refus en cas d'import croisé.
  - **Test plan** : Le linter passe sur HEAD. Test : injecter `import "crypto/tls"` dans `scanner-tcp` → linter échoue avec message clair nommant l'import interdit.

- [ ] **3.4 Mise à jour de la spec `architecture` des binaires de release**
  - **Notes** : `.github/workflows/release.yml` produit une image OCI par binaire `scanner-<kind>` au lieu d'une image `scanner` unique. Cf. spec `open-source-governance` modifiée.
  - **Test plan** : Workflow CI sur tag `vX.Y.Z` produit ≥ 5 images `ghcr.io/<org>/reconaut-scanner-<kind>:vX.Y.Z` ; un job de smoke `docker pull` confirme leur présence.

---

## 4. Mise à jour de la documentation et des changes existants

- [ ] **4.1 Mettre à jour `openspec/project.md`**
  - **Notes** : Section *Stack* : remplacer la ligne « Frontend : Vue 3 + Vite » par « Frontend : binaire Go `reconautctl` (TUI bubbletea/Charm) ». Ajouter un point sur la spécialisation des workers (`scanner-<kind>` par scan_kind).
  - **Test plan** : `grep -niE "vue|vite|nuxt" openspec/project.md` ne renvoie plus aucune mention positive (les négations style « pas de Vue » sont OK). `grep -i "TUI" openspec/project.md` renvoie ≥ 1 match.

- [ ] **4.2 Mettre à jour `add-tech-stack` (Frontend Framework + Scan Workers Runtime)**
  - **Notes** : Le change `add-tech-stack` est ARCHIVÉ ou MODIFIÉ ? Approche : ce change `replace-web-with-tui` MODIFIE les exigences correspondantes dans le spec delta `architecture`. À l'archivage de `add-tech-stack`, les requirements actuels seront repris dans `openspec/specs/architecture/spec.md`, puis ce change appliquera les MODIFIED par-dessus.
  - **Test plan** : `openspec validate replace-web-with-tui` (ou outil équivalent) passe ; les MODIFIED Requirements sont déclarés.

- [ ] **4.3 Mettre à jour `init-reconaut-platform/specs/platform/spec.md`**
  - **Notes** : Les scénarios mentionnent l'UI sans préjuger du canal (web vs TUI). Pas de modif lourde nécessaire ; seulement reformuler les références implicites à un sélecteur d'UI pour préciser que c'est la TUI.
  - **Test plan** : `grep -i "ui" openspec/changes/init-reconaut-platform/specs/platform/spec.md` ne renvoie aucune mention de SPA / browser / web. Les scénarios restent valides pour un client TUI.

- [ ] **4.4 Mettre à jour `README.md` racine et `docker-compose.yml`**
  - **Notes** : README : section quickstart mentionne le binaire `reconautctl` à la place de l'URL `localhost:5173`. docker-compose.yml : retirer le service `web` s'il existe ; ne pas embarquer `reconautctl` dans la stack containerisée (le binaire se distribue séparément).
  - **Test plan** : `grep -iE "vite|localhost:5173|apps/web" README.md docker-compose.yml` ne renvoie aucune occurrence positive.

---

## 5. Acceptance pour le change dans son ensemble

- [ ] **5.1 Tests automatisés des nouveaux requirements**
  - Chaque MODIFIED Requirement (Frontend Interface, Scan Workers Runtime, Authentication and RBAC, Reproducible Container Distribution) ET chaque ADDED Requirement (TUI Operator Surface, Operator Binary Boundary) a au moins un test automatisé passant en CI.

- [ ] **5.2 Linter de stack mis à jour bloque la résurgence du web**
  - `scripts/check_stack.sh` rejette tout `.vue`/`.jsx`/`.tsx`/`.svelte` ainsi que toute gem d'asset pipeline web (`propshaft`, `importmap-rails`, `sprockets-rails`, `webpacker`, `jsbundling-rails`, `cssbundling-rails`).

- [ ] **5.3 Linter de spécialisation des workers actif en CI**
  - `scripts/check_scanner_specialization.sh` tourne sur chaque PR et bloque tout import croisé entre packages de protocole.

- [ ] **5.4 Le binaire `reconautctl` est utilisable en environnement minimal**
  - Test e2e : container `alpine` sans Ruby ni Node, on copie `reconautctl-linux-amd64` et on lance `reconautctl --version` → exit 0. `reconautctl login --email <e> --password <p> --server <url>` contre une instance Rails de test → la clé API est stockée en `0600`.

- [ ] **5.5 Aucun composant web ne ressuscite par mégarde**
  - Audit du dépôt : `find apps/ -name "*.vue" -o -name "*.jsx" -o -name "*.tsx"` ne renvoie rien. Aucune image `reconaut-web` n'est publiée par la CI. Aucune dépendance Node n'apparaît dans `apps/api/Gemfile.lock`.
