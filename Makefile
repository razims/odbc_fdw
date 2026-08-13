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
DATA = odbc_fdw--1.0.0.sql

TEST_DIR = test/
REGRESS = $(notdir $(basename $(sort $(wildcard $(TEST_DIR)/sql/*test.sql))))
REGRESS_OPTS = --inputdir='$(TEST_DIR)' --outputdir='$(TEST_DIR)' --user='postgres' --load-extension=odbc_fdw

SHLIB_LINK = -lodbc

ifdef DEBUG
override CFLAGS += -DDEBUG -g -O0
endif

DOCKER_GOALS = docker-build docker-shell docker-test docker-hana docker-hana-seed docker-hana-clean
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

.PHONY: docker-build docker-shell docker-test docker-hana docker-hana-seed docker-hana-clean

# Docker is the supported development environment. The local smoke test needs
# no credentials; the HANA suite is opt-in and reads the gitignored .env file.
docker-build:
	$(DOCKER_COMPOSE) build dev

docker-shell:
	$(DOCKER_COMPOSE) build dev
	$(DOCKER_COMPOSE) run --rm dev

docker-test:
	$(DOCKER_COMPOSE) build test
	$(DOCKER_COMPOSE) run --rm test

docker-hana:
	$(DOCKER_COMPOSE) build hana
	$(DOCKER_COMPOSE) run --rm hana

# This is deliberately separate from docker-hana: it replaces or removes only
# ODBC_FDW_* fixture tables in HANA_SCHEMA.
docker-hana-seed:
	$(DOCKER_COMPOSE) build hana-seed
	$(DOCKER_COMPOSE) run --rm hana-seed

docker-hana-clean:
	$(DOCKER_COMPOSE) build hana-clean
	$(DOCKER_COMPOSE) run --rm hana-clean
