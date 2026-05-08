# Change : add-dns-records-scanner

## Pourquoi

Reconaut est positionné comme **base de connaissance d'actifs internet pour agents IA** (cf. [`reposition-as-agent-knowledge-base`](../reposition-as-agent-knowledge-base/proposal.md)). Le périmètre de scan v1 ([`replace-web-with-tui`](../replace-web-with-tui/) + [`add-tech-stack`](../add-tech-stack/)) livre 5 binaires Go spécialisés : `tcp_probe`, `tls_capture`, `http_banner`, `subdomain_enum`, `service_fingerprint`.

Il manque une capacité **fondamentale** pour un opérateur ASM : **résoudre les enregistrements DNS** d'un domaine déjà connu. Cas d'usage typiques :

1. **Inventaire des MX** — quels serveurs SMTP reçoivent le mail du domaine (signal de risque : MX pointant vers un fournisseur que l'opérateur ne contrôle plus).
2. **NS de référence** — qui héberge la zone DNS (NS chez un registrar inconnu = potentiel détournement).
3. **TXT** — SPF/DKIM/DMARC, vérifications d'identité de service tiers (Atlassian, GitHub, Google, etc.) — chaque entrée est un signal sur les services SaaS adoptés.
4. **CAA** — quelles autorités de certification sont autorisées à émettre des certificats pour le domaine. Une CAA absente ou trop permissive est un risque concret.
5. **A / AAAA** — IPs derrière le domaine, sans passer par `tcp_probe`. Permet un inventaire passif rapide.
6. **SOA** — métadonnées de zone (refresh, expire, serial). Détecte des zones orphelines (SOA serial figé depuis des mois).

`subdomain_enum` répond à une question différente : « quels sous-domaines existent sous ce domaine ? ». Le nouveau scanner répond à : « quelles **entrées DNS** sont publiées par ce domaine connu ? ». Les deux sont complémentaires.

## Ce qui change

1. **Nouveau `scan_kind` : `dns_records`** dans le contrat `ScanJobV1` (enum de [`packages/job-schema/scan_job_v1.json`](../../../packages/job-schema/scan_job_v1.json)).
2. **Nouveau binaire Go : `apps/scanner/cmd/scanner-dns_records/main.go`** qui consomme la queue `scan:dns_records` via le runtime partagé (cf. `apps/scanner/internal/runtime/`).
3. **Tool MCP `request_scan` étendu** : `scan_kind` accepte désormais `dns_records`. La cible DOIT être de `target_kind = "domain"` ou `host` ; un `target_kind = "ip"` ou `cidr` est rejeté avec `invalid_target` car résoudre les records DNS d'une IP n'a pas de sens.
4. **Linter `scripts/check_scanner_specialization.sh`** : ajout de `dns_records` à l'allowlist des binaires attendus (6 binaires au lieu de 5).
5. **Documentation** : la page [`docs/positioning/agent-knowledge-base.md`](../../../docs/positioning/agent-knowledge-base.md) liste désormais `dns_records` parmi les `scan_kind` couverts en v1. README quickstart inchangé.

## Contraintes

- **Scope-driven** : `dns_records` reste contraint par le scope déclaré par l'opérateur — résoudre les records d'un domaine hors scope est rejeté avec `out-of-scope` (même règle que `request_scan` aujourd'hui, validée par `Reconaut::ScanEnqueuer#ensure_in_scope!`).
- **Pas de zone transfer (AXFR)**. Le scanner émet des **requêtes individuelles par type** (A/AAAA/MX/NS/TXT/CAA/SOA), pas un AXFR. AXFR serait offensif (tente d'extraire la zone entière) et la plupart des résolveurs publics le bloquent ; c'est cohérent avec le non-objectif "pas de scan offensif" du projet.
- **Résolveur configurable**. Le binaire accepte `RECONAUT_DNS_RESOLVER` (défaut : résolveur système). Permet à l'opérateur de pointer un résolveur interne (Unbound, Pi-hole local) plutôt que d'utiliser le DNS public.
- **Timeout par requête : 5 s** (configurable via `RECONAUT_DNS_TIMEOUT`). Une zone lente ne bloque pas le worker.
- **Pas de cache local côté scanner** au-delà de ce que le résolveur OS fournit. La déduplication est portée par `idempotency_key` côté Rails.
- **Ingestion via `ScanResultV1`** : le résultat émis par le worker DOIT être conforme au schéma canonique (cf. [`reposition-as-agent-knowledge-base`](../reposition-as-agent-knowledge-base/specs/integrations/spec.md)). Les `findings` portent une entrée par enregistrement DNS résolu, avec un type uniforme (`dns_record`).

## Non-objectifs (hors scope de ce change)

- **Zone transfer (AXFR)** — explicitement exclu (offensif et inutile en pratique).
- **DNSSEC validation** — différé. Le scanner remonte les enregistrements résolus tels quels ; la validation de signature peut être ajoutée par un futur change `add-dnssec-validation`.
- **DNS over HTTPS / DNS over TLS** — différé. Le résolveur système est utilisé en v1 ; DoH/DoT seront un choix de configuration ultérieur.
- **Reverse DNS (PTR)** — différé. Couvert plus tard par un éventuel scanner spécialisé `reverse_dns` ou intégré dans `subdomain_enum`.
- **Fuzzing/permutation de domaines** — relève de `subdomain_enum`, pas de ce scanner.
- **Détection d'anomalies sur les records** (TXT suspect, CAA absent, etc.) — c'est la couche d'analyse IA (`ai-optimization`) qui exploitera les données ingérées par ce scanner. Le scanner se contente de **collecter**.

## Décisions prises

1. **Scanner séparé plutôt qu'extension de `subdomain_enum`.** Justifié par la spécialisation des binaires (cf. `replace-web-with-tui` §3.1) et par la sémantique distincte (résolution vs énumération). Importer un client DNS dans `subdomain_enum` mélangerait deux capacités sans bénéfice.
2. **Liste de types fixée en v1** : A, AAAA, MX, NS, TXT, CAA, SOA, CNAME. Couvre 95 % des besoins ASM. Les types exotiques (NAPTR, SRV, DS, DNSKEY, etc.) peuvent être ajoutés au cas par cas si l'opérateur a un cas d'usage concret.
3. **Pas d'AXFR.** Cohérent avec le non-objectif "pas de scan offensif" et inutile contre les résolveurs publics modernes.
4. **Résolveur OS par défaut** plutôt que client DNS maison. Bénéficie du cache OS et reste configurable via `RECONAUT_DNS_RESOLVER` pour pointer un résolveur interne.
5. **Cible domaine ou host uniquement.** Résoudre les records DNS d'une IP ou d'un CIDR n'a pas de sens — c'est le rôle de `tcp_probe` ou d'un futur `reverse_dns`.

## Différé (non bloquant, parqué pour plus tard)

- **DNSSEC validation** — change ultérieur `add-dnssec-validation`.
- **DoH / DoT** — change `add-dns-encrypted-resolvers` si la demande émerge.
- **Reverse DNS** — change `add-reverse-dns-scanner`.
- **Détection d'anomalies sur les records** — relève de la couche IA, pas du scanner.
- **Cache de résolution coté Rails** (TTL des records persistés et déclenchement de re-scan basé sur expiration) — couche au-dessus du scanner, intégrable plus tard avec le planificateur adaptatif.
