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
OBJS = odbc_fdw.o

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

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

GENERATED_SQL_FILES = $(wildcard $(TEST_DIR)/sql/*.sql)

integration_tests:
	bash test/tests-generator.sh
	make installcheck
