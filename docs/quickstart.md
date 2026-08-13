# Quickstart

This page walks you through connecting to Neo4j from OCaml and running your
first query with the `neodriver` packages.

## Prerequisites

- OCaml >= 5.2 and dune >= 3.13 (via opam or a system package manager).
- A running Neo4j instance, reachable at `bolt://localhost:7687` (the Bolt
  port), with a user that can run queries.

## Adding the driver to your project

Install the packages from opam:

```sh
opam install neodriver neodriver_eio
```

When developing against a local checkout of the driver, pin the packages
instead:

```sh
cd ocaml-neo4j-driver
opam pin add neodriver_packstream .
opam pin add neodriver_core .
opam pin add neodriver_eio .
opam pin add neodriver .
opam install neodriver neodriver_eio eio_main
```

`eio_main` provides the `Eio_main.run` entry point used by the example below.

Declare the dependency in your executable's `dune` file:

```dune
(executable
 (name hello)
 (libraries neodriver neodriver_eio eio_main))
```

## A minimal program

Save the following as `hello.ml`:

```ocaml
open Neodriver

let () =
  Eio_main.run (fun env ->
    let net = Eio.Stdenv.net env in
    let clock = Eio.Stdenv.mono_clock env in
    Eio.Switch.run (fun sw ->
      let driver =
        match
          Driver.connect ~uri:"bolt://localhost:7687"
            ~auth:(Conn.basic_auth ~credentials:"your_password" ())
            net clock sw
        with
        | Ok driver -> driver
        | Error error -> failwith (Errors.to_string error)
      in
      let session = Driver.session driver in
      (match Session.run session ~query:"RETURN 1 AS n" ~parameters:[] with
      | Ok result -> (
          match Neo4jResult.values result with
          | Ok [ [ Values.Int n ] ] -> Printf.printf "n = %Ld\n%!" n
          | _ -> ())
      | Error error -> failwith (Errors.to_string error));
      Session.close session))
```

Run it:

```sh
dune exec ./hello.exe
```

You should see `n = 1`.

## What is going on

- `Driver.connect` parses the URI and returns a **pool-backed** [driver](`Driver`):
  no server contact happens until the first query, so the error returned is the
  same whether the URI is invalid, the server is unreachable or the credentials
  are wrong. `Driver.session` returns a session that borrows a connection from
  the driver's pool on first use and returns it (with a RESET) on close.
- `Conn.basic_auth` builds the authentication token (default principal
  `neo4j`; only the `basic` scheme is supported so far).
- `Session.run` sends the query and returns a lazily streamed
  [result](`Neo4jResult`). `Neo4jResult.values` drains it into a list of
  records, each a list of [`Values.t`](`Values`); `Neo4jResult.consume`
  instead returns the [`Summary`](`Summary`) of the query.
- The `sw` switch passed to `Driver.connect` hosts the pool's connection
  attempts, so it must outlive the sessions (it does here, as the session is
  closed inside `Eio.Switch.run`).
- Routing (`neo4j://` and its `+s`/`+ssc` variants) is supported in minimal
  form: routing tables are fetched over the ROUTE message (Bolt 4.3+) or, on
  older servers, by calling the `dbms.routing.getRoutingTable` procedure, and
  addresses are selected per access mode; failed servers are deactivated
  (dropped from the routing tables until a refresh re-lists them). Server-side
  routing is enabled, and default-database sessions resolve and cache the
  server's home database (sent in RUN/BEGIN).

## Next steps

- [Usage documentation](usage.md) for sessions, transactions, value types and
  error handling.
- The generated API documentation (`dune build @doc`, then open
  `_build/default/_doc/_html/index.html`).
- Runnable [examples](../examples/) showing explicit and managed transactions.
