
(* This file is free software, part of Libzipperposition. See file "license" for more details. *)

(** {1 Utils related to TPTP} *)

open Libzipperposition

module A = Ast_tptp

type 'a or_error = [`Error of string | `Ok of 'a]
type untyped = STerm.t
type typed = TypedSTerm.t

exception Error of string

(** {2 Printing/Parsing} *)

val find_file : string -> string -> string option
(** [find_file name dir] looks for a file with the given [name],
    recursively, in [dir], or in its parent dir recursively.
    It also looks in the "TPTP" environment variable. *)

val parse_lexbuf :
  ?names:A.name list ->
  Lexing.lexbuf ->
  untyped A.t Sequence.t or_error
(** Given a lexbuf, try to parse its content into a sequence of untyped
    declarations *)

val parse_file :
  recursive:bool -> string ->
  untyped A.t Sequence.t or_error
(** Parsing a TPTP file is here presented with a [recursive] option
    that, if true, will make "include" directives to be recursively
    parsed. It uses {!find_file} for included files.
    @return an error-wrapped sequence of declarations. *)

(* TODO: a function that takes a TPTP file, and returns the list of
        files that it depends on (recursive includes) *)

(** Printing is simpler, because it does not involve includes. *)

val print_into : 't CCFormat.printer -> 't A.t Sequence.t CCFormat.printer
val print_into_file : 't CCFormat.printer -> string -> 't A.t Sequence.t -> unit

val has_includes : _ A.t Sequence.t -> bool
(** Check whether some include declaration can be found in the sequence *)

(** {2 Bridge to UntypedAST} *)

val to_ast : untyped A.t -> UntypedAST.statement
(** @raise Error if there are remaining includes *)

val of_ast : UntypedAST.statement -> untyped A.t
(** @raise Error if the AST contains Data *)
