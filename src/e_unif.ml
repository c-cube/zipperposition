(*
Zipperposition: a functional superposition prover for prototyping
Copyright (C) 2012 Simon Cruanes

This is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
02110-1301 USA.
*)

(** incremental E-unification *)

open Types

module T = Terms
module C = Clauses
module S = FoSubst
module I = Index
module Sup = Superposition
module Utils = FoUtils

(** an equational theory *)
type e_theory = {
  axioms: C.bag;
  index: I.index;
}

let empty_theory = {
  axioms = C.empty_bag;
  index = Discrimination_tree.index;
}

let add_axiom th axiom =
  (* add to set of axioms *)
  let bag, axiom = C.add_to_bag th.axioms axiom in
  (* add to index *)
  match axiom.clits with
  | [Equation (l, r, true, _)] ->
    let index = th.index in
    let index = index#add l (axiom, [0; C.left_pos], l) in
    let index = index#add r (axiom, [0; C.right_pos], r) in
    { axioms = bag;
      index = index; }
  | _ -> failwith "a E-theory can only contain equations"

let add_axioms th axioms = List.fold_left add_axiom th axioms
  
let pp_theory formatter theory =
  Format.fprintf formatter "theory: @[<h>%a@]" C.pp_bag theory.axioms

(** a state of the E-unification resolution algorithm *)
type state = (foterm * foterm) list * substitution

(** Abstract type for a lazy set of E-unifiers, It is associated with
    a E-unification problem. *)
type e_unifiers = {
  left: foterm;
  right: foterm;
  ord: ordering;
  mutable substs: substitution list;
  queue: state Queue.t;
  mutable var_num: int;
  theory: e_theory;
}

(** E-unify two terms yields a lazy set of E-unifiers *)
let e_unify ~ord th t1 t2 =
  let queue = Queue.create ()
  and substs = []
  and max_var = th.axioms.C.bag_maxvar  in
  Queue.add ([t1, t2], S.id_subst) queue;
  { left=t1; right=t2; ord=ord; substs = substs;
    queue = queue; theory = th; var_num=max_var+1;}

(** status of a set of E-unifiers *)
type e_status =
  | EUnknown of substitution list       (** substitutions already computed *)
  | ESat of substitution list           (** satisfiable, with the given set of unifiers *)
  | EUnsat                              (** no unifier *)

(** get the current state *)
let e_state unifiers =
  if Queue.is_empty unifiers.queue
    then if unifiers.substs = []
      then EUnsat
      else ESat unifiers.substs
    else EUnknown unifiers.substs

(** pretty printing of the problem *)
let pp_unifiers formatter unifiers =
  Format.fprintf formatter "E-unification of %a and %a modulo %a"
    !T.pp_term#pp unifiers.left !T.pp_term#pp unifiers.right
    pp_theory unifiers.theory


(** pretty print a pair of terms *)
let pp_pair formatter (a,b) =
  Format.fprintf formatter "%a ?= %a" !T.pp_term#pp a !T.pp_term#pp b

(** pretty printing of a state *)
let pp_state formatter (pairs, subst) =
  Format.fprintf formatter "state: @[<h>%a@] with %a"
    (Utils.pp_list pp_pair) pairs S.pp_substitution subst

(* ----------------------------------------------------------------------
 * computation of E-unifiers
 * ---------------------------------------------------------------------- *)

let default_steps = ref 5     (** default number of steps to do *)

(** check whether those two terms are top-unifiable *)
let rec top_unifiable t1 t2 =
  match t1.term, t2.term with
  | Var _, _ | _, Var _ -> true
  | Leaf s1, Leaf s2 -> s1 = s2
  | Node l1, Node l2 ->
    (try List.for_all2 top_unifiable l1 l2
    with Invalid_argument _ -> false)
  | _, _ -> false

(** perform as many decomposition steps as possible on the two top-unifiable terms *)
let decompose t1 t2 =
  assert (top_unifiable t1 t2);
  (* recursively compute the multiset of pairs generated by top-unification *)
  let rec recurse acc t1 t2 =
    match t1.term, t2.term with
    | Var _, _ | _, Var _ -> (t1,t2)::acc
    | Leaf s1, Leaf s2 -> assert (s1 = s2); acc
    | Node l1, Node l2 ->
      assert (List.length l1 = List.length l2); fold acc l1 l2
    | _, _ -> failwith "not top-unifiable terms cannot be decomposed"
  (* fold on two lists *)
  and fold acc l1 l2 =
    match l1, l2 with
    | [], [] -> acc
    | t1::l1', t2::l2' ->
      let acc = recurse acc t1 t2 in
      fold acc l1' l2'
    | _ -> assert false
  in
  recurse [] t1 t2

(** Check whether a list of pairs is syntactically unifiable *) 
let rec syntactically_unifiable pairs subst =
  match pairs with
  | [] -> Some subst (* success *)
  | (a,b)::pairs' ->
    begin
      let a = S.apply_subst subst a
      and b = S.apply_subst subst b in
      match a.term, b.term with
      | _ when T.eq_foterm a b ->
        syntactically_unifiable pairs' subst (* trivial elimination *)
      | Var _, _ ->
        if T.member_term a b then None (* occur check *)
        else
          let subst = S.build_subst a b subst in
          syntactically_unifiable pairs' subst
      | _, Var _ ->
        if T.member_term b a then None (* occur check *)
        else
          let subst = S.build_subst b a subst in
          syntactically_unifiable pairs' subst
      | Leaf s, Leaf s' -> (assert (s <> s'); None) (* trivial conflict *)
      | _ ->
        if top_unifiable a b
          then
            let subpairs = decompose a b in
            match syntactically_unifiable subpairs subst with
            | None -> None
            | Some subst' ->
              syntactically_unifiable pairs' subst'  (* success in unifying those two terms *)
          else None  (* conflict *)
    end

(** choose a pair to perform relaxed paramodulation on, and or
    raise Not_found *)
let do_paramod unifiers pairs subst =
  let th = unifiers.theory
  and ord = unifiers.ord in
  (* recurse through pairs, looking for one pair to solve using
     paramodulation. pre is the reversed list of previous pairs *)
  let rec recurse pre pairs =
    match pairs with
    | [] -> raise Not_found  (* found no suitable pair *)
    | ((a,b) as pair)::pairs' ->
      match paramodulate pair with
      | [] -> recurse (pair::pre) pairs'  (* pair not suitable for paramodulation *)
      | new_pairs ->
        pair, new_pairs, List.rev_append pre pairs' (* pair can be paramodulated *)
  (* find an unsolvable pair, and returns it and the list without it *)
  and find_unsolvable pre pairs =
    match pairs with
    | [] -> raise Not_found
    | ((a,b) as pair)::pairs' ->
      if not (top_unifiable a b)
        then pair, List.rev_append pre pairs'
        else find_unsolvable (pair::pre) pairs'
  (* given a pair, generate all relaxed paramodulation witness pairs from it *)
  and paramodulate (a,b) =
    List.rev_append (try_paramodulate a b) (try_paramodulate b a)
  (* try to paramodulate the first term *)
  and try_paramodulate a b =
    Sup.all_positions [] a
      (fun sub_t pos ->
        if T.is_var sub_t || not (T.db_closed sub_t) then [] else
        (* try to paramodulate on sub_t which is at position pos *)
        th.index#retrieve_unifiables sub_t []
          (fun acc l set ->
            (* l and sub_t should be top_unifiable *)
            assert (top_unifiable sub_t l);
            (* paramodulate with all clauses in set *)
            I.ClauseSet.fold
              (fun (equation, pos', _) acc ->
                match pos' with
                | [0; side] ->
                  (* rename equation with fresh variables *)
                  let equation, new_var_num = C.fresh_clause ~ord unifiers.var_num equation in
                  unifiers.var_num <- new_var_num;
                  (* (renamed) equation is l=r *)
                  let l = C.get_pos equation pos'
                  and r = C.get_pos equation [0; C.opposite_pos side] in
                  (* new_a is a[pos <- r] *)
                  let new_a = T.replace_pos a pos r in 
                  ((decompose sub_t l) @ [new_a, b]) :: acc
                | _ -> assert false
              ) set acc
          )
      )
  in
  (* pair on which paramodulation is done, new sets of pairs from paramodulation,
     remaining pairs *)
  let pair, new_pairs_set, other_pairs =
    try
      let pair, other_pairs = find_unsolvable [] pairs in
      pair, paramodulate pair, other_pairs
    with Not_found -> recurse [] pairs
  in
  match new_pairs_set with
  | [] -> raise Not_found  (* unsolvable pair with no paramodulation inference,
                              this branch is doomed to fail *)
  | _ ->
    (* for each set of pairs obtained by paramodulation, add them at the end
       of the list of other_pairs, to create a new problem *)
    List.map (fun new_pairs -> other_pairs @ new_pairs, subst) new_pairs_set

(** simplify the list of pairs by removing trivial pairs *)
let rec simplify pairs =
  match pairs with
  | [] -> []
  | (a,b)::pairs' when T.eq_foterm a b -> simplify pairs'  (* eliminate tautology *)
  | pair::pairs' -> pair::(simplify pairs')

(** make some progress in the computation of E-unifiers *)
let e_compute ?steps unifiers =
  let steps = match steps with
  | None -> !default_steps
  | Some steps -> steps in
  (* try to solve one problem *)
  let rec do_step (pairs, subst) = 
    (* first, try to syntactically solve the the problem *)
    let new_subst = syntactically_unifiable pairs subst in
    (* generate other problems by paramodulation *)
    begin
      try
        (* remove trivial pairs *)
        let pairs = simplify pairs in
        (* do all possible paramodulations on some pair *)
        let new_problems = do_paramod unifiers pairs subst in
        List.iter (fun pb -> Utils.debug 3
          (lazy (Utils.sprintf "  @[<h>... add problem %a to E-unify %a=%a@]" pp_state pb
                 !T.pp_term#pp unifiers.left !T.pp_term#pp unifiers.right))) new_problems;
        (* add new problems to the queue *)
        List.iter (fun pb -> Queue.add pb unifiers.queue) new_problems
      with Not_found -> ()  (* no new problems *)
    end;
    new_subst
  (* solve [steps] problems *)
  and several_steps steps new_substs =
    if (not (Queue.is_empty unifiers.queue)) && steps > 0
      then
        let problem = Queue.take unifiers.queue in
        Utils.debug 3 (lazy (Utils.sprintf "try to solve @[<h>%a@] " pp_state problem));
        (match do_step problem with
        | None -> ()
        | Some subst ->
          (* an answer has been found! *)
          new_substs := subst :: !new_substs;
          unifiers.substs <- subst :: unifiers.substs);
        several_steps (steps-1) new_substs
      else e_state unifiers, !new_substs
  (* call several_steps *)
  in
  let new_substs = ref [] in
  several_steps steps new_substs

