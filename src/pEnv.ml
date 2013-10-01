
(*
Zipperposition: a functional superposition prover for prototyping
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

(** {1 Preprocessing Env} *)

open Logtk

module F = Formula
module PF = PFormula

(** {2 Transformations} *)

type operation_result =
  | SimplifyInto of PFormula.t  (** replace by formula *)
  | Remove                      (** remove formula *)
  | Esa of PFormula.t list      (** replace by list of formulas *)
  | Add of PFormula.t list      (** add given formulas *)
  | AddOps of operation list    (** New operations to perform! *)
  | DoNothing                   (** sic. *)
and operation = PF.Set.t -> PF.t -> operation_result

exception ExitOperation
exception Restart

(* fixpoint of transformations *)
let fix ops set =
  let ops = ref ops in
  let q = Queue.create () in
  let add_forms l = List.iter (fun f -> Queue.push f q) l in
  PF.Set.iter (fun f -> Queue.push f q) set;
  (* initial queue to process *)
  let ans = ref PF.Set.empty in
  while not (Queue.is_empty q) do
    let pf = Queue.pop q in
    (* memoized simplifications *)
    let pf = PF.follow_simpl pf in
    try
      List.iter
        (fun tr -> match tr !ans pf with
          | DoNothing -> ()
          | Remove ->
            raise ExitOperation  (* remove formula *)
          | Esa [pf'] when PF.eq_noproof pf pf' -> ()
          | Esa l ->
            (* get rid of [f], but process [l] instead *)
            add_forms l;
            raise ExitOperation
          | Add l ->
            (* continue processing [pf], but also [l] *)
            add_forms (pf :: l);
            raise Restart
          | AddOps l ->
            (* add those operations to the list of ops to perform, and keep [pf] *)
            ops := List.rev_append l !ops;
            add_forms [pf];
            raise Restart
          | SimplifyInto f' when F.ac_eq pf.PF.form f'.PF.form ->
            () (* not really simplified *)
          | SimplifyInto f' ->
            (* ignore [f], process [f'] instead, and remember the
                simplification step *)
            PF.simpl_to ~from:pf ~into:f';
            Queue.push f' q;
            raise ExitOperation)
        !ops;
      (* terminal node, keep it *)
      ans := PF.Set.add pf !ans
    with ExitOperation -> ()
    | Restart ->
      (* process again all formulas *)
      PF.Set.iter (fun f -> Queue.push f q) !ans;
      ans := PF.Set.empty
  done;
  !ans

(* remove trivial formulas *)
let remove_trivial set pf =
  if F.is_trivial pf.PF.form
    then Remove
    else DoNothing

(* reduce formulas to CNF *)
let cnf ~ctx =
  fun set pf ->
    Util.debug 3 "reduce %a to CNF..." PF.pp pf;
    (* reduce to CNF this formula *)
    let clauses = Cnf.cnf_of ~ctx pf.PF.form in
    (* now build "proper" clauses, with proof and all *)
    match clauses with
    | [[f]] when F.eq f pf.PF.form -> DoNothing
    | _ ->
      let proof f' = Proof.mk_f_step ~esa:true f' ~rule:"cnf" [pf.PF.proof] in
      let clauses =
        List.map
          (fun c ->
            (* clause represented as formula *)
            let f = F.mk_or c in
            PF.create f (proof f))
          clauses
      in
      Esa clauses

let meta_prover ~meta =
  fun set pf ->
    (* scan formula *)
    let res  = MetaProverState.scan_formula meta pf in
    (* exploit result, adding lemmas to the set *)
    let lemmas = Util.list_fmap
      (function
        | MetaProverState.Deduced (pf', _) -> Some pf'
        | MetaProverState.Theory _
        | MetaProverState.Expert _ -> None)
      res
    in
    if lemmas = []
      then DoNothing
      else Add lemmas

let rw_term ?(rule="rw") trs =
  fun set pf ->
    let f = pf.PF.form in
    let f' = Formula.map (fun t -> Rewriting.TRS.rewrite trs t) f in
    if F.eq f f'
      then DoNothing
      else
        let proof = Proof.mk_f_step f' ~rule [pf.PF.proof] in
        let pf' = PF.create f' proof in
        SimplifyInto pf'

let rw_form ?(rule="rw") frs =
  fun set pf ->
    let f = pf.PF.form in
    let f' = Rewriting.FormRW.rewrite frs f in
    if F.eq f f'
      then DoNothing
      else
        let proof = Proof.mk_f_step f' ~rule [pf.PF.proof] in
        let pf' = PF.create f' proof in
        SimplifyInto pf'

let fmap_term ~rule func =
  fun set pf ->
    let f = pf.PF.form in
    let f' = Formula.map func f in
    if F.eq f f'
      then DoNothing
      else
        let proof = Proof.mk_f_step f' ~rule [pf.PF.proof] in
        let pf' = PF.create f' proof in
        SimplifyInto pf'

(* expand definitions *)
let expand_def set pf =
  (* detect definitions in [pf] and the current set *)
  let forms = Sequence.map PF.get_form (PF.Set.to_seq set) in
  let transforms =
    FormulaShape.detect_list [pf.PF.form] @
    FormulaShape.detect forms
  in
  (* make new operations on the set of formulas *)
  let ops = Util.list_fmap
    (function
      | Transform.RwForm frs -> Some (rw_form ~rule:"expand_pred_def" frs)
      | Transform.RwTerm trs -> Some (rw_term ~rule:"expand_term_def" trs)
      | Transform.Tr _ -> None)
    transforms
  in
  (* add those definitions *)
  if ops = []
    then DoNothing
    else AddOps ops

(** {2 Preprocessing} *)

type t = {
  mutable axioms : PF.Set.t;
  mutable ops : (int * (PF.Set.t -> operation)) list;  (* int: priority *)
  mutable constrs : Precedence.constr list;
  mutable constr_rules : (PF.Set.t -> Precedence.constr) list;
  meta : MetaProverState.t option;
  params : Params.t;
}

let copy penv = { penv with ops = penv.ops; }

let get_params ~penv = penv.params

let add_axiom ~penv ax =
  penv.axioms <- PF.Set.add ax penv.axioms

let add_axioms ~penv axioms =
  Sequence.iter (add_axiom ~penv) axioms

let add_operation ~penv ~prio op =
  penv.ops <- (prio, (fun _ -> op)) :: penv.ops

let add_operation_rule ~penv ~prio rule =
  penv.ops <- (prio, rule) :: penv.ops

let create ?meta params =
  let penv = {
    axioms = PF.Set.empty;
    ops = [];
    constrs = [];
    constr_rules = [];
    meta;
    params;
  } in
  (* may add the [meta] operation *)
  begin match meta with
  | None -> ()
  | Some m -> add_operation ~penv ~prio:2 (meta_prover ~meta:m);
  end;
  penv

let process ~penv set =
  let compare (p1, _) (p2, _) = p1 - p2 in
  let rules = List.map snd (List.sort compare penv.ops) in
  let ops = List.map (fun rule -> rule set) rules in
  fix ops set

let add_constr ~penv c =
  penv.constrs <- c::penv.constrs

let add_constrs ~penv l =
  List.iter (add_constr ~penv) l

let add_constr_rule ~penv r =
  penv.constr_rules <- r :: penv.constr_rules

let mk_precedence ~penv set =
  let constrs = penv.constrs @ List.map (fun rule -> rule set) penv.constr_rules in
  let forms = Sequence.map PF.get_form (PF.Set.to_seq set) in
  let signature = F.signature_seq forms in
  let symbols = Signature.to_symbols signature in
  Precedence.create ~complete:false constrs symbols
