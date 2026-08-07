# TestKit backend image: builds the pure OCaml Neo4j driver and runs the
# testkit backend (a JSON-over-TCP server) inside a container, so its network
# topology matches the Python harness (the backend is isolated from Neo4j).
FROM ocaml/opam:debian-12-ocaml-5.2

WORKDIR /workspace
COPY --chown=opam:opam . .

RUN sudo chown -R opam:opam /workspace \
  && opam install . --deps-only -y \
  && opam install -y yojson
RUN opam exec -- dune build testkitbackend/testkitbackend.exe

EXPOSE 9876
ENTRYPOINT ["opam", "exec", "--", "/workspace/_build/default/testkitbackend/testkitbackend.exe"]
