
(*
Copyright (c) 2013, Simon Cruanes
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this
list of conditions and the following disclaimer.  Redistributions in binary
form must reproduce the above copyright notice, this list of conditions and the
following disclaimer in the documentation and/or other materials provided with
the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*)

(** {1 Encoding of clauses} *)

open Logtk

module T = ScopedTerm
module FOT = FOTerm
module HOT = HOTerm

(** {2 Base definitions} *)

type 'a lit =
  | Eq of 'a * 'a * bool
  | Prop of 'a * bool
  | Bool of bool

let fmap_lit f = function
  | Eq (a,b, truth) -> Eq (f a, f b, truth)
  | Prop (a, truth) -> Prop (f a, truth)
  | Bool b -> Bool b

let opt_seq_lit = function
  | Eq (Some a, Some b, truth) -> Some (Eq (a, b, truth))
  | Prop (Some a, truth) -> Some (Prop (a, truth))
  | Eq _ | Prop _ -> None
  | Bool b -> Some (Bool b)

type 'a clause = 'a lit list

let fmap_clause f c = List.map (fmap_lit f) c

type foterm = FOTerm.t
type hoterm = HOT.t

type foclause = foterm clause
type hoclause = hoterm clause

(* convert a list of formulas into a clause *)
let foclause_of_clause l =
  let module F = Formula.FO in
  Util.debug 5 "foclause_of_clause %a" (Util.pp_list F.pp) l;
  let term_of_form f = match F.view f with
    | F.Atom t -> t
    | _ -> raise (Invalid_argument (Util.sprintf "expected term, got formula %a" F.pp f))
  in
  List.map
    (fun f -> match F.view f with
      | F.Not f' -> Prop (term_of_form f', false)
      | F.Eq (a,b) -> Eq (a, b, true)
      | F.Neq (a,b) -> Eq (a, b, false)
      | F.True -> Bool true
      | F.False -> Bool false
      | _ -> Prop (term_of_form f, true)
    ) l

let pp_clause pp_t buf c =
  Util.pp_list ~sep:" | "
    (fun buf lit -> match lit with
      | Eq (a, b, true) -> Printf.bprintf buf "%a = %a" pp_t a pp_t b
      | Eq (a, b, false) -> Printf.bprintf buf "%a != %a" pp_t a pp_t b
      | Prop (a, true) -> pp_t buf a
      | Prop (a, false) -> Printf.bprintf buf "~ %a" pp_t a
      | Bool b -> Printf.bprintf buf "%B" b
    ) buf c

(** {6 Encoding abstraction} *)

class type ['a, 'b] t = object
  method encode : 'a -> 'b
  method decode : 'b -> 'a option
end

let id = object
  method encode x = x
  method decode x = Some x
end

let compose a b = object (self)
  method encode x = b#encode (a#encode x)
  method decode y =
    match b#decode y with
    | Some x -> a#decode x
    | None -> None
end

let (>>>) a b = compose a b

(** {6 Currying} *)

let currying = object
  method encode c = fmap_clause HOT.curry c
  method decode c =
    fmap_clause HOT.uncurry c
      |> List.map opt_seq_lit
      |> Monad.Opt.seq
end

(** {6 Rigidifying variables}
This step replaces free variables by rigid variables. It is needed for
pattern detection to work correctly.

At this step two encodings are available, one that actually rigidifies
free variables (for encoding the problem's clauses) and one
that should only be used for the theory declarations (where free vars
are already rigid) *)

module RigidTerm = struct
  type t = HOT.t

  let eq = HOT.eq
  let hash = HOT.hash
  let cmp = HOT.cmp
  let pp = HOT.pp
  let to_string = HOT.to_string
  let fmt = HOT.fmt

  let __magic t = t
end

let rigidifying = object
  method encode c = fmap_clause HOT.rigidify c
  method decode c = Some (fmap_clause HOT.unrigidify c)
end

let already_rigid = object
  method encode c = c
  method decode c = Some c
end

(** {6 Clause encoding}

Encode the whole clause into a {!Reasoner.Property.t}, ie a higher-order term
that represents a meta-level property. *)

module EncodedClause = struct
  type t = Reasoner.term

  let eq = HOT.eq
  let hash = HOT.hash
  let cmp = HOT.cmp
  let pp = HOT.pp
  let to_string = HOT.to_string
  let fmt = HOT.fmt

  let __magic t = t
end

(** Encode/Decode clauses into terms:
    terms are already curried and rigidified, so we only need to replace
    connectives by their multiset versions. *)

let __ty_or = Type.(TPTP.o <=. multiset TPTP.o)
let __ty_eq = Type.(forall [var 0] (TPTP.o <=. multiset (var 0)))
let __ty_not = Type.(TPTP.o <=. TPTP.o)

let __or_conn =
  HOT.const ~ty:__ty_or Symbol.Base.or_
let __and__conn =
  HOT.const ~ty:__ty_or Symbol.Base.and_
let __xor_conn =
  HOT.const ~ty:__ty_or Symbol.Base.xor
let __equiv_conn =
  HOT.const ~ty:__ty_or Symbol.Base.equiv
let __eq_conn =
  HOT.const ~ty:__ty_eq Symbol.Base.eq
let __neq_conn =
  HOT.const ~ty:__ty_eq Symbol.Base.neq
let __not_conn =
  HOT.const ~ty:__ty_not Symbol.Base.not_

let signature = Signature.of_list
  [ Symbol.Base.or_, __ty_or
  ; Symbol.Base.and_, __ty_or
  ; Symbol.Base.xor, __ty_or
  ; Symbol.Base.equiv, __ty_or
  ; Symbol.Base.eq, __ty_eq
  ; Symbol.Base.neq, __ty_eq
  ; Symbol.Base.not_, __ty_not
  ]

let __encode_lit = function
  | Eq (a, b, truth) ->
      let ty = HOT.ty a in
      if truth
        then HOT.at (HOT.tyat __eq_conn ty) (HOT.multiset ~ty [a; b])
        else HOT.at (HOT.tyat __neq_conn ty) (HOT.multiset ~ty [a; b])
  | Prop (p, true) -> p
  | Prop (p, false) -> HOT.at __not_conn p
  | Bool true -> HOT.TPTP.true_
  | Bool false -> HOT.TPTP.false_

let __decode_lit t = match HOT.open_at t with
  | hd, _, [r] when HOT.eq hd __not_conn -> Prop (r, false)
  | hd, _, [r] ->
      begin match HOT.view r with
      | HOT.Multiset [a;b] when HOT.eq hd __eq_conn -> Eq (a, b, true)
      | HOT.Multiset [a;b] when HOT.eq hd __neq_conn -> Eq (a, b, false)
      | _ -> Prop (t, true)
      end
  | _ -> Prop (t, true)

let clause_prop = object
  method encode c =
    let lits = List.map __encode_lit c in
    HOT.multiset ~ty:Type.TPTP.o lits

  method decode c =
    match HOT.view c with
    | HOT.Multiset l -> Some (List.map __decode_lit l)
    | _ -> None
end

