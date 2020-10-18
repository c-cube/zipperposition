
(* This file is free software, part of Zipperposition. See file "license" for more details. *)

(** {1 Booleans} *)
open Libzipperposition
open Logtk

val enabled : bool ref

val k_solve_formulas : bool Flex_state.key 

module type S = sig
  module Env : Env.S
  module C : module type of Env.C with type t = Env.C.t

  (** {6 Registration} *)

  val setup : unit -> unit
  (** Register rules in the environment *)

  val update_form_counter: action:[< `Decrease | `Increase ] -> C.t -> unit
  val solve_bool_formulas: C.t -> C.t CCList.t option
  (* Find resolvable boolean literals and resolve them before CNF starts *)
end

module Make(E : Env.S) : S with module Env = E

val extension : Extensions.t
