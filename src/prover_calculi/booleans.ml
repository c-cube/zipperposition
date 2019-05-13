
(* This file is free software, part of Zipperposition. See file "license" for more details. *)

(** {1 boolean subterms} *)

open Logtk
open Libzipperposition

module T = Term

let _axioms_enabled = ref false

module type S = sig
  module Env : Env.S
  module C : module type of Env.C

  (** {6 Registration} *)

  val setup : unit -> unit
  (** Register rules in the environment *)
end


module Make(E : Env.S) : S with module Env = E = struct
  module Env = E
  module C = Env.C
  module Ctx = Env.Ctx

  let (=~),(/~) = Literal.mk_eq, Literal.mk_neq
  let (@:) = T.app_builtin ~ty:Type.prop
  let no a = a =~ T.false_
  let yes a = a =~ T.true_
  let imply a b = Builtin.Imply @: [a;b]
  let const_true p = T.fun_ (List.hd @@ fst @@ Type.open_fun (T.ty p)) T.true_

  let true_not_false = [T.true_ /~ T.false_]
  let true_or_false a = [yes a; a =~ T.false_]
  let imp_true1 a b = [yes a; yes(imply a b)]
  let imp_true2 a b = [no b; yes(imply a b)]
  let imp_false a b = [no(imply a b); no a; yes b]
  let all_true p = [p /~ const_true p; yes(Builtin.ForallConst@:[p])]
  let all_false p = [no(Builtin.ForallConst@:[p]); p =~ const_true p]
  let eq_true x y = [x/~y; yes(Builtin.Eq@:[x;y])]
  let eq_false x y = [no(Builtin.Eq@:[x;y]); x=~y]
  let and_ a b = [Builtin.And @: [a;b] 
                    =~  imply (imply a (imply b T.false_)) T.false_]
  let or_ a b = [Builtin.Or @: [a;b] 
                    =~  imply (imply a T.false_) b] 

  let and_true a  = [Builtin.And @: [T.true_; a] =~ a]
  let and_false a  = [Builtin.And @: [T.false_; a] =~ T.false_]
  
  
  let not = [T.app_builtin ~ty:(Type.arrow [Type.prop] Type.prop) Builtin.Not [] =~ 
             T.fun_ Type.prop (imply (T.bvar ~ty:Type.prop 0) T.false_)]
  let exists t = 
    let t2bool = Type.arrow [t] Type.prop in
    [T.app_builtin ~ty:(Type.arrow [t2bool] Type.prop) Builtin.ExistsConst [] =~ T.fun_ t2bool
      (Builtin.Not @:[Builtin.ForallConst @:[T.fun_ t (Builtin.Not @:[T.app (T.bvar t2bool 1) [T.bvar t 0]])]])]
  
  let as_clause c = Env.C.create ~penalty:1 ~trail:Trail.empty c Proof.Step.trivial

  let create_clauses () = 
    let alpha_var = HVar.make ~ty:Type.tType 0 in
    let alpha = Type.var alpha_var in
    let a = T.var (HVar.make ~ty:Type.prop 0) in
    let b = T.var (HVar.make ~ty:Type.prop 1) in
    let p = T.var (HVar.make ~ty:(Type.arrow [alpha] Type.prop) 1) in
    let x = T.var (HVar.make ~ty:alpha 1) in
    let y = T.var (HVar.make ~ty:alpha 2) in
    let cls = [
      (* true_not_false;  *)
      (* true_or_false a; *)
      (*imp_true1 a b;
      imp_true2 a b; imp_false a b; 
      and_ a b     *)
      (* all_true p; 
      all_false p  ; eq_true x y  ; eq_false x y; 
      not          ; exists alpha; *)
      (* ; or_ a b;  *)
      and_false a; and_true a; 
    ] in
    let res = List.map as_clause cls in
    CCFormat.printf "CREATED CLAUSES: %a\n" (CCList.pp Env.C.pp) res;
    Iter.of_list res

  let bool_cases c : C.t list =
    let sub_terms =
      C.Seq.terms c
      |> Iter.flat_map(fun t ->
           T.Seq.subterms_depth t
           |> Iter.filter_map (fun (t,d) -> if d>0  then Some t else None))
      |> Iter.filter(fun t ->
           Type.is_prop(T.ty t) &&
           T.DB.is_closed t &&
           begin match T.view t with
             | T.Const _ | T.App _ -> true
             | T.AppBuiltin ((Builtin.True | Builtin.False | Builtin.And), _) -> false
			 | T.AppBuiltin (_, _) -> true
             | T.Var _ | T.DB _ -> false
             | T.Fun _ -> assert false (* by typing *)
           end)
      |> T.Set.of_seq
    in
	T.Set.to_list sub_terms |> List.map(fun b ->
		let proof = Proof.Step.inference [C.proof_parent c]
			~rule:(Proof.Rule.mk"bool_cases")
		in
		C.create ~trail:(C.trail c) ~penalty:(C.penalty c)
			(Literal.mk_eq b T.true_ :: (C.lits c |> Literals.map(T.replace ~old:b ~by:T.false_) |> Array.to_list)) proof
	)


  let setup () =
	if !_axioms_enabled then(
		Env.ProofState.PassiveSet.add (create_clauses () );
		Env.add_unary_inf "bool_cases" bool_cases;
	);
    ()
end


let extension =
  let register env =
    let module E = (val env : Env.S) in
    let module ET = Make(E) in
    ET.setup ()
  in
  { Extensions.default with
      Extensions.name = "bool";
      env_actions=[register];
  }

let () =
  Options.add_opts
    [ "--boolean-axioms", Arg.Bool (fun b -> _axioms_enabled := b), 
      " enable/disable boolean axioms"  ];
  Params.add_to_mode "ho-complete-basic" (fun () ->
    _axioms_enabled := false
  );
  Params.add_to_mode "fo-complete-basic" (fun () ->
    _axioms_enabled := false
  );
  Extensions.register extension