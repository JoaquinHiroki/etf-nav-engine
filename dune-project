(lang dune 3.16)

(name etf_nav_engine)

(generate_opam_files true)

(source
 (github JoaquinHiroki/etf-nav-engine))

(authors "Joaquín Hiroki")

(maintainers "Joaquín Hiroki")

(package
 (name etf_nav_engine)
 (synopsis "Incremental ETF NAV engine fed by Kafka and persisted to Postgres")
 (allow_empty)
 (depends
  (ocaml
   (= 4.14.2))
  (core
   (and
    (>= v0.16)
    (< v0.17)))
  (ppx_jane
   (and
    (>= v0.16)
    (< v0.17)))
  (core_unix
   (and
    (>= v0.16)
    (< v0.17)))
  (incremental
   (and
    (>= v0.16)
    (< v0.17)))
  (kafka
   (= 0.5))
  (postgresql
   (= 5.2.0))
  (yojson
   (>= 2.0))))
