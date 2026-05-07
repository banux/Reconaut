# ADR 0001 : Licence AGPL-3.0-only

Date : 2026-05-07
Statut : Accepte
Auteurs : Bastien Quelen

## Contexte

Reconaut est un outil open source d'Attack Surface Management auto-
hebergeable. Le projet n'a pas de vocation commerciale ; le code est
distribue gratuitement, l'operateur l'auto-heberge sur son
infrastructure et reste seul responsable des donnees scannees.

La licence du projet doit (a) garantir que le code reste librement
auditable et modifiable par tout operateur, (b) empecher qu'un
hyperscaler ou un editeur de SaaS reprenne le code pour le revendre
en service ferme sans rendre ses modifications a la communaute, (c)
rester compatible avec les principes OSI / FSF / Debian Free Software
Guidelines pour ne pas s'isoler de l'ecosysteme.

## Options envisagees

### Apache-2.0
- **Pour** : licence permissive standard, large adoption, pas de
  contrainte de reciprocite, accepte par tous les ecosystemes
  (Apache Foundation, CNCF, etc.).
- **Contre** : un editeur peut reprendre Reconaut, l'integrer dans
  un service SaaS proprietaire, et ne JAMAIS contribuer en retour.
  Pour un outil de securite ou la confiance dans la chaine
  d'integrite est critique, ce manque de reciprocite va a l'encontre
  de la mission.

### BUSL-1.1 (Business Source License)
- **Pour** : empeche la concurrence SaaS pendant 4 ans, conversion
  vers une licence open source apres ce delai.
- **Contre** : non OSI-approved, considere comme "source-available"
  plutot que reellement open source. Incompatible avec l'ecosystem
  Debian / Fedora et avec une partie de l'audit communautaire qui
  exige une vraie licence libre.

### MIT
- **Pour** : encore plus simple qu'Apache-2.0.
- **Contre** : meme inconvenient qu'Apache-2.0 cote reciprocite, et
  pas de clause de brevet explicite.

### AGPL-3.0-only (retenue)
- **Pour** : OSI-approved, FSF-approved, force tout fournisseur d'un
  service hebergeant Reconaut a publier ses modifications sous la
  meme licence (clause "use over a network"). Compatible Debian /
  Fedora. Maintient l'esprit "service public outillage" du projet.
- **Contre** : certaines entreprises ont des politiques internes qui
  interdisent l'AGPL ; on accepte ce trade-off.

### AGPL-3.0-or-later
- **Contre** : laisse le destinataire choisir une version future de
  l'AGPL non encore publiee. Difficile a auditer. On prefere
  l'engagement explicite sur la 3.0 et un eventuel switch via un
  nouveau ADR si une 4.0 sortait.

## Decision

Reconaut est distribue sous **AGPL-3.0-only**.

- Le texte integral d'AGPL-3.0 est dans `LICENSE` a la racine.
- Identifiant SPDX canonique : `AGPL-3.0-only`.
- L'audit de licence des dependances (`license_finder` cote Rails,
  equivalent cote Go a venir) refuse toute dependance dont la licence
  n'est pas compatible AGPL en sortie : pas de BSL, pas de SSPL, pas
  d'Elastic License v2, pas de Commons Clause, pas de proprietaire.
  Voir `apps/api/doc/dependency_decisions.yml` pour l'allowlist
  effective.

## Consequences

- **Pour les operateurs** : Reconaut est utilisable librement dans
  une organisation interne (auto-hebergement). L'AGPL ne s'applique
  qu'au moment ou l'instance est mise a disposition d'utilisateurs
  externes.
- **Pour les fournisseurs SaaS** : ils peuvent operer Reconaut comme
  service mais doivent publier toute modification sous AGPL-3.0. En
  pratique, cela bloque la reprise commerciale silencieuse.
- **Pour les contributeurs** : DCO sign-off (cf. ADR 0002 a venir),
  pas de CLA de cession de droits.
- **Pour le marquage des fichiers** : l'header SPDX
  `# SPDX-License-Identifier: AGPL-3.0-only` est ajoute aux fichiers
  source applicatifs (Ruby, Go, JavaScript, Vue). Verifie en CI.

## References

- Texte AGPL-3.0 : `LICENSE` (racine)
- Discussion FSF "use over a network" :
  https://www.gnu.org/licenses/why-affero-gpl.html
- Debian Free Software Guidelines :
  https://www.debian.org/social_contract#guidelines
