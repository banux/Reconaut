# Postgres 16 + TimescaleDB + pgvector + Apache AGE
#
# Une instance Postgres unique porte les trois extensions exigees par
# openspec/changes/add-tech-stack/specs/architecture/spec.md (Postgres
# unique) et openspec/changes/add-graph-retrieval/specs/graph-retrieval/spec.md
# (AGE sur le meme cluster que les tables OLTP).
#
# Choix du base image : timescale/timescaledb-ha (HA = "high availability"
# + extensions multiples). Cette image embarque deja Postgres + TimescaleDB
# + pgvector. Apache AGE est ajoute par-dessus depuis les sources.
FROM timescale/timescaledb-ha:pg16

USER root

ARG AGE_VERSION=PG16/v1.5.0-rc0

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      git \
      ca-certificates \
      flex \
      bison \
      postgresql-server-dev-16 \
 && git clone --depth 1 --branch ${AGE_VERSION} https://github.com/apache/age.git /tmp/age \
 && make -C /tmp/age install \
 && rm -rf /tmp/age \
 && apt-get purge -y --auto-remove \
      build-essential \
      git \
      flex \
      bison \
      postgresql-server-dev-16 \
 && rm -rf /var/lib/apt/lists/*

USER postgres
