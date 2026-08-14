# syntax=docker/dockerfile:1.7

# Pin the PostgreSQL base and both proprietary ODBC clients as build inputs.
# Change a client version and all of its architecture-specific digests in the
# same commit; credentials and database coordinates belong in .env, versions
# never do.
ARG PG_IMAGE=postgres:18-trixie@sha256:d129b9577d274bb96cbd44d902bdeb1b935c89247d161241e9154cba64e13df4
ARG HANA_CLIENT_VERSION=2.29.25
ARG HANA_CLIENT_SHA256_AMD64=3836373eaa62c9461f6803f2102c9fd899439bad6329e10f71f32ec673c006b7
ARG HANA_CLIENT_SHA256_ARM64=35cca282fe96f81b5846d7cb19f7c5e786a38378938762808eaf9965e3e852d7
ARG HANA_DRIVER_SHA256_AMD64=a1bab067dfcc771ab87f4f0c6f8af5400de22f2959850f613f1d95b59899627b
ARG HANA_DRIVER_SHA256_ARM64=db4b4cb73c74319aa4cd4c3edf735471d999e615a2317a172af64d81a6805547
ARG HANA_SQLDBC_SHA256_AMD64=d0be5b01571456e4389b3d54941043cadab211aa8a497d6179ebdce4ccd4b29b
ARG HANA_SQLDBC_SHA256_ARM64=e7439a37a00a52ee772877470783373ce32a5ed281d1ff110739892837f99771
ARG ORACLE_CLIENT_VERSION=21.23.0.0.0dbru
ARG ORACLE_CLIENT_DOWNLOAD_DIR=2123000
ARG ORACLE_CLIENT_INSTALL_DIR=instantclient_21_23
ARG ORACLE_BASIC_SHA256_AMD64=68a6ccd7ca6fbfb4d2914bd6531a8599fdb75841b8d47df5256bfef40d020820
ARG ORACLE_ODBC_SHA256_AMD64=aec81a0e2660c1154690d7b1334255973072cc1a38b23134301a94091038a365

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
COPY Makefile odbc_fdw.control /workspace/
COPY src/ /workspace/src/
COPY odbc_fdw--*.sql /workspace/
COPY docker/ /workspace/docker/
COPY test/hana/ /workspace/test/hana/
COPY test/oracle/ /workspace/test/oracle/
RUN cc -std=c11 -Wall -Wextra -Werror -O2 /workspace/test/hana/hana-exec.c \
        -lodbc -o /usr/local/bin/hana-exec \
    && cc -std=c11 -Wall -Wextra -Werror -O2 /workspace/test/oracle/oracle-exec.c \
        -lodbc -o /usr/local/bin/oracle-exec \
    && chmod 0555 /usr/local/bin/hana-exec \
    && chmod 0555 /usr/local/bin/oracle-exec \
    && chmod +x /workspace/docker/*.sh /workspace/test/hana/*.sh /workspace/test/oracle/*.sh

# Oracle does not publish Instant Client 21 for Linux ARM64. Keep the ordinary
# and HANA test runners multi-architecture, and isolate Oracle in an amd64-only
# stage that Docker can emulate on ARM hosts. The ODBC package is an add-on to
# Basic, so both official, SHA-pinned archives are extracted together. No DSN,
# tnsnames.ora, database coordinate, or credential is baked into the image.
FROM test-runner AS oracle-test-runner

USER root

# Instant Client 21 requests the pre-time64 SONAME. libaio's public ABI did not
# change, but Debian 13 ships only libaio.so.1t64; expose the SONAME the
# proprietary binary was linked against inside this amd64-only stage.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libaio1t64 \
        libnsl2 \
        unzip \
    && ln -s libaio.so.1t64 /usr/lib/x86_64-linux-gnu/libaio.so.1 \
    && rm -rf /var/lib/apt/lists/*

ARG TARGETARCH
ARG ORACLE_CLIENT_VERSION
ARG ORACLE_CLIENT_DOWNLOAD_DIR
ARG ORACLE_CLIENT_INSTALL_DIR
ARG ORACLE_BASIC_SHA256_AMD64
ARG ORACLE_ODBC_SHA256_AMD64
RUN test "${TARGETARCH}" = amd64 \
    || { echo "Oracle Instant Client 21 is not published for Linux TARGETARCH='${TARGETARCH}'; build oracle-test-runner as linux/amd64." >&2; exit 1; } \
    && curl --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' \
        --output /tmp/oracle-basic.zip \
        "https://download.oracle.com/otn_software/linux/instantclient/${ORACLE_CLIENT_DOWNLOAD_DIR}/instantclient-basic-linux.x64-${ORACLE_CLIENT_VERSION}.zip" \
    && curl --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' \
        --output /tmp/oracle-odbc.zip \
        "https://download.oracle.com/otn_software/linux/instantclient/${ORACLE_CLIENT_DOWNLOAD_DIR}/instantclient-odbc-linux.x64-${ORACLE_CLIENT_VERSION}.zip" \
    && echo "${ORACLE_BASIC_SHA256_AMD64}  /tmp/oracle-basic.zip" | sha256sum --check --strict - \
    && echo "${ORACLE_ODBC_SHA256_AMD64}  /tmp/oracle-odbc.zip" | sha256sum --check --strict - \
    && install -d -m 0755 /opt/oracle \
    && unzip -oq /tmp/oracle-basic.zip -d /opt/oracle \
    && unzip -oq /tmp/oracle-odbc.zip -d /opt/oracle \
    && test -f "/opt/oracle/${ORACLE_CLIENT_INSTALL_DIR}/libsqora.so.21.1" \
    && chown -R root:root "/opt/oracle/${ORACLE_CLIENT_INSTALL_DIR}" \
    && printf '%s\n' "/opt/oracle/${ORACLE_CLIENT_INSTALL_DIR}" \
        > /etc/ld.so.conf.d/oracle-instantclient.conf \
    && ldconfig \
    && test "$(ldd "/opt/oracle/${ORACLE_CLIENT_INSTALL_DIR}/libsqora.so.21.1" | grep -c 'not found')" -eq 0 \
    && printf '%s\n' \
        '[Oracle 21 ODBC driver]' \
        'Description = Oracle Instant Client 21 ODBC driver baked into this test image' \
        "Driver = /opt/oracle/${ORACLE_CLIENT_INSTALL_DIR}/libsqora.so.21.1" \
        >> /etc/odbcinst.ini \
    && odbcinst -q -d | grep -Fx '[Oracle 21 ODBC driver]' \
    && rm -f /tmp/oracle-basic.zip /tmp/oracle-odbc.zip

ENV NLS_LANG=.AL32UTF8
ENV TNS_ADMIN=/opt/oracle/instantclient_21_23/network/admin
