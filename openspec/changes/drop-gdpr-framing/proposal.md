# Change : drop-gdpr-framing

## Pourquoi

Le `init-reconaut-platform` introduisait une capacité `gdpr-compliance` complète : opérateur-as-controller, journal d'audit RGPD, effacement par sujet, résidence des données, registre des traitements documentaire, etc. Cette posture défensive a été cohérente tant qu'on imaginait que Reconaut puisse héberger ou approcher des **données à caractère personnel** au sens du RGPD.

À l'usage, cette hypothèse ne tient pas. Reconaut **stocke** :

- des entrées de scope (CIDR, domaines, FQDN — qui sont des actifs internet de l'opérateur, pas des personnes) ;
- des hôtes (IP, FQDN — propriété de l'opérateur ou ciblés avec son intérêt légitime) ;
- des services (port, protocole, bannière, fingerprint TLS — métadonnées techniques) ;
- des certificats TLS (CN/SAN, hash, dates — publics par construction) ;
- des résultats de scan (timestamps, codes de retour, durées, octets reçus — métadonnées).

**Aucune** de ces lignes ne contient de PII au sens RGPD. Les bannières/fingerprints peuvent **occasionnellement** révéler un nom dans une signature de service (`Server: Apache/2.4.x (Bob's blog)`) mais c'est à la marge et l'opérateur est seul juge de ce qu'il fait des données qu'il collecte. Le projet ne traite pas un sujet de données identifiable au sens du RGPD.

Conclusion : maintenir un **framework RGPD dédié** est :

1. **Inutile** au regard du périmètre réel des données.
2. **Trompeur** — il signale que Reconaut serait conçu pour traiter du PII, ce qui n'est pas le cas et n'est pas l'objectif.
3. **Coûteux** — chaque feature (audit append-only avec checksums, tombstone hashée, propagation cross-région, registre des traitements, etc.) est un travail d'ingénierie et de doc qui ne sert pas le cas d'usage réel.

Ce change retire la **capacité `gdpr-compliance`** et le **framing RGPD** de tous les artefacts. Les **infrastructures réellement utiles** (journal d'audit, effacement par cible, résidence des données configurable, rétention 90 j) restent — mais cadrées comme **outils opérationnels** (forensique, hygiène de la base de connaissance, sovrainté), pas comme conformité RGPD.

## Ce qui change

1. **`openspec/project.md`** :
   - Retire la bullet *Boundary RGPD claire*.
   - Retire la phrase « L'opérateur est le controller RGPD » de la section *Modèle de menace*.
   - Retire `gdpr-compliance` de la liste des capacités scindées.
   - Ajoute en *Non-objectifs* : « Pas de cadre RGPD applicatif. Reconaut stocke des actifs internet (IP, domaines, services, certificats) — pas de PII. Si l'opérateur ingère involontairement des données personnelles via des bannières ou findings, c'est à lui d'évaluer la conformité de sa propre pratique ; le projet ne fournit pas de framework dédié. »

2. **`openspec/changes/init-reconaut-platform/proposal.md`** : retire les références à `gdpr-compliance`, `controller`, etc.

3. **Capacité `gdpr-compliance` retirée**. Le spec delta marque la capacité **REMOVED**. À l'archivage de `init-reconaut-platform`, la capacité ne figurera pas dans `openspec/specs/`.

4. **Spec `scanning`** (de init-reconaut-platform) : la section *Retention* est reformulée en **gestion opérationnelle de la durée de vie des données** — l'opérateur choisit une fenêtre chaude par préférence opérationnelle (volume DB, granularité d'analyse), pas par contrainte RGPD.

5. **Spec `platform`** : retire la phrase « operator-as-controller » des scénarios. Garde l'auth locale + clés API scopées (déjà couverts par `single-user-only`).

6. **Tasks d'`init-reconaut-platform`** :
   - §6.1 *Configuration de résidence par l'opérateur* → reformulée en **`data_residency.allowed_regions`** comme **étiquette documentaire** pour la souveraineté (pas un mécanisme RGPD).
   - §6.2 *Workflow d'effacement par sujet* → reformulée en **`Reconaut::EraseTarget`** (effacement par identifiant pour l'**hygiène opérationnelle** : retirer un hôte qui n'est plus scopé, purger un certificat révoqué, etc.). Pas de tombstone hashée, juste une ligne d'audit normale.
   - §6.3 *Journal d'audit append-only* → conservé tel quel (utile en opérationnel, indépendamment de RGPD). La doc `docs/operating/audit.md` ne mentionne plus RGPD.

7. **Doctor `Reconaut::Doctor`** : conserve le check `region` mais sans la framer comme « EU residency ». L'opérateur déclare son ancrage géographique en texte libre.

## Contraintes

- **Pas de réintroduction de RGPD plus tard sans change explicite**. Si un cas d'usage légitime émerge (par ex. une instance dédiée à la sécurité d'une équipe avec utilisateurs identifiés), un futur change `add-pii-handling` re-cadrera proprement.
- **L'audit log et l'erase-by-target restent**. Ils servent l'opérationnel, pas la conformité.
- **Aucun message produit ne doit suggérer que Reconaut traite du PII**. README, project.md, docs : tout doit être cohérent avec le retrait.
- **Linter narratif** : `scripts/check_stack.sh` rejette toute mention de `RGPD` / `GDPR` / `controller` dans le repo (avec une allowlist : ce change lui-même peut les mentionner pour justifier le retrait, et un éventuel ADR).

## Non-objectifs (hors scope de ce change)

- **Modifier le code Rails** existant qui ne fait référence à RGPD que dans des commentaires : on retire les commentaires qui réfèrent à la conformité, mais on ne refactore pas la logique (audit, erase, residence) — elle reste, sous un cadrage opérationnel.
- **Supprimer l'audit log** ou l'erase-by-target. Au contraire — ils restent, juste re-framés.
- **Toucher aux contrats MCP** : pas de tool RGPD à retirer car aucun n'a été livré.
- **Ajouter un disclaimer légal**. Le README dira simplement « Reconaut stocke des actifs internet, pas du PII » — c'est tout.

## Décisions prises

1. **Drop complet du framing RGPD du projet.** Justifié par le périmètre réel des données stockées (actifs internet, métadonnées techniques) qui ne contient pas de PII au sens RGPD. Le coût ingénierie/doc d'un framework dédié n'est pas justifié.
2. **Capacité `gdpr-compliance` REMOVED**. La capacité disparaît du dictionnaire de capacités du projet. Toute future feature de gestion de données personnelles (très improbable) exigera un nouveau change qui crée une nouvelle capacité dédiée.
3. **Audit + erase + residence conservés sous framing opérationnel**. Ce sont des features utiles sans lien intrinsèque avec RGPD : forensique, hygiène, sovrainté.
4. **Linter narratif anti-RGPD**. Empêche la résurgence non intentionnelle d'un cadre qu'on vient de retirer.

## Différé (non bloquant, parqué pour plus tard)

- **Réintroduction d'un mode PII-aware** si un cas d'usage légitime émerge — change explicite avec justification chiffrée (combien de PII attendu, lesquelles, etc.).
- **Documentation `docs/data-stored.md`** qui détaille exhaustivement ce que Reconaut stocke. Utile pour l'opérateur qui veut faire son propre audit. Différé — pas critique pour ce change.
