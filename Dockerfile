# syntax=docker/dockerfile:1.7

# Pin the PostgreSQL base and every downloaded client or build input. Change a
# version and all of its architecture-specific digests in the same commit.
# External database coordinates belong in .env; versions never do.
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
ARG SQLITE_VERSION=3.53.4
ARG SQLITE_RELEASE=3530400
ARG SQLITE_SHA3_256=454e45f61c6bd75b7420e7190732dea03ce6639c63ada47bbc592f67fc340338
ARG MYSQL_ODBC_VERSION=9.7.0
ARG MYSQL_ODBC_SHA256_AMD64=bbdf2b349ed642d4dd5cf39f7cc05fcf39f7e99b318fc838eb3b29920a6eaf50
ARG MYSQL_ODBC_SHA256_ARM64=8c15abaac3920da72d5ceef86a2eab9e8f4b3d5a44e201e00e5326dc54d81bd9
ARG MSSQL_ODBC_VERSION=18.6.2.1-1
ARG MSSQL_ODBC_SHA256_AMD64=11e26f96feb95a7ecf55544441fa24233fab0debe8901e0ca9715c19fea05ab0
ARG MSSQL_ODBC_SHA256_ARM64=4a7094e9a620d2c2aaf735eec4683d28e9823e5f28e674f0d29f4ec8086e9c49

FROM ${PG_IMAGE} AS dev

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        libsqliteodbc \
        odbc-postgresql \
        openssl \
        postgresql-server-dev-18 \
        sqlite3 \
        unixodbc \
        unixodbc-dev \
    && rm -rf /var/lib/apt/lists/*

# Build the current SQLite core while retaining Debian's portable SQLite ODBC
# bridge. The bridge links to libsqlite3 dynamically, so both the CLI and ODBC
# path exercise this SHA3-pinned core on amd64 and arm64.
ARG SQLITE_VERSION
ARG SQLITE_RELEASE
ARG SQLITE_SHA3_256
RUN curl --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' \
        --output /tmp/sqlite.tar.gz \
        "https://sqlite.org/2026/sqlite-autoconf-${SQLITE_RELEASE}.tar.gz" \
    && test "$(openssl dgst -sha3-256 /tmp/sqlite.tar.gz | awk '{print $2}')" = "${SQLITE_SHA3_256}" \
    && mkdir /tmp/sqlite-source \
    && tar --no-same-owner --strip-components=1 -xzf /tmp/sqlite.tar.gz -C /tmp/sqlite-source \
    && cd /tmp/sqlite-source \
    && ./configure --prefix=/usr/local --disable-static \
    && make -j"$(nproc)" \
    && make install \
    && ldconfig \
    && sqlite3 --version | grep -F "${SQLITE_VERSION}" \
    && odbcinst -q -d | grep -Fx '[SQLite3]' \
    && rm -rf /tmp/sqlite.tar.gz /tmp/sqlite-source

# Install the latest GA MySQL Connector/ODBC Unicode and ANSI drivers from
# Oracle's generic glibc build. The official archives cover both Linux
# architectures used by the development image.
ARG TARGETARCH
ARG MYSQL_ODBC_VERSION
ARG MYSQL_ODBC_SHA256_AMD64
ARG MYSQL_ODBC_SHA256_ARM64
RUN case "${TARGETARCH}" in \
        amd64) mysql_arch=x86-64bit; mysql_sha="${MYSQL_ODBC_SHA256_AMD64}" ;; \
        arm64) mysql_arch=aarch64; mysql_sha="${MYSQL_ODBC_SHA256_ARM64}" ;; \
        *) echo "No MySQL Connector/ODBC archive is pinned for TARGETARCH='${TARGETARCH}'." >&2; exit 1 ;; \
    esac \
    && mysql_archive="mysql-connector-odbc-${MYSQL_ODBC_VERSION}-linux-glibc2.28-${mysql_arch}" \
    && curl --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' \
        --output /tmp/mysql-odbc.tar.gz \
        "https://cdn.mysql.com/Downloads/Connector-ODBC/9.7/${mysql_archive}.tar.gz" \
    && echo "${mysql_sha}  /tmp/mysql-odbc.tar.gz" | sha256sum --check --strict - \
    && tar --no-same-owner -xzf /tmp/mysql-odbc.tar.gz -C /tmp \
    && install -d -m 0755 "/opt/mysql/connector-odbc-${MYSQL_ODBC_VERSION}/lib" \
    && cp -a "/tmp/${mysql_archive}/lib/." "/opt/mysql/connector-odbc-${MYSQL_ODBC_VERSION}/lib/" \
    && install -m 0555 "/tmp/${mysql_archive}/bin/myodbc-installer" /usr/local/bin/myodbc-installer \
    && chown -R root:root "/opt/mysql/connector-odbc-${MYSQL_ODBC_VERSION}" \
    && printf '%s\n' \
        '[MySQL ODBC 9.7 Unicode Driver]' \
        'Description = MySQL Connector/ODBC 9.7 Unicode driver' \
        "Driver = /opt/mysql/connector-odbc-${MYSQL_ODBC_VERSION}/lib/libmyodbc9w.so" \
        '[MySQL ODBC 9.7 ANSI Driver]' \
        'Description = MySQL Connector/ODBC 9.7 ANSI driver' \
        "Driver = /opt/mysql/connector-odbc-${MYSQL_ODBC_VERSION}/lib/libmyodbc9a.so" \
        >> /etc/odbcinst.ini \
    && test "$(ldd "/opt/mysql/connector-odbc-${MYSQL_ODBC_VERSION}/lib/libmyodbc9w.so" | grep -c 'not found')" -eq 0 \
    && odbcinst -q -d | grep -Fx '[MySQL ODBC 9.7 Unicode Driver]' \
    && rm -rf /tmp/mysql-odbc.tar.gz "/tmp/${mysql_archive}"

# Microsoft's current ODBC 18 package is published natively for Debian 13 on
# both amd64 and arm64. Download the exact package rather than adding a mutable
# apt repository to the image, and verify the package index's SHA-256 digest.
ARG MSSQL_ODBC_VERSION
ARG MSSQL_ODBC_SHA256_AMD64
ARG MSSQL_ODBC_SHA256_ARM64
RUN case "${TARGETARCH}" in \
        amd64) mssql_arch=amd64; mssql_sha="${MSSQL_ODBC_SHA256_AMD64}" ;; \
        arm64) mssql_arch=arm64; mssql_sha="${MSSQL_ODBC_SHA256_ARM64}" ;; \
        *) echo "No Microsoft ODBC package is pinned for TARGETARCH='${TARGETARCH}'." >&2; exit 1 ;; \
    esac \
    && mssql_deb="msodbcsql18_${MSSQL_ODBC_VERSION}_${mssql_arch}.deb" \
    && curl --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' \
        --output "/tmp/${mssql_deb}" \
        "https://packages.microsoft.com/debian/13/prod/pool/main/m/msodbcsql18/${mssql_deb}" \
    && echo "${mssql_sha}  /tmp/${mssql_deb}" | sha256sum --check --strict - \
    && apt-get update \
    && ACCEPT_EULA=Y apt-get install -y --no-install-recommends "/tmp/${mssql_deb}" \
    && odbcinst -q -d | grep -Fx '[ODBC Driver 18 for SQL Server]' \
    && rm -f "/tmp/${mssql_deb}" \
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
COPY sql/ /workspace/sql/
COPY docker/ /workspace/docker/
COPY test/common/ /workspace/test/common/
COPY test/hana/ /workspace/test/hana/
COPY test/mssql/ /workspace/test/mssql/
COPY test/mysql/ /workspace/test/mysql/
COPY test/oracle/ /workspace/test/oracle/
COPY test/sqlite/ /workspace/test/sqlite/
RUN cc -std=c11 -Wall -Wextra -Werror -O2 /workspace/test/hana/hana-exec.c \
        -lodbc -o /usr/local/bin/hana-exec \
    && cc -std=c11 -Wall -Wextra -Werror -O2 /workspace/test/oracle/oracle-exec.c \
        -lodbc -o /usr/local/bin/oracle-exec \
    && cc -std=c11 -Wall -Wextra -Werror -O2 /workspace/test/common/odbc-exec.c \
        -lodbc -o /usr/local/bin/odbc-exec \
    && chmod 0555 /usr/local/bin/hana-exec \
    && chmod 0555 /usr/local/bin/oracle-exec \
    && chmod 0555 /usr/local/bin/odbc-exec \
    && chmod +x /workspace/docker/*.sh /workspace/test/hana/*.sh \
        /workspace/test/mssql/*.sh /workspace/test/mysql/*.sh \
        /workspace/test/oracle/*.sh /workspace/test/sqlite/*.sh

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
