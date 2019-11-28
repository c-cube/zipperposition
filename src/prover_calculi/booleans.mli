
(* This file is free software, part of Zipperposition. See file "license" for more details. *)

(** {1 Booleans} *)
open Libzipperposition

val _quant_rename : bool ref

module type S = sig
  module Env : Env.S
  module C : module type of Env.C

  (** {6 Registration} *)

  val setup : unit -> unit
  (** Register rules in the environment *)


end

module Make(E : Env.S) : S with module Env = E

val extension : Extensions.t

val name_quantifiers : Logtk.TypeInference.typed_statement CCVector.ro_vector -> Logtk.TypeInference.typed_statement CCVector.ro_vector

val preprocess_booleans : Logtk.TypeInference.typed_statement CCVector.ro_vector -> Logtk.TypeInference.typed_statement CCVector.ro_vector

val preprocess_cnf_booleans : Logtk.Statement.clause_t CCVector.ro_vector -> Logtk.Statement.clause_t CCVector.ro_vector