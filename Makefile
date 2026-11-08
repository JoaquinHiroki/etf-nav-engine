OCAML_VERSION := 4.14.2

EVENTS ?= 10000000
DATA := data/generated/synthetic.events

.PHONY: setup build test integration fmt up down check data replay engine clean

setup:
	test -d _opam || opam switch create . ocaml-base-compiler.$(OCAML_VERSION) --no-install --yes
	opam install . --deps-only --with-test --working-dir --yes
	opam install ocaml-lsp-server ocamlformat.0.26.2 --yes

build:
	opam exec -- dune build

test:
	opam exec -- dune test

integration: up
	opam exec -- dune build @integration

fmt:
	opam exec -- dune fmt

up:
	docker compose up -d --wait
	./scripts/init.sh

down:
	docker compose down -v

check: build up
	opam exec -- dune exec bin/check_services.exe

data:
	mkdir -p data/generated
	opam exec -- dune exec --profile release bin/generate.exe -- -output $(DATA) -events $(EVENTS)

replay: up
	opam exec -- dune exec --profile release bin/replay.exe -- -input $(DATA) $(if $(RATE),-rate $(RATE))

engine: up
	opam exec -- dune exec --profile release bin/engine.exe -- $(ARGS)

clean:
	opam exec -- dune clean
