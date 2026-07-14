# ee-eid-test-pki — a self-contained Estonian eID test PKI
# that serves CA certificates, CRLs and OCSP.
#
#   docker build -t ee-eid-test-pki .
#   docker run --rm -p 8080:8080 -p 8081:8081 -p 8082:8082 ee-eid-test-pki
#
# Bake different endpoint hostnames into the issued certs (e.g. a compose
# service name) with:
#   docker build -t ee-eid-test-pki \
#     --build-arg PKI_HTTP_BASE=http://eid-test-pki:8080 \
#     --build-arg PKI_OCSP_BASE=http://eid-test-pki:8081 .
#
# Pull base images from a Docker Hub mirror / proxy registry (avoids docker.io):
#   docker build -t ee-eid-test-pki \
#     --build-arg ALPINE_IMAGE=<mirror>/library/alpine:3.21 \
#     --build-arg NGINX_IMAGE=<mirror>/library/nginx:1.27-alpine .

# Base images — override to pull from a Docker Hub mirror / proxy registry.
# (Declared before the first FROM so they apply to every stage.)
ARG ALPINE_IMAGE=alpine:3.21
ARG NGINX_IMAGE=nginx:1.27-alpine
# apk packages come from Alpine's CDN, NOT Docker Hub. On networks without egress
# to dl-cdn.alpinelinux.org, point this at an internal Alpine mirror, e.g.
#   --build-arg APK_MIRROR=https://mirror.example.com/alpine
# It replaces the dl-cdn base URL in /etc/apk/repositories. Empty = use dl-cdn.
ARG APK_MIRROR

# ---------------------------------------------------------------------------
# Stage 1 — generate the PKI (CAs, leaves, CRLs, trust bundles)
# ---------------------------------------------------------------------------
FROM ${ALPINE_IMAGE} AS builder
ARG APK_MIRROR
RUN if [ -n "$APK_MIRROR" ]; then \
      sed -i "s|https://dl-cdn.alpinelinux.org/alpine|$APK_MIRROR|g" /etc/apk/repositories; \
    fi && \
    apk add --no-cache bash openssl

# Endpoint hostnames baked into the AIA / CRL / OCSP URLs of issued certs.
ARG PKI_HTTP_BASE=http://host.docker.internal:8080
ARG PKI_OCSP_BASE=http://host.docker.internal:8081
# FRESH_CA=1 ignores the committed pinned fixtures and mints a new CA set.
ARG FRESH_CA
ENV PKI_HTTP_BASE=${PKI_HTTP_BASE} \
    PKI_OCSP_BASE=${PKI_OCSP_BASE} \
    FRESH_CA=${FRESH_CA} \
    PKI_OUT=/pki/out

WORKDIR /pki
COPY pki/ /pki/
# Optionally replace the committed test CA fixtures with your own via a BuildKit
# secret — a tar of the fixture ca/ dir (contains CA private keys). Keeps the keys
# out of build args, `docker history`, and the build context. Provide a complete,
# internally-consistent set: adopted certs are used as-is (not re-signed), so each
# intermediate must already be signed by the root you also supply. NOTE: adopted CA
# keys end up in the final image (the container issues leaves) — treat it as sensitive.
#   tar -cf ca-fixtures.tar -C <your-fixtures>/ca .
#   docker build --secret id=ca_fixtures,src=ca-fixtures.tar -t ee-eid-test-pki .
RUN --mount=type=secret,id=ca_fixtures,required=false \
    if [ -s /run/secrets/ca_fixtures ]; then \
      echo "adopting bring-your-own CA fixtures from build secret"; \
      tar -xf /run/secrets/ca_fixtures -C /pki/fixtures/ca; \
    fi && \
    bash /pki/scripts/build-all.sh

# ---------------------------------------------------------------------------
# Stage 2 — serve it (nginx for HTTP certs/CRLs, openssl for OCSP)
# ---------------------------------------------------------------------------
FROM ${NGINX_IMAGE}
# fcgiwrap + spawn-fcgi run the management-API CGI behind nginx (port 8082);
# jq builds the API's JSON responses.
ARG APK_MIRROR
RUN if [ -n "$APK_MIRROR" ]; then \
      sed -i "s|https://dl-cdn.alpinelinux.org/alpine|$APK_MIRROR|g" /etc/apk/repositories; \
    fi && \
    apk add --no-cache bash openssl fcgiwrap spawn-fcgi jq

# Toolkit + generated material (keys/certs/CRLs baked in for stable identity).
COPY --from=builder /pki /pki
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY management/api/dispatch.sh /usr/local/bin/pki-api.cgi
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/pki-api.cgi

# Re-declare the endpoint bases in this stage and carry them into the runtime
# ENV so that regeneration at container start (REGENERATE=1, or an empty mounted
# /pki/out) uses the SAME URLs baked at build — and can be overridden per run,
# e.g. a public URL:  -e PKI_HTTP_BASE=https://pki.example.com -e REGENERATE=1
ARG PKI_HTTP_BASE=http://host.docker.internal:8080
ARG PKI_OCSP_BASE=http://host.docker.internal:8081
ENV PKI_HTTP_BASE=${PKI_HTTP_BASE} \
    PKI_OCSP_BASE=${PKI_OCSP_BASE} \
    PKI_OUT=/pki/out
EXPOSE 8080 8081 8082

# HTTP (CA certs + CRLs + trust bundles) is the healthcheck target.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD wget -qO- http://127.0.0.1:8080/trust/community-roots.pem >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
