(** {1 Low Level Prover} *)

open Logtk

module T = LLTerm
module F = LLTerm.Form
module Fmt = CCFormat

type form = LLTerm.Form.t

type res =
  | R_ok
  | R_fail

let section = LLProof.section
let stat_solve = Util.mk_stat "llproof.prove"
let prof_check = Util.mk_profiler "llproof.prove"

module Solver = Sidekick_msat_solver.Make(struct
    module T = struct
      module Term = struct
        include T
        let ty = ty_exn
        type state = unit
        let bool () b = if b then Form.true_ else Form.false_
        let abs () t = abs t
        let map_shallow () = map_shallow
      end
      module Ty = struct
        include T
        let is_bool = equal bool
      end
      module Fun = struct
        type t = Bind of Binder.t * Ty.t | Builtin of Builtin.t | Const of ID.t
        let equal a b = match a, b with
          | Bind (b1,ty1), Bind(b2,ty2) -> Binder.equal b1 b2 && Ty.equal ty1 ty2
          | Builtin b1, Builtin b2 -> b1=b2
          | Const id1, Const id2 -> ID.equal id1 id2
          | (Bind _ | Builtin _ | Const _), _ -> false
        let hash _ = 0 (* TODO *)
        let pp out = function
          | Bind (b,_) -> Fmt.fprintf out "(@[bind %a@])" Binder.pp b
          | Builtin b -> Builtin.pp out b
          | Const id -> ID.pp out id
      end
    end
    module P = struct type t = unit let pp = Fmt.(const string "<proof>") let default=() end

    module V = Sidekick_core.CC_view

    let cc_view (t:T.Term.t) : _ V.t =
      let module Fun = T.Fun in
      let module T = T.Term in
      match T.view t with
      | T.App (f, a) -> V.App_ho (f, Iter.return a)
      | T.AppBuiltin (Builtin.Box_opaque, _) -> V.Opaque t  (* simple equality *)
      | T.AppBuiltin (b,l) ->
        begin match F.view t with
          | F.True -> V.Bool true
          | F.False -> V.Bool false
          | F.Eq (a,b) -> V.Eq (a,b)
          | F.Not a -> V.Not a
          | _ ->
            V.App_fun (Fun.Builtin b, Iter.of_list l)
        end
      | T.Ite (a,b,c) -> V.If (a,b,c)
      | T.Bind _ ->
        (* do not enter binders at all *)
        V.Opaque t
      | Int_pred _ | Rat_pred _
      | T.Const _ | T.Var _ | T.Type | T.Arrow _ -> V.Opaque t

    let is_valid_literal (t:T.Term.t) : bool =
      T.Term.db_closed t
  end)

(** main state *)
type t = Solver.t
type final_state = t

let solve_ (solver:t) : res =
  match Solver.solve ~assumptions:[] solver with
    | Solver.Unknown why ->
      Util.debugf ~section 5
        "(@[llprover.prove.fail@ :unknown %a@])" (fun k->k Solver.Unknown.pp why);
      R_fail
    | Solver.Unsat _ ->
      (* TODO: print/check? *)
      Util.debugf ~section 5
        "(@[llprover.prove.success@ :stats %a@])" (fun k->k Solver.pp_stats solver);
      R_ok
    | Solver.Sat m ->
      Util.debugf ~section 1 "(@[llprover.prove.failed@ :model %a@])"
        (fun k->k Solver.Model.pp m);
      R_fail

let can_check : LLProof.tag list -> bool =
  let open Builtin.Tag in
  let f = function
    | T_ho | T_ext -> true
    | T_defexp -> false (* TODO: need a notion of rewrite rule directly in sidekick *)
    | T_lra | T_lia | T_ind | T_data
    | T_distinct | T_ac _
    | T_conv | T_avatar -> false
  in
  List.for_all f

module Gensym = struct
  type t = {
    mutable fresh: int;
  }

  let create () : t = {fresh=0}

  let fresh_term (self:t) ~pre (ty:T.t) : T.t =
    let name = Printf.sprintf "_tseitin_%s%d" pre self.fresh in
    self.fresh <- 1 + self.fresh;
    let id = ID.make name in
    T.const ~ty id
end

(* booleans *)
module Th_bool = Sidekick_th_bool_static.Make(struct
    module Gensym = Gensym
    module S = Solver
    module T = T
    type term = T.t

    module F = T.Form
    open Sidekick_th_bool_static

    let mk_bool () = function
      | B_bool true -> F.true_
      | B_bool false -> F.false_
      | B_or a -> F.or_ (Sidekick_util.IArray.to_list a)
      | B_and a -> F.and_ (Sidekick_util.IArray.to_list a)
      | B_equiv (a,b) -> F.equiv a b
      | B_not a -> F.not_ a
      | B_imply (a,b) -> F.imply_l (Sidekick_util.IArray.to_list a) b
      | B_eq (a,b) -> F.eq a b
      | B_ite (a,b,c) -> T.ite a b c
      | B_atom t -> t
      | B_opaque_bool t -> t

    let view_as_bool t =
      match F.view t with
      | _ when not (T.db_closed t) -> B_opaque_bool t
      | F.True -> B_bool true
      | F.False -> B_bool false
      | _ when not (T.db_closed t) -> B_opaque_bool t
      | F.And l -> B_and (Sidekick_util.IArray.of_list l)
      | F.Or l -> B_or (Sidekick_util.IArray.of_list l)
      | F.Equiv (a,b) -> B_equiv (a,b)
      | F.Eq (a,b) -> B_eq (a,b)
      | F.Neq (a,b) -> B_not (F.eq a b)
      | F.Not a -> B_not a
      | F.Xor (a,b) -> B_equiv (a, F.not_ b)
      | F.Imply (a,b) -> B_imply (Sidekick_util.IArray.singleton a, b)
      | F.Atom t ->
        begin match T.view t with
          | Ite (a,b,c) -> B_ite (a,b,c)
          | _ -> B_atom t
        end
      | F.Forall _ | F.Exists _ -> B_opaque_bool t
      | F.Int_pred _ | F.Rat_pred _ ->
        B_atom t

    (* be sure to use Tseitin encoding on subterms *)
    let check_congruence_classes = true
  end)

(* Theory for lambda-expressions. This theory has two functions:
   - For any non-β-reduced term, it adds (λx. t) s = t[s/x] to the congruence closure.
   - For any equality in the congruence closure of a lambda-term (λx. t)
      with some other term s, it adds an equality t[u/x] = s u when a term of the
      form s u appears.
*)
module Th_lambda = struct
  module SI = Solver.Solver_internal
  module CC = SI.CC
  module N = SI.CC.N
  module Expl = SI.CC.Expl
  module N_tbl = Sidekick_util.Backtrackable_tbl.Make(N)
  module T_tbl = Sidekick_util.Backtrackable_tbl.Make(T)
  module T2_tbl = CCHashtbl.Make(struct
      type t = T.t * T.t
      let equal = CCPair.equal T.equal T.equal
      let hash = CCHash.pair T.hash T.hash
    end)

  (* a node [lm_node] decorated with a lambda-term *)
  type lambda_node = {
    lm_node: N.t;
    lm_ty_arg: T.t;
    lm_body: T.t;
  }
  type ext_skolem = {
    sko: T.t;
    mutable instantiated: bool;
  }

  type state = {
    lambdas_in_cls: lambda_node list N_tbl.t; (* repr -> lambdas_in_cls for the class *)
    lambdas_of_ty: lambda_node list T_tbl.t; (* ty -> list of lambdas_in_cls of this type *)
    ext_skolems: ext_skolem T2_tbl.t; (* pair of lambdas -> extensional skolem for this pair *)
  }

  let create tst : state =
    { lambdas_in_cls=N_tbl.create ~size:128 ();
      lambdas_of_ty=T_tbl.create ~size:24 ();
      ext_skolems=T2_tbl.create 24;
    }

  let push_level st =
    N_tbl.push_level st.lambdas_in_cls;
    T_tbl.push_level st.lambdas_of_ty;
    ()

  let pop_levels st n =
    N_tbl.pop_levels st.lambdas_in_cls n;
    T_tbl.pop_levels st.lambdas_of_ty n;
    ()

  let get_lambdas_in_cls st (n:N.t) : _ list =
    N_tbl.get st.lambdas_in_cls n |> CCOpt.get_or ~default:[]

  let errorf msg = Util.errorf ~where:"llprover" msg

  (* do static beta-reduction *)
  let beta_reduce st cc node : unit =
    let t = SI.CC.N.term node in
    match T.view t with
    | T.App (f, arg) ->
      begin match T.view f with
        | T.Bind {binder=Binder.Lambda;ty_var;body} ->
          begin match LLTerm.ty arg with
            | Some ty_arg when T.equal ty_var ty_arg ->
              (* β-reduction *)
              let reduced_term = T.db_eval ~sub:arg body in
              Util.debugf 3 ~section "@[th-lambda.beta-reduce@ :term %a@ :into %a@]"
                (fun k -> k T.pp t T.pp reduced_term);
              let reduced_node = SI.CC.add_term cc reduced_term in
              let expl = SI.CC.Expl.mk_list [] in (* trivial *)
              SI.CC.merge cc node reduced_node expl
            | Some ty_x ->
              errorf "type error: cannot apply `%a`@ to `%a : %a`" T.pp t T.pp arg T.pp ty_x
            | None -> errorf "type error: cannot apply `%a`@ to `%a : none`" T.pp t T.pp arg
          end
        | _ -> ()
      end
    | _ -> ()

  (* when merging classes [a] and [b], look in each class.
     If the class [a] contains [λx. t], look in all parents of [b]
     for some [apply b' u] where [b=b'].
     For each such parent of [b], do the merge
     [a=λx. t && b=b' && expl ==> apply b' u = t[x\u]] *)
  let cc_on_pre_merge si (st:state)
      (cc:SI.CC.t) ac (a:N.t) (b:N.t) (expl_a_b:SI.CC.Expl.t) : unit =
    let iter_lambdas_in_cls a b =
      match get_lambdas_in_cls st a with
      | [] -> () (* no lambdas_in_cls *)
      | lambdas_in_cls ->
        let app_parents =
          N.iter_parents b
          |> Iter.filter_map
            (fun n_parent_b ->
               let t_parent_b = N.term n_parent_b in
               match T.view t_parent_b with
               | App (f, arg) when N.equal (CC.find_t cc f) b ->
                 Some (n_parent_b, f, arg)
               | _ -> None)
        in
        let all_new_beta =
          app_parents
          |> Iter.flat_map
            (fun (n_parent_b, f, arg) ->
               Iter.of_list lambdas_in_cls |> Iter.map (fun lm -> n_parent_b, f, arg, lm))
        in
        all_new_beta
          (fun (n_parent_b, f, arg, lm) ->
             let {lm_node; lm_body; } = lm in
             (* [app f arg = body[x\arg]] because [f=b] and [b=a=λx. body] *)
             let new_t = T.db_eval ~sub:arg lm_body in
             Util.debugf 3 ~section
               "(@[th-lambda.cc-beta-reduce@ (merging n1=n2, n2 being applied)@ \
                :n1 %a@ :n2 %a@ :lambda-n1 %a@ :parent-n2 %a@ :new-t %a@])"
               (fun k -> k N.pp a N.pp b N.pp lm_node N.pp n_parent_b T.pp new_t);
             let expl =
               Expl.mk_list
                 [expl_a_b; Expl.mk_merge lm_node a; Expl.mk_merge b (CC.add_term cc f)]
             in
             CC.merge_t cc (N.term n_parent_b) new_t expl;
          );
    in
    iter_lambdas_in_cls a b;
    iter_lambdas_in_cls b a;
    let lms = get_lambdas_in_cls st a @ get_lambdas_in_cls st b in
    if lms <> [] then (
      N_tbl.add st.lambdas_in_cls a lms; (* update with the merge *)
    );
    ()

  let sorted_pair t1 t2 : T.t * T.t =
    if T.compare t1 t2 <= 0 then t1, t2 else t2, t1

  (* final check.
     - extensionality:
       add [lm=lm' => lm sko=lm' sko] for each pair of lambdas [lm, lm']
       with the same type. [sko] is unique to the pair [lm,lm'].
  *)
  let final_check (st:state) (si:SI.t) (acts:SI.actions) trail : unit =
    let mk_lit ?sign t = SI.mk_lit si acts t in
    let lambdas =
      T_tbl.to_iter st.lambdas_of_ty
      |> Iter.map snd
      |> Iter.flat_map
        (function
          | [] -> assert false
          | [_] -> Iter.empty (* no pairs *)
          | l -> Iter.diagonal_l l)
    in
    begin
      lambdas
        (fun (lm1,lm2) ->
           let t1 = N.term lm1.lm_node in
           let t2 = N.term lm2.lm_node in
           assert (not (T.equal t1 t2));
           let (t1,t2) as pair = sorted_pair t1 t2 in
           let sko =
             try T2_tbl.find st.ext_skolems pair
             with Not_found ->
               let sko =
                 let c = ID.makef "_ext_sko_%d" (T2_tbl.length st.ext_skolems) in
                 T.const ~ty:lm1.lm_ty_arg c
               in
               let sko = {sko; instantiated=false} in
               T2_tbl.add st.ext_skolems pair sko; (* save it *)
               sko
           in
           if not sko.instantiated then (
             sko.instantiated <- true;
             (* axiom: [t1 sko=t2 sko => t1=t2] *)
             let ext_axiom = [
               mk_lit @@ T.Form.neq (T.app t1 sko.sko) (T.app t2 sko.sko);
               mk_lit @@ T.Form.eq t1 t2;
             ] in
             Util.debugf ~section 5 "(@[th-lambda.add-ext-axiom@ %a@])"
               (fun k->k (Fmt.Dump.list SI.Lit.pp) ext_axiom);
             SI.add_clause_permanent si acts ext_axiom;
           );
           ())
    end;
    CC.check (SI.cc si) acts;
    Util.debugf 5 ~section
      "(@[th-lambda.final-check@ :classes (@[%a@])@ (@[<hv2>:trail@ %a@])@])"
      (fun k->k (Util.pp_seq (Fmt.Dump.list N.pp))
          (CC.all_classes (SI.cc si)
           |> Iter.map (fun n-> N.iter_class n |> Iter.to_rev_list))
          (Util.pp_seq SI.Lit.pp) trail);
    ()

  (* if [t] is a lambda term, add its node to the set of lambdas_in_cls *)
  let add_lambda (st:state) (n:SI.CC.N.t) (t:T.t) : unit =
    match T.view t with
    | T.Bind {binder=Binder.Lambda; ty_var; body} ->
      let lm = { lm_node=n; lm_body=body; lm_ty_arg=ty_var } in
      N_tbl.add st.lambdas_in_cls n [lm];
      let ty_t = T.ty_exn t in
      let others =
        try T_tbl.find st.lambdas_of_ty ty_t with Not_found -> []
      in
      T_tbl.add st.lambdas_of_ty ty_t (lm :: others);
    | _ -> ()

  let cc_on_new_term _ (st:state) (cc:SI.CC.t) (n:SI.CC.N.t) (t:T.t) =
    add_lambda st n t;
    beta_reduce st cc n;
    ()

  let create_and_setup si =
    Util.debug 3 ~section "Setting up theory of lambda expressions.";
    let st = create (SI.tst si) in
    SI.on_final_check si (final_check st);
    SI.CC.on_new_term (SI.cc si) (cc_on_new_term si st);
    SI.CC.on_pre_merge (SI.cc si) (cc_on_pre_merge si st);
    st

  let theory =
    Solver.mk_theory
      ~name:"th-lambda"
      ~create_and_setup
      ~push_level
      ~pop_levels
      ()
end

let prove (a:form list) (b:form) : _*_ =
  Util.debugf ~section 3
    "(@[@{<yellow>llprover.prove@}@ :hyps (@[<hv>%a@])@ :concl %a@])"
    (fun k->k (Util.pp_list T.pp) a T.pp b);
  Util.incr_stat stat_solve;
  Util.enter_prof prof_check;
  (* see if we enable debug in sidekick, but reduce verbosity *)
  begin match Util.Section.get_debug section with
    | Some n when n>5 -> Msat.Log.set_debug (n-5)
    | _ -> ()
  end;
  (* prove [a ∧ -b ⇒ ⊥] *)
  let theories = [Th_bool.theory; Th_lambda.theory] in
  let solver = Solver.create ~size:`Small ~store_proof:false ~theories () () in
  List.iter
    (fun t -> Solver.add_clause_l solver [Solver.mk_atom_t solver t])
    (T.Form.not_ b :: a);
  let res = solve_ solver in
  Util.exit_prof prof_check;
  res, solver

let pp_stats = Solver.pp_stats
