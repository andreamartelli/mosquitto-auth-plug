# Load our module (and misc) configuration from config.mk
# It also contains MOSQUITTO_SRC
include config.mk

BE_CFLAGS =
BE_LDFLAGS =
BE_LDADD =
BE_DEPS =
OBJS = auth-plug.o base64.o log.o hash.o be-psk.o backends.o cache.o

BACKENDS =
BACKENDSTR =

ifneq ($(BACKEND_CDB),no)
	BACKENDS += -DBE_CDB
	BACKENDSTR += CDB

	CDBDIR = contrib/tinycdb-0.78
	CDB = $(CDBDIR)/cdb
	CDBINC = $(CDBDIR)/
	CDBLIB = $(CDBDIR)/libcdb.a
	BE_CFLAGS += -I$(CDBINC)/
	BE_LDFLAGS += -L$(CDBDIR)
	BE_LDADD = -lcdb
	BE_DEPS += $(CDBLIB)
	OBJS += be-cdb.o
endif

ifneq ($(BACKEND_MYSQL),no)
	BACKENDS += -DBE_MYSQL
	BACKENDSTR += MySQL

	BE_CFLAGS += `mysql_config --cflags`
	BE_LDADD += `mysql_config --libs`
	OBJS += be-mysql.o
endif

ifneq ($(BACKEND_SQLITE),no)
	BACKENDS += -DBE_SQLITE
	BACKENDSTR += SQLite

	BE_LDADD += -lsqlite3
	OBJS += be-sqlite.o
endif

ifneq ($(BACKEND_REDIS),no)
	BACKENDS += -DBE_REDIS
	BACKENDSTR += Redis

	BE_CFLAGS += -I/usr/local/include/hiredis
	BE_LDFLAGS += -L/usr/local/lib
	BE_LDADD += -lhiredis
	OBJS += be-redis.o
endif

ifneq ($(BACKEND_POSTGRES),no)
	BACKENDS += -DBE_POSTGRES
	BACKENDSTR += PostgreSQL

	BE_CFLAGS += -I`pg_config --includedir`
	BE_LDADD += -L`pg_config --libdir` -lpq
	OBJS += be-postgres.o
endif

ifneq ($(BACKEND_LDAP),no)
	BACKENDS += -DBE_LDAP
	BACKENDSTR += LDAP

	BE_LDADD = -lldap -llber
	OBJS += be-ldap.o
endif

ifneq ($(BACKEND_HTTP), no)
	BACKENDS+= -DBE_HTTP
	BACKENDSTR += HTTP

	BE_LDADD += -lcurl
	OBJS += be-http.o
endif

OSSLINC = -I$(OPENSSLDIR)/include
OSSLIBS = -L$(OPENSSLDIR)/lib -lcrypto

CFLAGS = -I$(MOSQUITTO_SRC)/src/
CFLAGS += -I$(MOSQUITTO_SRC)/lib/
ifneq ($(OS),Windows_NT)
	CFLAGS += -fPIC -Wall -Werror 
endif
CFLAGS += $(BACKENDS) $(BE_CFLAGS) -I$(MOSQ)/src -DDEBUG=1 $(OSSLINC)
LDFLAGS = $(BE_LDFLAGS) -L$(MOSQUITTO_SRC)/lib/
# LDFLAGS += -Wl,-rpath,$(../../../../pubgit/MQTT/mosquitto/lib) -lc
# LDFLAGS += -export-dynamic
LDFLAGS += -lcares
LDADD = $(BE_LDADD) $(OSSLIBS) -lmosquitto

all: printconfig auth-plug.so np

printconfig:
	@echo "Selected backends:         $(BACKENDSTR)"
	@echo "Using mosquitto source dir: $(MOSQUITTO_SRC)"
	@echo "OpenSSL install dir:        $(OPENSSLDIR)"
	@echo
	@echo "If you changed the backend selection, you might need to 'make clean' first"
	@echo

auth-plug.so : $(OBJS) $(BE_DEPS)
	$(CC) $(CFLAGS) $(LDFLAGS) -fPIC -shared -o $@ $(OBJS) $(BE_DEPS) $(LDADD)

be-redis.o: be-redis.c be-redis.h log.h hash.h Makefile
be-sqlite.o: be-sqlite.c be-sqlite.h Makefile
auth-plug.o: auth-plug.c be-cdb.h be-mysql.h be-sqlite.h Makefile cache.h
be-psk.o: be-psk.c be-psk.h Makefile
be-cdb.o: be-cdb.c be-cdb.h Makefile
be-mysql.o: be-mysql.c be-mysql.h Makefile
be-ldap.o: be-ldap.c be-ldap.h Makefile
be-sqlite.o: be-sqlite.c be-sqlite.h Makefile
base64.o: base64.c base64.h Makefile
log.o: log.c log.h Makefile
hash.o: hash.c hash.h uthash.h Makefile
be-postgres.o: be-postgres.c be-postgres.h Makefile
cache.o: cache.c cache.h uthash.h Makefile
be-http.o: be-http.c be-http.h Makefile backends.h

np: np.c base64.o
	$(CC) $(CFLAGS) $^ -o $@ $(OSSLIBS)

$(CDBLIB):
	(cd $(CDBDIR); make libcdb.a cdb )

pwdb.cdb: pwdb.in
	$(CDB) -c -m  pwdb.cdb pwdb.in
clean :
	rm -f *.o *.so np
	(cd contrib/tinycdb-0.78; make realclean )

config.mk:
	@echo "Please create your own config.mk file"
	@echo "You can use config.mk.in as base"
	@false
