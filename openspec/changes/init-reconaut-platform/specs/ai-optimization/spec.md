# Spec delta : ai-optimization

## ADDED Requirements

### Requirement: Adaptive Scan Scheduling
Le planificateur DEVRA prioriser les cibles de scan par gain d'information attendu, calculé à partir du taux de churn glissant sur 7 jours, de l'intérêt déclaré par le tenant et du temps écoulé depuis le dernier scan réussi. Chaque décision de planification DOIT être auditable.

#### Scenario: Cible à fort churn priorisée
- **GIVEN** un `/24` dont le taux de churn glissant sur 7 jours est > 2,0 (services ajoutés ou retirés par jour et par hôte)
- **WHEN** le planificateur construit la prochaine fenêtre de scan
- **THEN** cette plage est planifiée au moins 4× plus fréquemment qu'une plage à faible churn (< 0,1) de même nombre d'IP et de même intérêt tenant
- **AND** la décision de priorité (entrées et score calculé) est récupérable via `GET /scheduler/decisions/{id}`

#### Scenario: Intérêt déclaré par le tenant booste le classement
- **GIVEN** un tenant a marqué le CIDR `203.0.113.0/24` avec `interest=high`
- **WHEN** le planificateur classe les cibles
- **THEN** le score de cette plage est multiplié par le coefficient d'intérêt tenant configuré (défaut 3×) et le boost est tracé dans l'audit de décision

### Requirement: Anomaly Detection on Scan Results
Le pipeline DOIT marquer un hôte comme `anomaly_candidate` lorsque son profil de services courant dévie de plus de 3σ par rapport à son baseline glissant sur 30 jours, et DOIT faire remonter les hôtes marqués dans le flux d'anomalies du tenant en moins de 5 minutes après l'observation de la déviation.

#### Scenario: Nouveau service exposé soudain
- **GIVEN** un hôte qui n'a exposé que TCP/443 sur les 90 derniers jours de scans
- **WHEN** une sonde trouve aussi TCP/22 ouvert
- **THEN** l'hôte est tagué `anomaly_candidate` avec la raison `new_port:22`
- **AND** le tag apparaît dans le flux d'anomalies du tenant en moins de 5 minutes après la fin de la sonde

#### Scenario: Hôte stable reste non marqué
- **GIVEN** un hôte dont le profil de services est stable depuis 30 jours
- **WHEN** un nouveau scan confirme le même ensemble de services ouverts
- **THEN** aucun tag d'anomalie n'est créé pour cet hôte
