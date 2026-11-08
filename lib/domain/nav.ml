open! Core

let nav ~cash ~positions_value ~shares_outstanding =
  (cash +. positions_value) /. shares_outstanding
;;

let premium ~etf_price ~nav = (etf_price -. nav) /. nav
