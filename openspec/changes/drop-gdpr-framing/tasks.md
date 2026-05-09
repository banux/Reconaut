# Tâches : drop-gdpr-framing

Checklist du retrait du cadre RGPD du projet, en conservant les infrastructures opérationnelles utiles (audit, erase, résidence). Chaque tâche inclut des notes d'implémentation et un test plan qui DOIT passer avant de cocher la case.

---

## 1. Repositionnement narratif

- [x] **1.1 Réécrire `openspec/project.md`**
  - **Notes** : Retirer la bullet *Boundary RGPD claire*. Retirer la phrase « L'opérateur est le controller RGPD » de la section *Modèle de menace*. Retirer `gdpr-compliance` de la liste des capacités scindées. Ajouter en *Non-objectifs* : « Pas de cadre RGPD applicatif. Reconaut stocke des actifs internet (IP, domaines, services, certificats) — pas de PII. »
  - **Test plan** : `grep -niE "RGPD|GDPR|controller|gdpr-compliance" openspec/project.md` ne renvoie aucune occurrence positive (les négations « pas de RGPD » sont OK et seront couvertes par l'allowlist du linter §4.1).

- [x] **1.2 Mettre à jour `init-reconaut-platform/proposal.md`**
  - **Notes** : Retirer la bullet *operator-as-controller RGPD*. Retirer la mention de la capacité `gdpr-compliance` parmi les ajouts du change. Mentionner explicitement dans les non-objectifs : « pas de cadre RGPD ».
  - **Test plan** : `grep -niE "RGPD|GDPR|controller" openspec/changes/init-reconaut-platform/proposal.md` ne renvoie plus d'occurrence positive.

- [x] **1.3 Mettre à jour `README.md`**
  - **Notes** : Toute mention RGPD / GDPR / "responsable de traitement" est retirée. Si une phrase introductive était positionnée comme "compliance-aware", la reformuler en "outil de scan auto-hébergeable, scope-driven".
  - **Test plan** : `grep -niE "RGPD|GDPR|controller|responsable.*traitement" README.md` ne renvoie rien.

---

## 2. Nettoyage des specs en aval

- [x] **2.1 Marquer la capacité `gdpr-compliance` REMOVED dans `init-reconaut-platform`**
  - **Notes** : Le spec delta de ce change (`drop-gdpr-framing/specs/gdpr-compliance/spec.md`) déclare REMOVED toutes les Requirements de la capacité. À l'archivage, la capacité ne figurera pas dans `openspec/specs/`. L'ancien dossier `init-reconaut-platform/specs/gdpr-compliance/` est conservé comme archive historique.
  - **Test plan** : la spec REMOVED est cohérente avec ce qui existait dans `init-reconaut-platform/specs/gdpr-compliance/spec.md`. Aucun autre change ne référence la capacité comme dépendance active.

- [x] **2.2 Reformuler `init-reconaut-platform/specs/scanning/spec.md` (rétention/erase)**
  - **Notes** : La section *Retention* qui parle de tier chaud/froid sous angle RGPD est reformulée en *Operational Data Lifecycle* (cf. spec delta de ce change). Le tier froid Postgres compressé reste possible, plus une exigence cœur. La tombstone hashée est retirée — l'audit normal suffit.
  - **Test plan** : grep `init-reconaut-platform/specs/scanning/spec.md` pour `RGPD|controller|tombstone hash` → aucune occurrence après mise à jour.

- [x] **2.3 Reformuler `init-reconaut-platform/specs/platform/spec.md` (audit + résidence)**
  - **Notes** : Les scénarios d'audit deviennent des scénarios d'audit opérationnel. Le check de résidence devient une étiquette de souveraineté libre. Pas de validation EU codée en dur.
  - **Test plan** : grep `init-reconaut-platform/specs/platform/spec.md` pour `RGPD|EU.{0,30}residency|operator-as-controller` → aucune occurrence active.

- [x] **2.4 Mettre à jour `init-reconaut-platform/tasks.md` §6.x**
  - **Notes** :
    - §6.1 *Configuration de résidence* → reformulée en `RECONAUT_DATA_RESIDENCY` chaîne libre, doctor info-level.
    - §6.2 *Workflow d'effacement* → reformulée en `Reconaut::EraseTarget` (hygiène opérationnelle), pas de tombstone hashée.
    - §6.3 *Audit append-only* → conservé tel quel mais le commentaire de doc retire la mention « RoPA RGPD ».
  - **Test plan** : `grep -i "RGPD\|controller" openspec/changes/init-reconaut-platform/tasks.md` ne renvoie plus rien.

---

## 3. Nettoyage du code applicatif

- [x] **3.1 Retirer les commentaires RGPD dans le code Rails**
  - **Notes** : `apps/api/app/lib/**/*.rb` et `apps/api/app/controllers/**/*.rb` : remplacer les commentaires qui réfèrent à RGPD/controller/tombstone par un cadrage opérationnel équivalent. Aucun changement de logique métier.
  - **Test plan** : `grep -RiE "RGPD|GDPR|controller.*RGPD" apps/api/app/` ne renvoie rien après nettoyage.

- [x] **3.2 Retirer les références RGPD dans les docs**
  - **Notes** : `docs/**/*.md` (architecture, positioning, integrations, adr) — mêmes règles. Si un doc parle de "données personnelles" alors qu'il décrit des bannières TLS, reformuler en "métadonnées techniques".
  - **Test plan** : `grep -RiE "RGPD|GDPR" docs/` ne renvoie rien (sauf l'éventuel ADR qui consigne la décision de drop, dans la zone d'allowlist).

- [x] **3.3 Doctor : retirer le check `region` EU-allowlist**
  - **Notes** : `apps/api/app/lib/reconaut/doctor.rb` — la constante `EU_REGION_ALLOWLIST` et le check `region` qui valide contre cette liste sont retirés. Un nouveau check `data_residency` info-level lit `RECONAUT_DATA_RESIDENCY` et expose la valeur sans validation.
  - **Test plan** : `spec/lib/reconaut/doctor_spec.rb` adapté : pas de fail sur `region not in EU`. Le check `data_residency` rapporte `:info` quand la variable est présente, `:unknown` sinon.

---

## 4. Linter narratif

- [x] **4.1 `scripts/check_stack.sh` rejette toute mention de RGPD/GDPR/controller**
  - **Notes** : Étendre le linter avec une règle : `grep -RiE "RGPD|GDPR" docs/ openspec/ README.md` doit renvoyer 0 ligne (hors allowlist : ce change `drop-gdpr-framing` lui-même + un éventuel ADR de décision).
  - **Test plan** : `bash scripts/check_stack.sh` passe sur HEAD après cleanup. Test : ajouter "RGPD" dans `README.md` → linter échoue. Test : ajouter "GDPR" dans `docs/architecture/foo.md` → linter échoue.

---

## 5. Acceptance pour le change dans son ensemble

- [x] **5.1 Aucun cadre RGPD résiduel**
  - `grep -RiE "RGPD|GDPR" --include='*.md' --include='*.rb' --include='*.go'` à la racine du repo renvoie uniquement des matches dans la zone d'allowlist (le change `drop-gdpr-framing/` lui-même).

- [x] **5.2 Audit log et erase-by-target restent fonctionnels**
  - Les specs existants qui exercent l'audit et l'erase passent toujours. Aucune régression sur `audit_recorder` ou les chemins MCP qui écrivent des lignes d'audit.

- [x] **5.3 Doctor reformulé**
  - Le rapport JSON imprimé par `bin/rails reconaut:doctor` ne contient plus la clé `region` framée comme RGPD ; il contient un check `data_residency` (info-level).

- [x] **5.4 Tests verts**
  - Toute la suite `apps/api && bundle exec rspec` reste verte après cleanup.
