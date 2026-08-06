(lang dune 3.13)
(name ocaml_neo4j_driver)
(version 0.1.0)
(license MIT)
(authors "Tomasz Barański <tomasz.baranski@posteo.net>")
(maintainers "Tomasz Barański <tomasz.baranski@posteo.net>")
(homepage "https://github.com/tomob/ocaml-neo4j-driver")
(bug_reports "https://github.com/tomob/ocaml-neo4j-driver/issues")
(source (github tomob/ocaml-neo4j-driver))
(generate_opam_files true)

(package
 (name neodriver_packstream)
 (synopsis "PackStream binary serialization for the Neo4j Bolt protocol")
 (description
  "Pure OCaml implementation of PackStream, the binary serialization format used by Neo4j's Bolt protocol. No async dependencies.")
 (depends
  (ocaml (>= 5.2.0))
  (dune (>= 3.13))
  (alcotest :with-test)))

(package
 (name neodriver_core)
 (synopsis "Transport-agnostic core of the pure OCaml Neo4j driver")
 (description
  "Shared, backend-agnostic logic for the Neo4j driver: error taxonomy, configuration, addressing, hydration, client state machine and result summaries.")
 (depends
  (ocaml (>= 5.2.0))
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
   "Eio (direct-style, OCaml 5) backend for the Neo4j driver. Supports bolt://, bolt+s:// and bolt+ssc:// connections.")
  (depends
   (ocaml (>= 5.2.0))
   (dune (>= 3.13))
   (neodriver_core (= :version))
   (neodriver_packstream (= :version))
   (eio (>= 1.0))
   (eio_main (>= 1.0))
   (ipaddr (>= 5.5))
   (tls (>= 2.0))
   (tls-eio (>= 2.0))
   (x509 (>= 1.0))
   (ca-certs (>= 1.0))
   (domain-name (>= 0.4))
   (mirage-crypto-rng (>= 1.2))
   (mtime (>= 2.0))
   (alcotest :with-test)))

(package
 (name neodriver)
 (synopsis "Convenience module aggregating the public Neo4j driver API")
 (description
  "Aggregates the public API of neodriver_packstream, neodriver_core and neodriver_eio under a single Neodriver namespace with friendly short names.")
 (depends
  (ocaml (>= 5.2.0))
  (dune (>= 3.13))
  (neodriver_packstream (= :version))
  (neodriver_core (= :version))
  (neodriver_eio (= :version))
  (alcotest :with-test)))
