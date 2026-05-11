# SPDX-License-Identifier: AGPL-3.0-only
#
# Dockerfile minimal pour apps/api (Rails 8).
#
# Cf. openspec/changes/add-helm-chart/tasks.md §1.1.
#
# Single-arch, unsigned, sans SBOM. Le hardening (multi-arch
# amd64+arm64, signature Sigstore/cosign, SBOM CycloneDX) relève de
# `add-oci-release` futur (cf. init §8.1/§8.2).

FROM ruby:3.4-slim

ENV RAILS_ENV=production \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT="development test" \
    RAILS_LOG_TO_STDOUT=1 \
    DEBIAN_FRONTEND=noninteractive

# Build deps : libpq pour pg, build-essential pour les gems natives,
# git pour les sources Git dans le Gemfile (le cas échéant), curl
# pour le healthcheck embarqué.
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        build-essential \
        libpq-dev \
        postgresql-client \
        curl \
        git && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy Gemfile en premier pour profiter du cache Docker tant que les
# dépendances ne changent pas.
COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4 --retry 3

# Copy le reste du code applicatif.
COPY . .

# Bootsnap pour accélérer le boot (compile les ASTs au build time).
RUN if [ -f config/boot.rb ]; then \
      bundle exec bootsnap precompile --gemfile app/ lib/ config/ 2>/dev/null || true; \
    fi

EXPOSE 3000

# Healthcheck local au container : Rails doit répondre 200 sur /healthz.
# Le k8s probe et le docker-compose healthcheck l'utilisent.
HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=10 \
  CMD curl -fsS http://localhost:3000/healthz || exit 1

CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0", "-p", "3000"]
