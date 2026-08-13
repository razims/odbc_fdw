# syntax=docker/dockerfile:1.7

# Pin the PostgreSQL base and the HANA client as build inputs. The HANA values
# are copied from dwh's measured PostgreSQL 18 image: change each version and
# its architecture-specific digests together, never through .env.
ARG PG_IMAGE=postgres:18-trixie@sha256:d129b9577d274bb96cbd44d902bdeb1b935c89247d161241e9154cba64e13df4
ARG HANA_CLIENT_VERSION=2.29.25
ARG HANA_CLIENT_SHA256_AMD64=3836373eaa62c9461f6803f2102c9fd899439bad6329e10f71f32ec673c006b7
ARG HANA_CLIENT_SHA256_ARM64=35cca282fe96f81b5846d7cb19f7c5e786a38378938762808eaf9965e3e852d7
ARG HANA_DRIVER_SHA256_AMD64=a1bab067dfcc771ab87f4f0c6f8af5400de22f2959850f613f1d95b59899627b
ARG HANA_DRIVER_SHA256_ARM64=db4b4cb73c74319aa4cd4c3edf735471d999e615a2317a172af64d81a6805547
ARG HANA_SQLDBC_SHA256_AMD64=d0be5b01571456e4389b3d54941043cadab211aa8a497d6179ebdce4ccd4b29b
ARG HANA_SQLDBC_SHA256_ARM64=e7439a37a00a52ee772877470783373ce32a5ed281d1ff110739892837f99771

FROM ${PG_IMAGE} AS dev

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        odbc-postgresql \
        postgresql-server-dev-18 \
        unixodbc \
        unixodbc-dev \
    && rm -rf /var/lib/apt/lists/*

# `libodbcHDB.so` is loaded in the PostgreSQL backend, so the image fetches it
# only over HTTPS and verifies both SAP's archive and the two individual files.
# The EULA cookie is a licence acknowledgement, not a credential. Extract only
# the two libraries measured with the HANA probe; do not ship client CLIs or
# installers that create another untracked route to a tenant.
ARG TARGETARCH
ARG HANA_CLIENT_VERSION
ARG HANA_CLIENT_SHA256_AMD64
ARG HANA_CLIENT_SHA256_ARM64
ARG HANA_DRIVER_SHA256_AMD64
ARG HANA_DRIVER_SHA256_ARM64
ARG HANA_SQLDBC_SHA256_AMD64
ARG HANA_SQLDBC_SHA256_ARM64
RUN case "${TARGETARCH}" in \
        amd64) sap_arch=linux-x64 ; \
               tar_sha="${HANA_CLIENT_SHA256_AMD64}" ; \
               driver_sha="${HANA_DRIVER_SHA256_AMD64}" ; \
               sqldbc_sha="${HANA_SQLDBC_SHA256_AMD64}" ;; \
        arm64) sap_arch=linux-arm64 ; \
               tar_sha="${HANA_CLIENT_SHA256_ARM64}" ; \
               driver_sha="${HANA_DRIVER_SHA256_ARM64}" ; \
               sqldbc_sha="${HANA_SQLDBC_SHA256_ARM64}" ;; \
        *) echo "No SAP HANA client is pinned for TARGETARCH='${TARGETARCH}'." >&2; exit 1 ;; \
    esac \
    && curl --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' \
        --header 'Cookie: eula_3_2_agreed=tools.hana.ondemand.com/developer-license-3_2.txt' \
        --output /tmp/hanaclient.tar.gz \
        "https://tools.hana.ondemand.com/additional/hanaclient-${HANA_CLIENT_VERSION}-${sap_arch}.tar.gz" \
    && echo "${tar_sha}  /tmp/hanaclient.tar.gz" | sha256sum --check --strict - \
    && tar xzf /tmp/hanaclient.tar.gz -C /tmp client/client/ODBC.TGZ client/client/SQLDBC.TGZ \
    && install -d -m 0755 /opt/sap/hdbclient \
    && tar --no-same-owner -xzf /tmp/client/client/ODBC.TGZ \
        -C /opt/sap/hdbclient libodbcHDB.so \
    && tar --no-same-owner -xzf /tmp/client/client/SQLDBC.TGZ \
        -C /opt/sap/hdbclient libSQLDBCHDB.so \
    && echo "${driver_sha}  /opt/sap/hdbclient/libodbcHDB.so" | sha256sum --check --strict - \
    && echo "${sqldbc_sha}  /opt/sap/hdbclient/libSQLDBCHDB.so" | sha256sum --check --strict - \
    && chown root:root /opt/sap/hdbclient/libodbcHDB.so /opt/sap/hdbclient/libSQLDBCHDB.so \
    && chmod 0555 /opt/sap/hdbclient/libodbcHDB.so /opt/sap/hdbclient/libSQLDBCHDB.so \
    && printf '%s\n' \
        '[HDBODBC]' \
        'Description = SAP HANA ODBC driver baked into this development image' \
        'Driver = /opt/sap/hdbclient/libodbcHDB.so' \
        >> /etc/odbcinst.ini \
    && odbcinst -q -d | grep -Fx '[HDBODBC]' \
    && rm -rf /tmp/hanaclient.tar.gz /tmp/client

WORKDIR /workspace

# The official image ships the server but not the PGXS headers or makefiles.
ENV PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config

# This image is a development and test tool, not a database service image.
ENTRYPOINT []
CMD ["bash"]

FROM dev AS test-runner

# Copy only the extension and test harness. In particular, .env is excluded
# from the build context by .dockerignore.
COPY Makefile odbc_fdw.c odbc_fdw.control /workspace/
COPY odbc_fdw--*.sql /workspace/
COPY docker/ /workspace/docker/
RUN chmod +x /workspace/docker/run-local-tests.sh /workspace/docker/probe-hana.sh
