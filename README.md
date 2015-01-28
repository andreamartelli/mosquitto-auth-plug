# mosquitto-auth-plug

This is a plugin to authenticate and authorize [Mosquitto] users from one
of several distinct back-ends:

* MySQL
* PostgreSQL
* CDB
* SQLite3 database
* [Redis] key/value store
* TLS PSK (the `psk` back-end is a bit of a shim which piggy-backs onto the other database back-ends)
* LDAP
* HTTP (custom HTTP API)

## Introduction

This plugin can perform authentication (check username / password)
and authorization (ACL). Currently not all back-ends have the same capabilities
(the the section on the back-end you're interested in).

| Capability                 | mysql | redis | cdb   | sqlite | ldap | psk | postgres | http |
| -------------------------- | :---: | :---: | :---: | :---:  | :-:  | :-: | :------: | :--: |
| authentication             |   Y   |   Y   |   Y   |   Y    |  Y   |  Y  |    Y     |  Y   |
| superusers                 |   Y   |       |       |        |      |  2  |    Y     |  Y   |
| acl checking               |   Y   |   1   |   1   |   1    |      |  2  |    Y     |  Y   |
| static superusers          |   Y   |   Y   |   Y   |   Y    |      |  2  |    Y     |  Y   |

 1. Currently not implemented; back-end returns TRUE
 2. Dependent on the database used by PSK


Multiple back-ends can be configured simultaneously for authentication, and they're attempted in
the order you specify. Once a user has been authenticated, the _same_ back-end is used to
check authorization (ACLs). Superusers are checked for in all back-ends.
The configuration option is called `auth_opt_backends` and it takes a
comma-separated list of back-end names which are checked in exactly that order.

```
auth_opt_backends cdb,sqlite,mysql,redis,postgres
```

Note: anonymous MQTT connections are assigned a username of configured in the
plugin as `auth_opt_anonusername` and they
are handled by a so-called _fallback back-end_ which is the *first* configured
back-end.

Passwords are obtained from the back-end as a SHA1 hex string (see section
on Passwords below). Even if you try and store a clear-text password,
it simply won't work.

The mysql back-end supports expansion of `%c` and `%u` as clientid and username
respectively. This allows ACLs in the database to look like this:

```
+-----------+---------------------------------+----+
| username  | topic                           | rw |
+-----------+---------------------------------+----+
| bridge-01 | $SYS/broker/connection/%c/state |  2 |
+-----------+---------------------------------+----+
```

The plugin supports so-called _superusers_. These are usernames exempt
from ACL checking. In other words, if a user is a _superuser_, that user
doesn't require ACLs.

## Building the plugin

In order to compile the plugin you'll require a copy of the [Mosquitto] source
code together with the libraries required for the back-end you want to use in
the plugin. OpenSSL is also required.

Copy `config.mk.in` to `config.mk` and modify `config.mk` to suit your building environment, in particular, you have
to configure which back-ends you want to provide as well as the path to the
[Mosquitto] source and its library.

After a `make` you should have a shared object called `auth-plug.so`
which you will reference in your `mosquitto.conf`.

Note that OpenSSL as shipped with OS X is probably too old. You may wish to use a version
supplied by home brew or build your own, and then adapt `OPENSSLDIR` in `config.mk`.

## Configuration

The plugin is configured in [Mosquitto]'s configuration file (typically `mosquitto.conf`),
and it is loaded into Mosquitto auth the ```auth_plugin``` option.


```
auth_plugin /path/to/auth-plug.so
```

Options therein with a leading ```auth_opt_``` are handed to the plugin. The following
"global" ```auth_opt_*``` plugin options exist:

| Option         | default    |  Mandatory  | Meaning               |
| -------------- | ---------- | :---------: | --------------------- |
| backends       |            |     Y       | comma-separated list of back-ends to load |
| superusers     |            |             | fnmatch(3) case-sensitive string

Individual back-ends have their options described in the sections below.

### MySQL

The `mysql` back-end is currently the most feature-complete: it supports
obtaining passwords, checking for _superusers_, and verifying ACLs by
configuring up to three distinct SQL queries used to obtain those results.

You configure the SQL queries in order to adapt to whichever schema
you currently have.

The following `auth_opt_` options are supported by the mysql back-end:

| Option         | default           |  Mandatory  | Meaning               |
| -------------- | ----------------- | :---------: | --------------------- |
| host           | localhost         |             | hostname/address
| port           | 3306              |             | TCP port
| user           |                   |             | username
| pass           |                   |             | password
| dbname         |                   |     Y       | database name
| userquery      |                   |     Y       | SQL for users
| superquery     |                   |             | SQL for superusers
| aclquery       |                   |             | SQL for ACLs
| mysql_opt_reconnect | true         |             | enable MYSQL_OPT_RECONNECT option
| mysql_auto_connect  | true         |             | enable auto_connect function
| anonusername   | anonymous         |             | username to use for anonymous connections
| cacheseconds   | 300               |             | number of seconds to cache ACL lookups. 0 disables

The SQL query for looking up a user's password hash is mandatory. The query
MUST return a single row only (any other number of rows is considered to be
"user not found"), and it MUST return a single column only with the SHA1
password hash. A single `'%s'` in the query string is replaced by the
username attempting to access the broker.

```sql
SELECT pw FROM users WHERE username = '%s' LIMIT 1
```

The SQL query for checking whether a user is a _superuser_ - and thus
circumventing ACL checks - is optional. If it is specified, the query MUST
return a single row with a single value: 0 is false and 1 is true. We recommend
using a `SELECT IFNULL(COUNT(*),0) FROM ...` for this query as it satisfies
both conditions. ). A single `'%s`' in the query string is replaced by the
username attempting to access the broker. The following example uses the
same `users` table, but it could just as well reference a distinct table
or view.

```sql
SELECT IFNULL(COUNT(*), 0) FROM users WHERE username = '%s' AND super = 1
```

The SQL query for checking ACLs is optional, but if it is specified, the
`mysql` back-end can try to limit access to particular topics or topic branches
depending on the value of a database table. The query MAY return zero or more
rows for a particular user, each returning EXACTLY one column containing a
topic (wildcards are supported). A single `'%s`' in the query string is
replaced by the username attempting to access the broker, and a single `'%d`' is
replaced with the integer value `1` signifying a read-only access attempt
(SUB) or `2` signifying a read-write access attempt (PUB).

In the following example, the table has an `INT(1)` column `rw` containing `1` for
readonly topics, and `2` for read-write topics:

```sql
SELECT topic FROM acls WHERE (username = '%s') AND (rw >= %d)
```

Mosquitto configuration for the `mysql` back-end:

```
auth_plugin /home/jpm/mosquitto-auth-plug/auth-plug.so
auth_opt_host localhost
auth_opt_port 3306
auth_opt_dbname test
auth_opt_user jjj
auth_opt_pass supersecret
auth_opt_userquery SELECT pw FROM users WHERE username = '%s'
auth_opt_superquery SELECT COUNT(*) FROM users WHERE username = '%s' AND super = 1
auth_opt_aclquery SELECT topic FROM acls WHERE (username = '%s') AND (rw >= %d)
auth_opt_anonusername AnonymouS
```

Assuming the following database tables:
(Example username:password pairs in plaintext are `andrew:andrew` and `su1:superuser`)

```
mysql> SELECT * FROM users;
+----+----------+--------------------------------------------+-------+
| id | username | pw                                         | super |
+----+----------+--------------------------------------------+-------+
|  1 | andrew   | 02e0a999c50b1f88df7a8f5a04e1b76b35ea6a88   |     0 |
|  3 | su1      | 8e67bb26b358e2ed20fe552ed6fb832f397a507d   |     1 |
+----+----------+--------------------------------------------+-------+

mysql> SELECT * FROM acls;
+----+----------+-------------------+----+
| id | username | topic             | rw |
+----+----------+-------------------+----+
|  1 | andrew   | loc/jjolie        |  1 |
|  2 | andrew   | $SYS/something    |  1 |
|  5 | su1      | mega/secret       |  1 |
+----+----------+-------------------+----+
```

the above SQL queries would enable the following combinations (note the `*` at
the beginning of the line indicating a _superuser_)

```
  andrew     02e0a999c50b1f88df7a8f5a04e1b76b35ea6a88
	loc/jjolie                               PERMIT
	mega/secret                              DENY
	$SYS/something                           PERMIT
* su1        8e67bb26b358e2ed20fe552ed6fb832f397a507d
	loc/jjolie                               DENY
	mega/secret                              PERMIT
	$SYS/something                           DENY
```

The `mysql` back-end will re-connect to the MySQL server when the connection has gone away.
If you wish, you can disable this by configuring:

```
auth_opt_mysql_opt_reconnect false
auth_opt_mysql_auto_connect false
```

### LDAP

The LDAP plugin currently does authentication only; authenticated users are allowed
to publish/subscribe at will.

The user with which Mosquitto connects to the broker is searched in the LDAP directory
via the `ldap_uri` configuration parameter. This LDAP search MUST return exactly one
entry. The user's password is then use with the DN of the entry found to bind to the
directory. If that LDAP bind succeeds, the user is authenticated. In other cases,
authentication fails.


| Option         | default           |  Mandatory  | Meaning     |
| -------------- | ----------------- | :---------: | ----------  |
| binddn         |                   |     Y       | the DN of an object which may search users |
| bindpw         |                   |     Y       | its password                               |
| ldap_uri       |                   |     Y       | an LDAP uri with filter                    |

Example configuration:

```
auth_plugin /path/to/auth-plug.so
auth_opt_backends ldap
auth_opt_binddn cn=manager,dc=mens,dc=de
auth_opt_bindpw s3crit
auth_opt_ldap_uri ldap://127.0.0.1/ou=Users,dc=mens,dc=de?cn?sub?(&(objectclass=inetOrgPerson)(uid=@))

```

### CDB

| Option         | default           |  Mandatory  | Meaning     |
| -------------- | ----------------- | :---------: | ----------  |
| cdbname        |                   |     Y       | path to .cdb |

### SQLITE

| Option          | default           |  Mandatory  | Meaning     |
| --------------- | ----------------- | :---------: | ----------  |
| dbpath          |                   |     Y       | path to database |
| sqliteuserquery |                   |     Y       | SQL for users |

### Redis

| Option         | default           |  Mandatory  | Meaning     |
| -------------- | ----------------- | :---------: | ----------  |
| redis_host     | localhost         |             | hostname / IP address
| redis_port     | 6379              |             | TCP port number |

### HTTP

The `http` back-end is for auth by custom HTTP API.

The following `auth_opt_` options are supported by the `http` back-end:

| Option            | default           |  Mandatory  | Meaning     |
| ----------------- | ----------------- | :---------: | ----------  |
| http_ip           |                   |      Y      | IP address,will skip dns lookup |
| http_port         | 80                |             | TCP port number                 |
| http_hostname     |                   |             | hostname for HTTP header        |
| http_getuser_uri  |                   |      Y      | URI for check username/password |
| http_superuser_uri|                   |      Y      | URI for check superuser         |
| http_aclcheck_uri |                   |      Y      | URI for check acl               |

If the configured URLs return an HTTP status code == `200`, the authentication /
authorization succeeds, else it fails.

| URI-Param         | username | password | topic | acc |
| ----------------- | -------- | -------- | :---: | :-: |
| http_getuser_uri  |   Y      |   Y      |   N   |  N  |
| http_superuser_uri|   Y      |   N      |   N   |  N  |
| http_aclcheck_uri |   Y      |   N      |   Y   |  Y  |

Mosquitto configuration for the `http` back-end:

```
auth_opt_backends http
auth_opt_http_ip 127.0.0.1
auth_opt_http_port 8089
#auth_opt_http_hostname example.org
auth_opt_http_getuser_uri /auth
auth_opt_http_superuser_uri /superuser
auth_opt_http_aclcheck_uri /acl
```

A very simple example service using Python and bottle can be found in [examples/http-auth-be.py](examples/http-auth-be.py).

### PostgreSQL

The `postgres`  like `mysql` back-end is currently the most feature-complete: it supports
obtaining passwords, checking for _superusers_, and verifying ACLs by
configuring up to three distinct SQL queries used to obtain those results.

You configure the SQL queries in order to adapt to whichever schema
you currently have.

The following `auth_opt_` options are supported by the mysql back-end:

| Option         | default           |  Mandatory  | Meaning               |
| -------------- | ----------------- | :---------: | --------------------- |
| host           | localhost         |             | hostname/address
| port           | 5432              |             | TCP port
| user           |                   |             | username
| pass           |                   |             | password
| dbname         |                   |     Y       | database name
| userquery      |                   |     Y       | SQL for users
| superquery     |                   |             | SQL for superusers
| aclquery       |                   |             | SQL for ACLs

The SQL query for looking up a user's password hash is mandatory. The query
MUST return a single row only (any other number of rows is considered to be
"user not found"), and it MUST return a single column only with the SHA1
password hash. A single `'$1'` in the query string is replaced by the
username attempting to access the broker.

```sql
SELECT pass FROM account WHERE username = $1 limit 1
```

The SQL query for checking whether a user is a _superuser_ - and thus
circumventing ACL checks - is optional. If it is specified, the query MUST
return a single row with a single value: 0 is false and 1 is true. We recommend
using a `SELECT COALESCE(COUNT(*),0) FROM ...` for this query as it satisfies
both conditions. ). A single `'$1`' in the query string is replaced by the
username attempting to access the broker. The following example uses the
same `users` table, but it could just as well reference a distinct table
or view.

```sql
SELECT COALESCE(COUNT(*),0) FROM account WHERE username = $1 AND super = 1
```

The SQL query for checking ACLs is optional, but if it is specified, the
`mysql` back-end can try to limit access to particular topics or topic branches
depending on the value of a database table. The query MAY return zero or more
rows for a particular user, each returning EXACTLY one column containing a
topic (wildcards are supported). A single `'$1`' in the query string is
replaced by the username attempting to access the broker, and a single `'$2`' is
replaced with the integer value `1` signifying a read-only access attempt
(SUB) or `2` signifying a read-write access attempt (PUB).

In the following example, the table has a column `rw` containing 1 for
readonly topics, and 2 for read-write topics:

```sql
SELECT topic FROM acl WHERE (username = $1) AND rw >= $2
```

Mosquitto configuration for the `postgres` back-end:

```
auth_plugin /home/jpm/mosquitto-auth-plug/auth-plug.so
auth_opt_host localhost
auth_opt_port 5432
auth_opt_dbname test
auth_opt_user jjj
auth_opt_pass supersecret
auth_opt_userquery SELECT password FROM account WHERE username = $1 limit 1
auth_opt_superquery SELECT COALESCE(COUNT(*),0) FROM account WHERE username = $1 AND mosquitto_super = 1
auth_opt_aclquery SELECT topic FROM acls WHERE (username = $1) AND (rw & $2) > 0```
```
Assuming the following database tables:

```
mysql> SELECT * FROM users;
+----+----------+--------------------------------------------+-------+
| id | username | pw                                         | super |
+----+----------+--------------------------------------------+-------+
|  1 | andrew   | 02e0a999c50b1f88df7a8f5a04e1b76b35ea6a88   |     0 |
|  3 | su1      | 8e67bb26b358e2ed20fe552ed6fb832f397a507d   |     1 |
+----+----------+--------------------------------------------+-------+

mysql> SELECT * FROM acls;
+----+----------+-------------------+----+
| id | username | topic             | rw |
+----+----------+-------------------+----+
|  1 | andrew   | loc/jjolie        |  1 |
|  2 | andrew   | $SYS/something    |  1 |
|  5 | su1      | mega/secret       |  1 |
+----+----------+-------------------+----+
```

the above SQL queries would enable the following combinations (note the `*` at
the beginning of the line indicating a _superuser_)

```
  andrew     02e0a999c50b1f88df7a8f5a04e1b76b35ea6a88
	loc/jjolie                               PERMIT
	mega/secret                              DENY
	$SYS/something                           PERMIT
* su1        8e67bb26b358e2ed20fe552ed6fb832f397a507d
	loc/jjolie                               DENY
	mega/secret                              PERMIT
	$SYS/something                           DENY
```

## Passwords

A user's password is stored as a [SHA1] hash in the back-end.

## Configure Mosquitto

```
listener 1883

auth_plugin /path/to/auth-plug.so
auth_opt_redis_host 127.0.0.1
auth_opt_redis_port 6379

# Usernames with this fnmatch(3) (a.k.a glob(3))  pattern are exempt from the
# module's ACL checking
auth_opt_superusers S*
```

## ACL

In addition to ACL checking which is possibly performed by a back-end,
there's a more "static" checking which can be configured in `mosquitto.conf`.

Note that if ACLs are being verified by the plugin, this also applies to
Will topics (_last will and testament_). Failing to correctly set up
an ACL for these, will cause a broker to silently fail with a 'not
authorized' message.

Users can be given "superuser" status (i.e. they may access any topic)
if their username matches the _glob_ specified in `auth_opt_superusers`.

In our example above, any user with a username beginning with a capital `"S"`
is exempt from ACL-checking.

## PUB/SUB

At this point you ought to be able to connect to [Mosquitto].

```
mosquitto_pub  -t '/location/n2' -m hello -u n2 -P secret
```

## PSK

If [Mosquitto] has been built with PSK support, and _auth-plug_ has been built
with `BE_PSK` defined, it supports authenticating PSK connections over TLS, as
long as Mosquitto is appropriately configured.

The way this works is that the `psk` back-end actually uses one of _auth-plug_'s
other databases (`mysql`, `sqlite`, `cdb`, etc.) to obtain the pre-shared key
from the "users" query, and it uses the same database's back-end for performing
authorization (aka ACL checks).

Consider the following `mosquitto.conf` snippet:

```
...
auth_opt_psk_database mysql
...
listener 8885
psk_hint hint1
tls_version tlsv1
use_identity_as_username true
```

TLS PSK is available on port 8885 and is activated with, say,

```
mosquitto_pub -h localhost -p 8885 -t x -m hi --psk-identity ps2 --psk 020202
```

The `use_identity_as_username` option has _auth-plug_ see the name `ps2` as the
username, and this is given to the database back-end (here: `mysql`) to look up
the password as defined for the `mysql` back-end. _auth-plug_ uses its `getuser()` query
to read the clear-text (not PKBDF2) hex key string which it returns to Mosquitto
for authentication. If authentication passes, the connection is established.

For authorization, _auth_plug_ uses the identity as the username and the topic to
perform ACL-checking as described earlier.

The following log-snippet serves as an illustration:

```
New connection from ::1 on port 8885.
|-- psk_key_get(hint1, ps1) from [mysql] finds PSK: 1
New client connected from ::1 as mosqpub/90759-tiggr.ww. (c1, k60).
Sending CONNACK to mosqpub/90759-tiggr.ww. (0)
|-- user ps1 was authenticated in back-end 0 (psk)
|--   mysql: topic_matches(x, x) == 1
|-- aclcheck(ps1, x, 2) AUTHORIZED=1 by psk
Received PUBLISH from mosqpub/90759-tiggr.ww. (d0, q0, r0, m0, 'x', ... (2 bytes))
Received DISCONNECT from mosqpub/90759-tiggr.ww.
```

## Requirements

* [hiredis], the Minimalistic C client for Redis
* OpenSSL (tested with 1.0.0c, but should work with earlier versions)
* A [Mosquitto] broker
* A [Redis] server
* MySQL
* [TinyCDB](http://www.corpit.ru/mjt/tinycdb.html) by Michael Tokarev (included in `contrib/`).

## Credits

This is based on the [mosquitto-auth-plug](https://github.com/jpmens/mosquitto-auth-plug) by [jpmens](https://github.com/jpmens) 
with ridiculously little modifications to use the SHA1 password hashing algorithm instead of the original PBKDF2.
Thanks for the great job.

* Uses `base64.[ch]` (and yes, I know OpenSSL has base64 routines, but no thanks). These files are
>  Copyright (c) 1995, 1996, 1997 Kungliga Tekniska Hgskolan (Royal Institute of Technology, Stockholm, Sweden).
* Uses [uthash][2] by Troy D. Hanson.


 [Mosquitto]: http://mosquitto.org
 [Redis]: http://redis.io
 [sha1]: hhttp://en.wikipedia.org/wiki/SHA-1
 [1]: https://exyr.org/2011/hashing-passwords/
 [hiredis]: https://github.com/redis/hiredis
 [uthash]: http://troydhanson.github.io/uthash/

## Possibly related

 * [mosquitto_pyauth](https://github.com/mbachry/mosquitto_pyauth)
 * [mosquitto-auth-plugin-http](https://github.com/hadleyrich/mosquitto-auth-plugin-http)
 * [lua_auth_plugin](https://github.com/DenkiYagi/lua_auth_plugin)

