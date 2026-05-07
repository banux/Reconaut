-- Extensions exigees par les specs Reconaut.
--
-- Source de verite :
--   - openspec/project.md : Postgres unique avec TimescaleDB + pgvector + AGE
--   - openspec/changes/add-graph-retrieval/specs/graph-retrieval/spec.md
--     -> Requirement: Asset Graph Projection (AGE sur le meme cluster)
--
-- Ce script tourne automatiquement au premier demarrage du conteneur
-- (entrypoint Postgres standard : tout fichier sql sous /docker-entrypoint-initdb.d
-- est execute une seule fois sur la base par defaut).

CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS age;

LOAD 'age';
