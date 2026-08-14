##########################################################################
#
#                foreign-data wrapper for ODBC
#
# Copyright (c) 2011, PostgreSQL Global Development Group
# Copyright (c) 2016, CARTO
# Copyright (c) 2026, Softinent
#
# This software is released under the PostgreSQL Licence
#
# Author: Zheng Yang <zhengyang4k@gmail.com>
#
# IDENTIFICATION
#                 odbc_fdw/Makefile
#
##########################################################################

MODULE_big = odbc_fdw
OBJS = \
	src/odbc_fdw.o \
	src/odbc_fdw_options.o \
	src/odbc_fdw_odbc.o \
	src/odbc_fdw_scan.o \
	src/odbc_fdw_import.o

EXTENSION = odbc_fdw

# ONE version string, and it is the same string as the git tag. Every future
# release adds `odbc_fdw--<prev>--<new>.sql` here so ALTER EXTENSION UPDATE
# works; for a C-only change an EMPTY upgrade script is the honest artefact,
# because the alternative is DROP and CREATE, which CASCADEs a warehouse's
# foreign tables away.
DATA = sql/odbc_fdw--1.0.2.sql \
       sql/odbc_fdw--1.0.0--1.0.1.sql \
       sql/odbc_fdw--1.0.1--1.0.2.sql

TEST_DIR = test/
REGRESS = $(notdir $(basename $(sort $(wildcard $(TEST_DIR)/sql/*test.sql))))
REGRESS_OPTS = --inputdir='$(TEST_DIR)' --outputdir='$(TEST_DIR)' --user='postgres' --load-extension=odbc_fdw

SHLIB_LINK = -lodbc

ifdef DEBUG
override CFLAGS += -DDEBUG -g -O0
endif

DOCKER_GOALS = \
	docker-build docker-shell docker-test docker-sqlite docker-mysql docker-mssql \
	docker-hana docker-hana-seed docker-hana-clean \
	docker-oracle docker-oracle-seed docker-oracle-clean \
	docker-test-amd64 docker-test-arm64 docker-test-all \
	docker-hana-amd64 docker-hana-arm64 docker-hana-all \
	docker-hana-seed-amd64 docker-hana-seed-arm64 \
	docker-hana-clean-amd64 docker-hana-clean-arm64 \
	docker-oracle-amd64 docker-oracle-seed-amd64 docker-oracle-clean-amd64
NON_DOCKER_GOALS = $(filter-out $(DOCKER_GOALS),$(MAKECMDGOALS))

# A Docker-only command must be usable on a host with no PostgreSQL headers or
# pg_config at all. Normal extension builds still use PGXS exactly as upstream
# did; mixing a Docker target with any normal target intentionally loads PGXS.
ifeq ($(strip $(NON_DOCKER_GOALS)),)
ifneq ($(strip $(MAKECMDGOALS)),)
else
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
endif
else
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
endif

GENERATED_SQL_FILES = $(wildcard $(TEST_DIR)/sql/*.sql)

integration_tests:
	bash test/tests-generator.sh
	make installcheck

DOCKER_COMPOSE ?= docker compose

.PHONY: \
	docker-build docker-shell docker-test docker-sqlite docker-mysql docker-mssql \
	docker-hana docker-hana-seed docker-hana-clean \
	docker-oracle docker-oracle-seed docker-oracle-clean \
	docker-test-amd64 docker-test-arm64 docker-test-all \
	docker-hana-amd64 docker-hana-arm64 docker-hana-all \
	docker-hana-seed-amd64 docker-hana-seed-arm64 \
	docker-hana-clean-amd64 docker-hana-clean-arm64 \
	docker-oracle-amd64 docker-oracle-seed-amd64 docker-oracle-clean-amd64

# Docker is the supported development environment. The local smoke test needs
# no credentials; the HANA and Oracle suites are opt-in and read the gitignored
# .env file.
docker-build:
	$(DOCKER_COMPOSE) build dev

docker-shell:
	$(DOCKER_COMPOSE) build dev
	$(DOCKER_COMPOSE) run --rm dev

docker-test:
	$(DOCKER_COMPOSE) build test
	$(DOCKER_COMPOSE) run --rm test

docker-sqlite:
	$(DOCKER_COMPOSE) build sqlite
	$(DOCKER_COMPOSE) run --rm sqlite

docker-mysql:
	$(DOCKER_COMPOSE) build mysql
	$(DOCKER_COMPOSE) up -d --wait mysql-db
	$(DOCKER_COMPOSE) run --rm mysql

# SQL Server 2025's Linux server image is amd64-only. The test runner and
# Microsoft ODBC client remain native on both amd64 and arm64; Docker emulates
# only the isolated Express database service on an arm64 development host.
docker-mssql:
	$(DOCKER_COMPOSE) build mssql
	$(DOCKER_COMPOSE) up -d --wait mssql-db
	$(DOCKER_COMPOSE) run --rm mssql

# Explicit platforms make the non-native image testable through Docker's
# emulation support. They are intentionally separate from docker-test, whose
# native-platform behaviour remains the fast development default.
docker-test-amd64:
	DOCKER_DEFAULT_PLATFORM=linux/amd64 $(DOCKER_COMPOSE) build test
	DOCKER_DEFAULT_PLATFORM=linux/amd64 $(DOCKER_COMPOSE) run --rm test

docker-test-arm64:
	DOCKER_DEFAULT_PLATFORM=linux/arm64 $(DOCKER_COMPOSE) build test
	DOCKER_DEFAULT_PLATFORM=linux/arm64 $(DOCKER_COMPOSE) run --rm test

docker-test-all: docker-test-amd64 docker-test-arm64

docker-hana:
	$(DOCKER_COMPOSE) build hana
	$(DOCKER_COMPOSE) run --rm hana

docker-hana-amd64:
	DOCKER_DEFAULT_PLATFORM=linux/amd64 $(DOCKER_COMPOSE) build hana
	DOCKER_DEFAULT_PLATFORM=linux/amd64 $(DOCKER_COMPOSE) run --rm hana

docker-hana-arm64:
	DOCKER_DEFAULT_PLATFORM=linux/arm64 $(DOCKER_COMPOSE) build hana
	DOCKER_DEFAULT_PLATFORM=linux/arm64 $(DOCKER_COMPOSE) run --rm hana

docker-hana-all: docker-hana-amd64 docker-hana-arm64

# This is deliberately separate from docker-hana: it replaces or removes only
# ODBC_FDW_* fixture tables in HANA_SCHEMA.
docker-hana-seed:
	$(DOCKER_COMPOSE) build hana-seed
	$(DOCKER_COMPOSE) run --rm hana-seed

docker-hana-seed-amd64:
	DOCKER_DEFAULT_PLATFORM=linux/amd64 $(DOCKER_COMPOSE) build hana-seed
	DOCKER_DEFAULT_PLATFORM=linux/amd64 $(DOCKER_COMPOSE) run --rm hana-seed

docker-hana-seed-arm64:
	DOCKER_DEFAULT_PLATFORM=linux/arm64 $(DOCKER_COMPOSE) build hana-seed
	DOCKER_DEFAULT_PLATFORM=linux/arm64 $(DOCKER_COMPOSE) run --rm hana-seed

docker-hana-clean:
	$(DOCKER_COMPOSE) build hana-clean
	$(DOCKER_COMPOSE) run --rm hana-clean

docker-hana-clean-amd64:
	DOCKER_DEFAULT_PLATFORM=linux/amd64 $(DOCKER_COMPOSE) build hana-clean
	DOCKER_DEFAULT_PLATFORM=linux/amd64 $(DOCKER_COMPOSE) run --rm hana-clean

docker-hana-clean-arm64:
	DOCKER_DEFAULT_PLATFORM=linux/arm64 $(DOCKER_COMPOSE) build hana-clean
	DOCKER_DEFAULT_PLATFORM=linux/arm64 $(DOCKER_COMPOSE) run --rm hana-clean

# Oracle uses a PDB service name (DBQ=//host:port/service), never an SID. Like
# HANA, seeding and cleanup are explicit because they mutate a real remote test
# database; the probe itself is read-only through odbc_fdw.
docker-oracle:
	$(DOCKER_COMPOSE) build oracle
	$(DOCKER_COMPOSE) run --rm oracle

docker-oracle-amd64:
	$(MAKE) docker-oracle

docker-oracle-seed:
	$(DOCKER_COMPOSE) build oracle-seed
	$(DOCKER_COMPOSE) run --rm oracle-seed

docker-oracle-seed-amd64:
	$(MAKE) docker-oracle-seed

docker-oracle-clean:
	$(DOCKER_COMPOSE) build oracle-clean
	$(DOCKER_COMPOSE) run --rm oracle-clean

docker-oracle-clean-amd64:
	$(MAKE) docker-oracle-clean
