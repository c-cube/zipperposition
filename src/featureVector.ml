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

(** Feature Vector indexing (see Schulz 2004) for efficient forward
    and backward subsumption *)

open Types
open Symbols

module T = Terms
module C = Clauses
module Utils = FoUtils

(* ----------------------------------------------------------------------
 * features
 * ---------------------------------------------------------------------- *)

(** a vector of feature *)
type feature_vector = int list

(** a function that computes a feature *)
type feature = hclause -> int

let compute_fv features hc =
  List.map (fun feat -> feat hc) features

let feat_size_plus hc =
  let cnt = ref 0 in
  Array.iter (fun (Equation (_,_,sign,_)) -> if sign then incr cnt) hc.hclits;
  !cnt

let feat_size_minus hc =
  let cnt = ref 0 in
  Array.iter (fun (Equation (_,_,sign,_)) -> if not sign then incr cnt) hc.hclits;
  !cnt

(* sum of depths at which symbols occur. Eg f(a, g(b)) will yield 4 (f
   is at depth 0) *)
let sum_of_depths_lit lit =
  let rec sum depth acc t = match t.term with
  | Var _ -> acc
  | Node (s, l) -> List.fold_left (sum (depth+1)) (acc+depth) l
  in
  match lit with
  | Equation (l, r, _, _) -> sum 0 (sum 0 0 l) r

let sum_of_depths hc =
  Array.fold_left (fun acc lit -> acc + sum_of_depths_lit lit) 0 hc.hclits

(* number of occurrences of symbol in literal *)
let count_symb_lit symb lit =
  let cnt = ref 0 in
  let rec count_symb_term t = match t.term with
  | Var _ -> ()
  | Node (s, l) ->
    (if s = symb then incr cnt);
    List.iter count_symb_term l
  in
  match lit with
  | Equation (l, r, _, _) ->
    count_symb_term l; count_symb_term r; !cnt

let count_symb_plus symb hc =
  let cnt = ref 0 in
  Array.iter
    (fun lit -> if C.pos_lit lit
      then cnt := !cnt + count_symb_lit symb lit) hc.hclits;
  !cnt

let count_symb_minus symb hc =
  let cnt = ref 0 in
  Array.iter
    (fun lit -> if C.neg_lit lit
      then cnt := !cnt + count_symb_lit symb lit) hc.hclits;
  !cnt

(* max depth of the symbol in the literal, or -1 *)
let max_depth_lit symb lit =
  let rec max_depth_term t depth =
    match t.term with
    | Var _ -> -1
    | Node (s, l) ->
      let depth = if s = symb then depth else -1 in
      List.fold_left
        (fun maxdepth subterm -> max maxdepth (max_depth_term subterm (depth+1)))
        depth l
  in
  match lit with
  | Equation (l, r, _, _) -> max (max_depth_term l 0) (max_depth_term r 0)

let max_depth_plus symb hc =
  let depth = ref 0 in
  Array.iter
    (fun lit -> if C.pos_lit lit
      then depth := max !depth (max_depth_lit symb lit)) hc.hclits;
  !depth

let max_depth_minus symb hc =
  let depth = ref 0 in
  Array.iter
    (fun lit -> if C.neg_lit lit
      then depth := max !depth (max_depth_lit symb lit)) hc.hclits;
  !depth

(* ----------------------------------------------------------------------
 * FV index
 * ---------------------------------------------------------------------- *)

type trie =
  | Node of trie Ptmap.t  (** map feature -> trie *)
  | Leaf of C.CSet.t      (** leaf with a set of hcs *)

let empty_trie n = match n with
  | Node m when Ptmap.is_empty m -> true
  | Leaf set when C.CSet.is_empty set -> true
  | _ -> false

(** get/add/remove the leaf for the given list of ints. The
    continuation k takes the leaf, and returns a leaf
    that replaces the old leaf. 
    This function returns the new trie. *)
let goto_leaf trie t k =
  (* the root of the tree *)
  let root = trie in
  (* function to go to the given leaf, building it if needed *)
  let rec goto trie t rebuild =
    match trie, t with
    | (Leaf set) as leaf, [] -> (* found leaf *)
      (match k set with
      | new_leaf when leaf == new_leaf -> root  (* no change, return same tree *)
      | new_leaf -> rebuild new_leaf)           (* replace by new leaf *)
    | Node m, c::t' ->
      (try  (* insert in subtrie *)
        let subtrie = Ptmap.find c m in
        let rebuild' subtrie = match subtrie with
          | _ when empty_trie subtrie -> rebuild (Node (Ptmap.remove c m))
          | _ -> rebuild (Node (Ptmap.add c subtrie m))
        in
        goto subtrie t' rebuild'
      with Not_found -> (* no subtrie found *)
        let subtrie = if t' = [] then Leaf C.CSet.empty else Node Ptmap.empty
        and rebuild' subtrie = match subtrie with
          | _ when empty_trie subtrie -> rebuild (Node (Ptmap.remove c m))
          | _ -> rebuild (Node (Ptmap.add c subtrie m))
        in
        goto subtrie t' rebuild')
    | Node _, [] -> assert false (* ill-formed term *)
    | Leaf _, _ -> assert false  (* wrong arity *)
  in
  goto trie t (fun t -> t)

(** a trie of ints *)
module FVTrie = Trie.Make(Ptmap)

(** a feature vector index, based on a trie that contains sets of hcs *)
type fv_index = feature list * trie

let mk_fv_index features = (features, Node Ptmap.empty)

let max_symbols = 30    (** maximum number of symbols considered for indexing *)

let mk_fv_index_signature signature =
  (* only consider a bounded number of symbols *)
  let bounded_signature = Utils.list_take max_symbols signature in
  let features = [feat_size_plus; feat_size_minus; sum_of_depths] @
    List.flatten
      (List.map (fun symb ->
        (* for each symbol, use 4 features *)
        [count_symb_plus symb; count_symb_minus symb])
        bounded_signature)
  in
  (* build an index with those features *)
  mk_fv_index features

let index_clause (features, trie) hc =
  (* feature vector of the hc *)
  let fv = compute_fv features hc in
  (* add the hc to the trie *)
  let k set = Leaf (C.CSet.add set hc) in
  let new_trie = goto_leaf trie fv k in
  (features, new_trie)

let remove_clause (features, trie) hc =
  (* feature vector of the hc *)
  let fv = compute_fv features hc in
  (* add the hc to the trie *)
  let k set = Leaf (C.CSet.remove set hc) in
  let new_trie = goto_leaf trie fv k in
  (features, new_trie)

(** hcs that subsume (potentially) the given hc *)
let retrieve_subsuming (features, trie) hc f =
  (* feature vector of the hc *)
  let fv = compute_fv features hc in
  let rec iter_lower fv node = match fv, node with
  | [], Leaf set -> C.CSet.iter set f
  | i::fv', Node map ->
    Ptmap.iter
      (fun j subnode -> if j <= i
        then iter_lower fv' subnode)  (* go in the branch *)
      map
  | _ -> failwith "number of features in feature vector changed"
  in
  iter_lower fv trie

(** hcs that are subsumed (potentially) by the given hc *)
let retrieve_subsumed (features, trie) hc f =
  (* feature vector of the hc *)
  let fv = compute_fv features hc in
  let rec iter_higher fv node = match fv, node with
  | [], Leaf set -> C.CSet.iter set f
  | i::fv', Node map ->
    Ptmap.iter
      (fun j subnode -> if j >= i
        then iter_higher fv' subnode)  (* go in the branch *)
      map
  | _ -> failwith "number of features in feature vector changed"
  in
  iter_higher fv trie
