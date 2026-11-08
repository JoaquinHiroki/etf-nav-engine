open! Core

type t = Time_ns.Stable.Alternate_sexp.V1.t [@@deriving bin_io, compare, sexp]

let year_2100_ns = 4_102_444_800_000_000_000

let quickcheck_generator =
  Quickcheck.Generator.map (Int.gen_incl 0 year_2100_ns) ~f:Time_ns.of_int_ns_since_epoch
;;

let quickcheck_observer =
  Quickcheck.Observer.unmap Int.quickcheck_observer ~f:Time_ns.to_int_ns_since_epoch
;;

let quickcheck_shrinker : t Quickcheck.Shrinker.t = Quickcheck.Shrinker.empty ()
