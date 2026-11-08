OCAML_VERSION := 4.14.2

.PHONY: setup build test fmt up down check clean

setup:
	test -d _opam || opam switch create . ocaml-base-compiler.$(OCAML_VERSION) --no-install --yes
	opam install . --deps-only --with-test --yes
	opam install ocaml-lsp-server ocamlformat.0.26.2 --yes

build:
	opam exec -- dune build

test:
	opam exec -- dune test

fmt:
	opam exec -- dune fmt

up:
	docker compose up -d --wait

down:
	docker compose down -v

check: build up
	opam exec -- dune exec bin/check_services.exe

clean:
	opam exec -- dune clean
