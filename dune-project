(lang dune 3.13)
(name ocaml_neo4j_driver)
(version 0.1.0)
(license MIT)
(generate_opam_files true)

(package
 (name neodriver_packstream)
 (synopsis "PackStream binary serialization for the Neo4j Bolt protocol")
 (description
  "Pure OCaml implementation of PackStream, the binary serialization format used by Neo4j's Bolt protocol. No async dependencies.")
 (depends
  (ocaml (>= 5.0))
  (dune (>= 3.13))
  (alcotest :with-test)))

(package
 (name neodriver_core)
 (synopsis "Transport-agnostic core of the pure OCaml Neo4j driver")
 (description
  "Shared, backend-agnostic logic for the Neo4j driver: error taxonomy, configuration, addressing, hydration, client state machine and result summaries.")
 (depends
  (ocaml (>= 5.0))
  (dune (>= 3.13))
  (neodriver_packstream (= :version))
  (fmt (>= 0.9))
  (logs (>= 0.7))
  (ptime (>= 1.1))
  (mtime (>= 2.0))
  (uri (>= 4.0))
  (alcotest :with-test)))

(package
 (name neodriver_eio)
 (synopsis "Eio backend of the pure OCaml Neo4j driver")
 (description
  "Eio (direct-style, OCaml 5) backend for the Neo4j driver. Supports bolt:// connections; TLS will follow in a later phase.")
 (depends
  (ocaml (>= 5.0))
  (dune (>= 3.13))
  (neodriver_core (= :version))
  (eio (>= 1.0))
  (eio_main (>= 1.0))
  (alcotest :with-test)))

(package
 (name neodriver)
 (synopsis "Convenience module aggregating the public Neo4j driver API")
 (description
  "Aggregates the public API of neodriver_packstream, neodriver_core and neodriver_eio under a single Neodriver namespace with friendly short names.")
 (depends
  (ocaml (>= 5.0))
  (dune (>= 3.13))
  (neodriver_packstream (= :version))
  (neodriver_core (= :version))
  (neodriver_eio (= :version))
  (alcotest :with-test)))
