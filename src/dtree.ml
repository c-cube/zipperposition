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

open Types

module T = Terms
module S = FoSubst
module Utils = FoUtils

(** Efficient perfect discrimination trees for matching *)

(* --------------------------------------------------------
 * term traversal in prefix order
 * -------------------------------------------------------- *)

(** index of subterm in prefix traversal *)
type position = int

(** get subterm by its position *)
let rec get_pos t pos = 
  match t.term, pos with
  | _, 0 -> t
  | Node (hd::l), _ -> get_subpos l (pos - hd.tsize)
  | _ -> assert false
and get_subpos l pos =
  match l, pos with
  | t::l', _ when t.tsize > pos -> get_pos t pos  (* search inside the term *)
  | t::l', _ -> get_subpos l' (pos - t.tsize) (* continue to next term *)
  | [], _ -> assert false

(** get position of next term *)
let next t pos = pos+1

(** skip subterms, got to next term that is not a subterm of t|pos *)
let skip t pos =
  let t_pos = get_pos t pos in
  pos + t_pos.tsize

(** maximum position in the term *)
let maxpos t = t.tsize - 1

(** find first atomic term of t *)
let rec term_to_char t =
  match t.term with
  | Var _ | Leaf _ -> t
  | Node (hd::_) -> term_to_char hd (* recurse to get the symbol *)
  | Node [] -> assert false

(** convert term to list of char *)
let to_list t =
  let l = ref []
  and pos = ref 0 in
  for i = 0 to maxpos t do
    let c = term_to_char (get_pos t !pos) in
    l := c :: !l;
    incr pos;
  done;
  List.rev !l

(* --------------------------------------------------------
 * discrimination tree
 * -------------------------------------------------------- *)

type 'a trie =
  | Node of 'a trie Terms.TMap.t        (** map atom -> trie *)
  | Leaf of (term * 'a * int) list      (** leaf with (term, value, priority) list *)

let empty_trie n = match n with
  | Node m when T.TMap.is_empty m -> true
  | Leaf [] -> true
  | _ -> false

(** get/add/remove the leaf for the given flatterm. The
    continuation k takes the leaf, and returns a leaf option
    that replaces the old leaf. 
    This function returns the new trie. *)
let goto_leaf trie t k =
  (* the root of the tree *)
  let root = trie in
  (* function to go to the given leaf, building it if needed *)
  let rec goto trie t rebuild =
    match trie, t with
    | (Leaf l) as leaf, [] -> (* found leaf *)
      (match k l with
      | new_leaf when leaf == new_leaf -> root  (* no change, return same tree *)
      | new_leaf -> rebuild new_leaf)           (* replace by new leaf *)
    | Node m, c::t' ->
      (try  (* insert in subtrie *)
        let subtrie = T.TMap.find c m in
        let rebuild' subtrie = match subtrie with
          | _ when empty_trie subtrie -> rebuild (Node (T.TMap.remove c m))
          | _ -> rebuild (Node (T.TMap.add c subtrie m))
        in
        goto subtrie t' rebuild'
      with Not_found -> (* no subtrie found *)
        let subtrie = if t' = [] then Leaf [] else Node T.TMap.empty
        and rebuild' subtrie = match subtrie with
          | _ when empty_trie subtrie -> rebuild (Node (T.TMap.remove c m))
          | _ -> rebuild (Node (T.TMap.add c subtrie m))
        in
        goto subtrie t' rebuild')
    | Node _, [] -> assert false (* ill-formed term *)
    | Leaf _, _ -> assert false  (* wrong arity *)
  in
  goto trie t (fun t -> t)
      
(** the tree itself, with metadata *)
type 'a dtree = {
  min_var : int;
  max_var : int;
  cmp : 'a -> 'a -> bool;
  tree : 'a trie;
}

(** empty discrimination tree (with a comparison function) *)
let empty f = {
  min_var = max_int;
  max_var = min_int;
  cmp = f;
  tree = Node T.TMap.empty;
}

(** add a term and a value to the discrimination tree. The priority
    is used to sort index values (by increasing number, the lowest
    are iterated on the first). *)
let add dt ?(priority=0) t v =
  let chars = to_list t in
  let k l =
    let l' = (t, v, priority)::l in
    Leaf (List.stable_sort (fun (_, _, p1) (_, _, p2) -> p1 - p2) l')
  in
  let tree = goto_leaf dt.tree chars k
  and max_var = max (T.max_var t.vars) dt.max_var
  and min_var = min (T.min_var t.vars) dt.min_var in
  {dt with tree; max_var; min_var;}

(** remove the term -> value from the tree *)
let remove dt t v =
  let chars = to_list t in
  let k l =
    (* remove tuples that match *)
    let l' = List.filter (fun (t', v', _) -> t' != t || not (dt.cmp v v')) l in
    Leaf l'
  in
  let tree = goto_leaf dt.tree chars k in
  (* we assume the (term->value) was in the tree; we also do not
    update max and min vars, so they are an approximation *)
  {dt with tree;}

(** maximum variable in the tree *)
let min_var dt = dt.min_var

(** minimum variable in the tree *)
let max_var dt = dt.max_var

(** iterate on all (term -> value) such that subst(term) = input_term *)
let iter_match dt t k =
  (* variable collision check *)
  assert (T.is_ground_term t || T.max_var t.vars < dt.min_var || T.min_var t.vars > dt.max_var);
  (* recursive traversal of the trie, following paths compatible with t *)
  let rec traverse trie pos subst =
    match trie with
    | Leaf l ->  (* yield all answers *)
      List.iter (fun (t', v, _) -> k t' v subst) l
    | Node m ->
      (* "lazy" transformation to flatterm *)
      let t_pos = get_pos t pos in
      let t1 = term_to_char t_pos in
      T.TMap.iter
        (fun t1' subtrie ->
          (* explore branch that has the same symbol, if any *)
          (if T.eq_term t1' t1 then (assert (not (T.is_var t1));
                                     traverse subtrie (next t pos) subst));
          (* if variable, try to bind it and continue *)
          (if T.is_var t1' && t1'.sort = t_pos.sort && S.is_in_subst t1' subst
            then  (* already bound, check consistency *)
              let t_matched = T.expand_bindings t_pos
              and t_bound = T.expand_bindings t1'.binding in
              if T.eq_term t_matched t_bound
                then traverse subtrie (skip t pos) subst  (* skip term *)
                else () (* incompatible bindings of the variable *)
            else if T.is_var t1' && t1'.sort = t_pos.sort
              then begin
                (* t1' not bound, so we bind it and continue in subtree *)
                T.set_binding t1' (T.expand_bindings t_pos);
                let subst' = S.update_binding subst t1' in
                traverse subtrie (skip t pos) subst';
                T.reset_binding t1'  (* cleanup the variable *)
              end))
        m
  in
  T.reset_vars t;
  traverse dt.tree 0 S.id_subst

(** iterate on all (term -> value) in the tree *)
let iter dt k =
  let rec iter trie =
    match trie with
    | Node m -> T.TMap.iter (fun _ sub_dt -> iter sub_dt) m
    | Leaf l -> List.iter (fun (t, v, _) -> k t v) l
  in iter dt.tree
  

(* --------------------------------------------------------
 * pretty printing
 * -------------------------------------------------------- *)

module PrintTree = Prtree.Make(
  struct
    type t = string * term trie

    (* get a list of (key, sub-node) *)
    let get_values map =
      let l : t list ref = ref [] in
      T.TMap.iter
        (fun key node -> 
          let key_repr = Utils.sprintf "[@[<h>%a@]]" !T.pp_term#pp key in
          l := (key_repr, node) :: !l) map;
      !l
    and pp_rule formatter (l, r, _) =
      Format.fprintf formatter "@[<h>%a → %a@]" !T.pp_term#pp l !T.pp_term#pp r

    (* recurse in subterms *)
    let decomp (prefix, t) = match t with
      | Node m -> prefix, get_values m
      | Leaf l ->
        let rules_repr = Utils.sprintf "%s @[<h>{%a}@]"
          prefix (Utils.pp_list ~sep:"; " pp_rule) l in
        rules_repr, []
  end)

let pp_term_tree formatter dt = PrintTree.print formatter ("", dt.tree)
