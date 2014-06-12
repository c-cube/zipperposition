
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

(** {1 Chaining on Sets} *)

open Logtk

module Lit = Literal

(** {2 Inference Rules} *)
module type S = sig
  module Env : Env.S
  module C : module type of Env.C
  module PS : module type of Env.ProofState

  val preprocess : Formula.FO.t -> Formula.FO.t
  (** Preprocessing of formula, during CNF, to remove most set operators,
      keeping only those of the form
      a \cap b \cap ...  \subseteq a' \cup b' \cup ... *)

  val setup : unit -> unit
end

(* global theory currently in use *)
let _theory = ref Theories.Sets.default

module Make(E : Env.S) = struct
  module Env = E
  module PS = Env.ProofState
  module C = Env.C
  module Ctx = Env.Ctx
  module F = Formula.FO
  module TS = Theories.Sets

  let _theory = ref TS.default

  type sets_list = {
    sets : F.term list;
    comp : F.term list;
    empty : bool;
    ty : Type.ty
  }

  (** Preprocessing of set terms in both sides of a \subseteq
      and returns a list of list of sets.
      If ~left, the result is considered as a list of intersections of sets;
      otherwise, it is a list of unions of sets
    *)
  let rec preprocess_subseteq ~sets ~left s_list acc =
    match s_list with
      | s::l ->
        let vs = TS.view ~sets s in
        begin match vs with
          | TS.Union s_list' ->
            if left then begin
              Util.debug 3 " --- A inter (B union C) subseteq D --> %s"
                "(A inter B subseteq D) and (A inter C subseteq D)";
              let rec aux l_aux acc_aux =
                match l_aux with
                  | h::t -> aux t ((preprocess_subseteq ~sets ~left (h::l) acc)@acc_aux)
                  | [] -> acc_aux
              in aux s_list' []
            end else begin
              Util.debug 3 " --- A union (B union C) --> A union B union C";
              preprocess_subseteq ~sets ~left s_list' (preprocess_subseteq ~sets ~left l acc)
            end
          | TS.Inter s_list' ->
            if left then begin
              Util.debug 3 " --- A inter (B inter C) --> A inter B inter C";
              preprocess_subseteq ~sets ~left s_list' (preprocess_subseteq ~sets ~left l acc)
            end else begin
              Util.debug 3 " --- A subseteq B union (C inter D) --> %s"
                "(A subseteq B union C) and (A subseteq B union D)";
              let rec aux l_aux acc_aux =
                match l_aux with
                  | h::t -> aux t ((preprocess_subseteq ~sets ~left (h::l) acc)@acc_aux)
                  | [] -> acc_aux
              in aux s_list' []
            end
          | TS.Diff (s1,s2) ->
            Util.debug 3 " --- A diff B --> A inter comp(B)";
            preprocess_subseteq ~sets ~left
              ((TS.mk_inter ~sets [s1;(TS.mk_complement ~sets s2)])::l)
              acc
          | TS.Singleton x ->
            Util.debug 3 " --- {x} --> {x}";
            preprocess_subseteq ~sets ~left l
              (List.map
                (fun sr -> {sets = (s::sr.sets);comp = sr.comp;empty = false; ty = sr.ty})
                acc)
         | TS.Emptyset ty ->
            if left then begin
              Util.debug 3 " --- A inter empty --> empty";
              [{sets = []; comp = []; empty = true; ty = ty}]
            end else begin
              Util.debug 3 " --- A union empty --> A";
              preprocess_subseteq ~sets ~left l acc
            end
          | TS.Complement s' ->
            let vs' = TS.view ~sets s' in
            begin match vs' with
              | TS.Union s_list' ->
                Util.debug 3 " --- comp(A union B) --> comp(A) inter comp(B)";
                preprocess_subseteq ~sets ~left
                  (TS.mk_inter ~sets (List.map (fun x -> TS.mk_complement ~sets x) s_list')::l)
                  acc
              | TS.Inter s_list' ->
                Util.debug 3 " --- comp(A inter B) --> comp(A) union comp(B)";
                preprocess_subseteq ~sets ~left
                  (TS.mk_union ~sets (List.map (fun x -> TS.mk_complement ~sets x) s_list')::l)
                  acc
              | TS.Diff (s1,s2) ->
                Util.debug 3 " --- comp(A diff B) --> comp(A) union B";
                preprocess_subseteq ~sets ~left
                  ((TS.mk_union ~sets [(TS.mk_complement ~sets s1);s2])::l)
                  acc
              | TS.Singleton x ->
                Util.debug 3 " --- comp({x}) --> comp({x})";
                preprocess_subseteq ~sets ~left l
                  (List.map
                    (fun sr -> {sets = sr.sets; comp = s'::(sr.comp); empty = false; ty = sr.ty})
                    acc)
              | TS.Emptyset ty ->
                if left then begin
                  Util.debug 3 " --- A inter comp(empty) --> A";
                  preprocess_subseteq ~sets ~left l acc
                end else begin
                  Util.debug 3 " --- A union comp(empty) --> comp(empty)";
                  [{sets = []; comp = []; empty = true; ty = ty}]
                end
              | TS.Complement s'' ->
                Util.debug 3 " --- comp(comp(A)) --> A";
                preprocess_subseteq ~sets ~left (s''::l) acc
              | TS.Other _ ->
                Util.debug 3 " --- comp(A) --> comp(A)";
                preprocess_subseteq ~sets ~left l
                  (List.map
                    (fun sr -> {sets = sr.sets; comp = s'::(sr.comp); empty = false; ty = sr.ty})
                    acc)
              | _ -> assert false
            end
          | TS.Other _ ->
            Util.debug 3 " --- A --> A";
            preprocess_subseteq ~sets ~left l
              (List.map
                (fun sr -> {sets = s::(sr.sets); comp = sr.comp; empty = false; ty = sr.ty})
                acc)
          | _ -> assert false
        end
      | [] -> acc

  (** reconstructs the set terms
      returns a list of terms of the form
      A \cap B \cap ... \subseteq A' \cup B' \cup ...
      constructed by doing the cartesian product of left side terms and right side terms
    *)
  let reform_subseteq ~sets left right =
    Util.debug 3 "Reconstruction of clauses...";
    let rec aux l r acc =
      match l with
        | h::t ->
          begin match r with
            | h'::t' ->
                let h_inter =
                  if h.sets = [] && h'.comp = [] then
                    TS.mk_empty ~sets h.ty
                else if h.empty || h'.empty then
                  TS.mk_empty ~sets h.ty
                else
                  TS.mk_inter ~sets (h.sets@h'.comp)
                and h_union =
                  if h.comp = [] && h'.sets = [] then
                    TS.mk_empty ~sets h.ty
                  else
                    TS.mk_union ~sets (h'.sets@h.comp) in
                  aux l t' (F.Base.atom ((TS.mk_subseteq ~sets h_inter h_union))::acc)
            | [] -> aux t right acc
          end
        | [] -> acc
    in aux left right []

  let rec preprocess f =
    let sets = !_theory in
    let vf = F.view f in
    match vf with
      | F.True
      | F.False -> f
      | F.Atom t ->
        let vt = TS.view ~sets t in
        begin match vt with
          | TS.Member (x,s) ->
            Util.debug 3 "Found a set of type member -- %s"
              "applying: x in A --> {x} subseteq A";
            preprocess (F.Base.atom (TS.mk_subseteq ~sets (TS.mk_singleton ~sets x) s))
          | TS.Subset (s1,s2) ->
            Util.debug 3 "Found a set of type subset -- %s"
              "applying: A subset B --> A subseteq B and not(B subseteq A)";
            preprocess (F.Base.and_
                [(F.Base.atom (TS.mk_subseteq ~sets s1 s2));
                 (F.Base.not_ (F.Base.atom (TS.mk_subseteq ~sets s2 s1)))
                ])
          | TS.Subseteq (s1,s2) ->
            Util.debug 3 "Found a set of type subseteq -- %s"
              "beginning transformation into a conjonction of subseteq clauses";
            let preproc_left =
              preprocess_subseteq ~sets ~left:true [s1]
              [{sets = []; comp = []; empty = false; ty = TS._get_set_type ~sets s1}]
            and preproc_right =
              preprocess_subseteq ~sets ~left:false [s2]
              [{sets = []; comp = []; empty = false; ty = TS._get_set_type ~sets s2}] in
              F.Base.and_ (reform_subseteq ~sets preproc_left preproc_right)
          | TS.Other _ -> f
          | _ -> assert false
        end
      | F.And f_list -> F.Base.and_ (List.map preprocess f_list)
      | F.Or f_list -> F.Base.or_ (List.map preprocess f_list)
      | F.Not f' ->
        begin match F.view f' with
          | F.True
          | F.False -> f
          | F.Atom t ->
            let vt = TS.view ~sets t in
            begin match vt with
              | TS.Member (x,s) ->
                Util.debug 3 "Found a set of type not member -- %s"
                  "applying x not in A --> not({x} subseteq A)";
                let subseteq_new = TS.mk_subseteq ~sets (TS.mk_singleton ~sets x) s in
                  preprocess (F.Base.not_ (F.Base.atom subseteq_new))
              | TS.Subset (s1,s2) ->
                Util.debug 3 "Found a set of type not subset -- %s"
                  "applying not(A subset B) --> (B subseteq A) or not(A subseteq B)";
                preprocess (F.Base.or_
                  [(F.Base.atom (TS.mk_subseteq ~sets s2 s1));
                   (F.Base.not_ (F.Base.atom (TS.mk_subseteq ~sets s1 s2)))
                  ])
              | TS.Subseteq (s1,s2) ->
                Util.debug 3 "Found a set of type not subseteq -- %s"
                  "beginning transformation into a disjonction of not subseteq clauses";
                let preproc_left =
                  preprocess_subseteq ~sets ~left:true [s1]
                    [{sets = []; comp = []; empty = false; ty = TS._get_set_type ~sets s1}]
                and preproc_right =
                  preprocess_subseteq ~sets ~left:false [s2]
                    [{sets = []; comp = []; empty = false; ty = TS._get_set_type ~sets s1}] in
                  F.Base.or_ (List.map (fun x -> F.Base.not_ x)
                    (reform_subseteq ~sets preproc_left preproc_right))
              | TS.Other _ -> f
              | _ -> assert false
            end
          | F.And f_list -> F.Base.not_ (F.Base.and_ (List.map preprocess f_list))
          | F.Or f_list -> F.Base.not_ (F.Base.or_ (List.map preprocess f_list))
          | F.Not f'' -> F.Base.not_ (F.Base.not_ (preprocess f''))
          | F.Imply (f1,f2) -> F.Base.not_ (F.Base.imply (preprocess f1) (preprocess f2))
          | F.Equiv (f1,f2) -> F.Base.not_ (F.Base.equiv (preprocess f1) (preprocess f2))
          | F.Xor (f1,f2) -> F.Base.not_ (F.Base.xor (preprocess f1) (preprocess f2))
          | F.Eq (t1,t2) ->
            if TS.is_set ~sets t1
            then begin
              Util.debug 3 "Found a set of type not equals -- %s"
                "applying not(A = B) --> not(A subseteq B) or not(B subseteq A)";
              preprocess (F.Base.or_
                [(F.Base.not_ (F.Base.atom (TS.mk_subseteq ~sets t1 t2)));
                (F.Base.not_ (F.Base.atom (TS.mk_subseteq ~sets t2 t1)))]
            )
            end else f
          | F.Neq (t1,t2) ->
            if TS.is_set ~sets t1
            then begin
              Util.debug 3 "Found a set of type equals -- %s"
                "applying not(A <> B) --> (A subseteq B) and (B subseteq A)";
              preprocess (F.Base.and_
                [(F.Base.atom (TS.mk_subseteq ~sets t1 t2));
                (F.Base.atom (TS.mk_subseteq ~sets t2 t1))]
            )
            end else f
          | F.Forall (t,f'') -> F.Base.not_ (F.Base.__mk_forall t (preprocess f''))
          | F.Exists (t,f'') -> F.Base.not_ (F.Base.__mk_exists t (preprocess f''))
          | F.ForallTy f'' -> F.Base.not_ (F.Base.__mk_forall_ty (preprocess f''))
        end
      | F.Imply (f1,f2) -> F.Base.imply (preprocess f1) (preprocess f2)
      | F.Equiv (f1,f2) -> F.Base.equiv (preprocess f1) (preprocess f2)
      | F.Xor (f1,f2) -> F.Base.xor (preprocess f1) (preprocess f2)
      | F.Eq (t1,t2) ->
        if TS.is_set ~sets t1
        then begin
        Util.debug 3 "Found a set of type equals -- %s"
          "applying A = B --> (A subseteq B) and (B subseteq A)";
          preprocess (F.Base.and_
            [(F.Base.atom (TS.mk_subseteq ~sets t1 t2));
             (F.Base.atom (TS.mk_subseteq ~sets t2 t1))]
          )
        end else f
      | F.Neq (t1,t2) ->
        if TS.is_set ~sets t1
        then begin
          Util.debug 3 "Found a set of type not equals -- %s"
            "applying A <> B --> not(A subseteq B) or not(B subseteq A)";
          preprocess (F.Base.or_
            [(F.Base.not_ (F.Base.atom (TS.mk_subseteq ~sets t1 t2)));
             (F.Base.not_ (F.Base.atom (TS.mk_subseteq ~sets t2 t1)))]
          )
        end else f
      | F.Forall (t,f') -> F.Base.__mk_forall t (preprocess f')
      | F.Exists (t,f') -> F.Base.__mk_exists t (preprocess f')
      | F.ForallTy f' -> F.Base.__mk_forall_ty (preprocess f')

  let setup () =
    Util.debug 1 "setup set chaining";
    Env.add_cnf_option (Cnf.PostNNF preprocess);
    Ctx.Lit.add_from_hook (Lit.Conv.set_hook_from ~sets:!_theory);
    Ctx.Lit.add_to_hook (Lit.Conv.set_hook_to ~sets:!_theory);
    (* maybe change the set signature? FIXME
    Signal.on Ctx.Theories.Sets.on_add
      (fun theory' -> _theory := theory'; Signal.ContinueListening);
    *)
    ()
end

let _initial_setup () =
  (* declare types for set operators *)
  Util.debug 3 "declaring set types...";
  let set_signature = Theories.Sets.signature !_theory in
  Params.signature := Signature.merge !Params.signature set_signature;
  (* add hooks (printing, lit conversion) *)
  FOTerm.add_hook (Theories.Sets.print_hook ~sets:!_theory);
  ()

let extension =
  let module DOIT(Env : Env.S) = struct
    include Extensions.MakeAction(Env)
    let actions =
      let module Set = Make(Env) in
      [Ext_general Set.setup]
  end
  in
  { Extensions.default with
    Extensions.name="set";
    Extensions.init_actions = [Extensions.Init_do _initial_setup];
    Extensions.make=(module DOIT : Extensions.ENV_TO_S);
  }

let () =
  Params.add_opts
    [ "-set"
      , Arg.Unit (fun () -> Extensions.register extension)
      , "enable set chaining"
    ];
  ()

