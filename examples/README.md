# Examples

Self-contained programs demonstrating the driver, modelled on the
[python-driver-examples](https://github.com/neo4j-examples/python-driver-examples)
collection. Each program connects to Neo4j, does its thing and closes the
session. Run them from the repository root.

## Configuration

The examples read three environment variables (with the defaults shown):

- `NEO4J_URI` — default `bolt://localhost:7687`
- `NEO4J_USER` — default `neo4j`
- `NEO4J_PASSWORD` — default empty; set it to your password

```sh
export NEO4J_URI=bolt://localhost:7687
export NEO4J_USER=neo4j
export NEO4J_PASSWORD=your_password
```

## hello_world

The canonical start: create a `Greeting` node in a managed (retried) write
transaction and print the message the server returns.

```sh
dune exec examples/hello_world.exe
```

## connect

Connect (forcing the lazy connection) and print the server address, protocol
version and agent.

```sh
dune exec examples/connect.exe
```

## create

Read `examples/data/employees.csv` and create the graph with one `MERGE` query
per row: `Person`, `Company` and `Location` nodes connected by `WORKS_AT` and
`LIVES_IN` relationships. Prints the created-node counters.

```sh
dune exec examples/create.exe
```

## run_cypher

Run a read query joining people with their companies and print each returned
record. Works best after `create`.

```sh
dune exec examples/run_cypher.exe
```

## transaction

An explicit transaction: `BEGIN`, a `CREATE` inside the transaction, then
`COMMIT` (rolling back on any failure).

```sh
dune exec examples/transaction.exe
```

## managed_transaction

A managed transaction: `Session.execute` runs the unit of work with retry on
transient failures and commits it; the session's bookmarks are printed
afterwards.

```sh
dune exec examples/managed_transaction.exe
```

## transaction_config

Attach transaction options to a managed write: custom metadata (recorded by the
server with the query) and a timeout, via
`Session.execute_write ~metadata ~timeout`. The same options are accepted by
`Driver.execute_query`.

```sh
dune exec examples/transaction_config.exe
```

## read_write_transaction

The read/write split: a managed write transaction (`Session.execute_write`)
creates a `Person`, then a managed read transaction (`Session.execute_read`)
fetches its id, both in the same session.

```sh
dune exec examples/read_write_transaction.exe
```

## database_selection

Target a named database through the session config: a one-shot
`Driver.execute_query ~config` writes, then a `Driver.session ~config` reads it
back. Requires a server that offers the `examples` database (multi-database:
enterprise, or a server where it was created); otherwise the query fails with a
clear server error.

```sh
dune exec examples/database_selection.exe
```

## bookmarks

Causal consistency with bookmarks: what they are and how to chain sessions. The
program writes a `Person` node and shows the three ways the returned bookmark
is used — automatically within one session (read-your-writes), manually across
sessions (the writer's `Session.last_bookmarks` seed the reader's config), and
through a shared `Bookmark_manager` (every session sharing it is chained
without passing bookmarks around). Cleans up the demo nodes at the end.

```sh
dune exec examples/bookmarks.exe
```

## execute_query

The high-level API: `Driver.execute_query` runs a query in a managed, retried
transaction and returns an eager result (`keys` / `records` / `summary`);
`Driver.verify_connectivity` and `Driver.supports_multi_db` probe the server.

```sh
dune exec examples/execute_query.exe
```

## tls

Encryption and certificate trust. The URI scheme selects them: `bolt+s` /
`neo4j+s` verify against the system CAs, the `+ssc` variants trust any
certificate. To trust custom CA files, set `NEO4J_TLS_CA` to comma-separated
PEM paths and use a plain `bolt://` URI (the example then enables encryption and
passes `Config.Custom`). Combining explicit encryption/trust with a secure
`+s`/`+ssc` scheme is a configuration error: the scheme already carries it.

```sh
NEO4J_URI=bolt+s://localhost:7687 dune exec examples/tls.exe
NEO4J_URI=bolt://localhost:7687 NEO4J_TLS_CA=/path/to/ca.pem dune exec examples/tls.exe
```

## custom_auth

Build an authentication token for an arbitrary scheme with
`Auth_manager.custom_auth ~principal ~credentials ~realm ~parameters scheme`
and pass it as `~auth` to the driver. The defaults (basic scheme,
`NEO4J_USER`/`NEO4J_PASSWORD`) behave like basic auth; override with
`AUTH_SCHEME`, `AUTH_PRINCIPAL`, `AUTH_CREDENTIALS`, `AUTH_REALM`,
`AUTH_PARAM_KEY` and `AUTH_PARAM_VALUE`. Runs `RETURN 1`.

```sh
dune exec examples/custom_auth.exe
```

## retain_result

How to retain a result across transactions: `Neo4jResult.t` is lazy and tied to
its transaction's connection, so `Neo4jResult.list` materializes it *inside* the
read transaction; the plain values can then be used by later write transactions.
Reads every `Person` name and links each to a `Company` in its own managed write
transaction. Expects some `:Person` nodes to exist (run `create` or
`read_write_transaction` first).

```sh
dune exec examples/retain_result.exe
```

## config

Tune the driver once instead of per session: a connection-pool config
(`~pool_config`) and driver-level workspace defaults (`~workspace_config`:
retry policy, fetch size, database, impersonated user). Every session the driver
creates inherits the workspace defaults; a session's own `~config` overrides
them. Runs a simple `RETURN 1`.

```sh
dune exec examples/config.exe
```
