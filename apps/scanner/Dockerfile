# SPDX-License-Identifier: AGPL-3.0-only
#
# Dockerfile multi-stage pour les binaires scanner-<kind>.
#
# Cf. openspec/changes/add-helm-chart/tasks.md §1.2.
#
# Stage 1 (builder) : compile chaque binaire `scanner-<kind>` en
# CGO_ENABLED=0 statiquement linké.
# Stage 2 (runtime) : distroless/static-debian12 — pas de shell, pas
# de package manager, ~6 MB. Le dispatch est piloté par la variable
# d'env RECONAUT_SCAN_KIND.

# -------- Stage 1 : builder ---------------------------------------------------
FROM golang:1.26-alpine AS builder

WORKDIR /src

# Copy go.mod / go.sum pour profiter du cache des modules.
COPY go.mod go.sum ./
RUN go mod download

# Copy le reste du code.
COPY . .

# Compile chaque binaire scanner-<kind> statiquement.
# CGO_ENABLED=0 + GOOS=linux pour produire un binaire portable vers
# l'image distroless.
RUN set -eux; \
    mkdir -p /out; \
    for kind in tcp_probe tls_capture http_banner subdomain_enum service_fingerprint dns_records; do \
      CGO_ENABLED=0 GOOS=linux go build \
        -ldflags='-s -w' \
        -o "/out/scanner-${kind}" \
        "./cmd/scanner-${kind}"; \
    done

# Script d'entrypoint qui dispatche selon RECONAUT_SCAN_KIND.
RUN <<'SH' tee /out/entrypoint.sh
#!/bin/sh
set -e
kind="${RECONAUT_SCAN_KIND:-}"
if [ -z "$kind" ]; then
  echo "scanner: RECONAUT_SCAN_KIND non défini ; valeurs valides : tcp_probe | tls_capture | http_banner | subdomain_enum | service_fingerprint | dns_records" >&2
  exit 64
fi
exec "/usr/local/bin/scanner-${kind}" "$@"
SH
RUN chmod +x /out/entrypoint.sh

# -------- Stage 2 : runtime ---------------------------------------------------
# distroless/static fournit ca-certificates + tzdata + nonroot user.
# Pas de shell — l'entrypoint utilise /busybox via le second tag.
# On opte pour distroless:debug pour avoir un /bin/sh minimal (notre
# entrypoint.sh en a besoin pour le dispatch). En prod hardenée
# (relève d'add-oci-release), on inlinera le dispatch en Go pour
# pouvoir repasser sur distroless:static sans shell.
FROM gcr.io/distroless/static-debian12:debug-nonroot

COPY --from=builder /out/scanner-* /usr/local/bin/
COPY --from=builder /out/entrypoint.sh /usr/local/bin/entrypoint.sh

USER nonroot

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
