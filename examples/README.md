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
