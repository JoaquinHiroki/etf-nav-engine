open! Core

let reduce xs ~empty ~combine =
  let rec range lo hi =
    if hi - lo = 1
    then xs.(lo)
    else (
      let mid = lo + ((hi - lo) / 2) in
      combine (range lo mid) (range mid hi))
  in
  if Array.is_empty xs then empty else range 0 (Array.length xs)
;;

let sum xs = reduce xs ~empty:0. ~combine:( +. )
