
(* This file is free software, part of Zipperposition. See file "license" for more details. *)

(** Test unification *)

open Logtk
open Logtk_arbitrary
open Logtk_parsers

module Fmt = CCFormat
module T = Term
module S = Subst
module Q = QCheck

let t_test = Alcotest.testable T.ZF.pp T.equal

(** {2 Unit Tests} *)

let psterm, pstmt, pstmt_l, clear_scope, unif_ty =
  let tyctx = TypeInference.Ctx.create ~implicit_ty_args:false () in
  let pt s =
    let t = Parse_zf.parse_term Lex_zf.token (Lexing.from_string s) in
    let t = TypeInference.infer_exn tyctx t in
    (* TypeInference.Ctx.exit_scope tyctx; *)
    t
  and pst s =
    let t = Parse_zf.parse_statement Lex_zf.token (Lexing.from_string s) in
    let t = TypeInference.infer_statement_exn tyctx t in
    (* TypeInference.Ctx.exit_scope tyctx; *)
    t
  and pst_l s =
    let l = Parse_zf.parse_statement_list Lex_zf.token (Lexing.from_string s) in
    let l = TypeInference.infer_statements_exn
        ~on_var:`Default ~ctx:tyctx ~implicit_ty_args:false
        (Sequence.of_list l) in
    (* TypeInference.Ctx.exit_scope tyctx; *)
    CCVector.to_list l
  and unif_ty t u =
    TypedSTerm.unify (TypedSTerm.ty_exn t) (TypedSTerm.ty_exn u)
  in
  pt, pst, pst_l, (fun () -> TypeInference.Ctx.exit_scope tyctx), unif_ty

(* prelude *)
let () =
  ignore (pstmt_l
    "val term : type.
     val a : term.
     val b : term.
     val c : term.
     val d : term.
     val e : term.
     val f : term -> term -> term.
     val g : term -> term.
     val h : term -> term.
     val ite : term -> term -> term -> term.
     val p : term -> term -> prop.
     val q : term -> prop.
     val r : term -> prop.
     val s : prop.
     val f_ho2: (term -> term ) -> (term -> term) -> term.
     val g_ho: (term -> term -> term) -> term.
     val p_ho2: (term -> term ) -> (term -> term) -> prop.
     val a_poly : pi a. a -> a.
     val f_poly : pi a b. (a -> b) -> (a -> b) -> a.
   ")

let tyctx = T.Conv.create()

(* parse Term.t *)
let pterm_ =
  fun ?ty s ->
    let t = psterm s in
    let ty = CCOpt.map psterm ty in
    CCOpt.iter (fun ty -> TypedSTerm.unify ty (TypedSTerm.ty_exn t)) ty;
    T.Conv.of_simple_term_exn tyctx t

let pterm ?ty s =
  try pterm_ ?ty s
  with e ->
    Format.printf "%s@." (Util.err_spf "pterm %s" s);
    raise e

(* parse two terms of same type *)
let pterm2 =
  fun ?(unif_types=true) ?ty s1 s2 ->
    let t1 = psterm s1 in
    let t2 = psterm s2 in
    if unif_types then (
      unif_ty t1 t2;
    );
    let ty = CCOpt.map psterm ty in
    CCOpt.iter (fun ty -> TypedSTerm.unify ty (TypedSTerm.ty_exn t1)) ty;
    CCOpt.iter (fun ty -> TypedSTerm.unify ty (TypedSTerm.ty_exn t2)) ty;
    T.Conv.of_simple_term_exn tyctx t1,
    T.Conv.of_simple_term_exn tyctx t2

module Task : sig
  type t
  val mk_unif : ?negated:bool -> ?unif_types:bool -> ?with_ty:string -> string -> string -> t
  val set_with_ty : string -> t -> t
  val set_unif_types : bool -> t -> t
  val is_negated : t -> bool
  val pp : t CCFormat.printer
  val parse : t -> T.t * T.t
end = struct
  type t =
    | Unif of {
        t1: string;
        t2: string;
        unif_types: bool;
        with_ty: string option;
        negated: bool;
      }

  let mk_unif ?(negated=false) ?(unif_types=true) ?with_ty t1 t2 : t =
    Unif {t1;t2;unif_types; with_ty; negated}

  let set_with_ty ty = function
    | Unif r -> Unif {r with with_ty=Some ty}

  let set_unif_types b = function
    | Unif r -> Unif {r with unif_types=b}

  let is_negated = function
    | Unif {negated; _} -> negated

  let pp out = function
    | Unif {t1; t2; with_ty=None; _} -> Format.fprintf out "(%s, %s)" t1 t2
    | Unif {t1; t2; with_ty=Some ty; _} -> Format.fprintf out "(%s, %s) : %s" t1 t2 ty

  let parse_ = function
    | Unif {with_ty; t1; t2; unif_types; _} -> pterm2 ~unif_types ?ty:with_ty t1 t2

  let parse p =
    try parse_ p
    with e ->
      print_endline (Util.err_spf "cannot parse/typecheck pair %a@." pp p);
      raise e
end

let check_variant ?(msg="") t u =
  if Unif.FO.are_variant t u then ()
  else (
    Alcotest.failf
      "@[<2>`%a`@ and `%a`@ should be variant@,%s@]@."
        T.ZF.pp t T.ZF.pp u msg
  )

let check_matches ?(msg="") t u =
  if Unif.FO.matches ~pattern:t u then ()
  else (
    Alcotest.failf
      "@[<2>`%a`@ should match@ `%a`%s@]@."
        T.ZF.pp t T.ZF.pp u msg
  )

let check_eq ?(msg="check eq") t1 t2 =
  Alcotest.(check t_test) msg t1 t2

let unifier2 t u =
    let subst = Unif.FO.unify_syn (t,0)(u,1) in
    let renaming = Subst.Renaming.create() in
    Subst.FO.apply renaming subst (t,0) |> Lambda.snf,
    Subst.FO.apply renaming subst (u,1) |> Lambda.snf,
    renaming,
    subst

let unifier t u =
  let t', u', _, _ = unifier2 t u in
  Alcotest.(check t_test) "check unified versions are equal" t' u';
  t'

let check_unifiable ?(negated=false) t u : unit Alcotest.test_case =
  "check unifiable", `Quick, fun () ->
    try
      let _ = unifier2 t u in
      if negated then (
        Alcotest.failf
         "@[<2>`%a`[0]@ and `%a`[1]@ should not be unifiable@]@."
            T.ZF.pp t T.ZF.pp u
      )
    with Unif.Fail ->
      if not negated then (
        Alcotest.failf "@[<2>`%a`[0]@ and `%a`[1]@ should be unifiable@]@."
            T.ZF.pp t T.ZF.pp u
      )

let check_unify_correct t u =
  "check unify is correct", `Quick, fun() ->
    let t', u', _, _ = unifier2 t u in
    let msg = Fmt.sprintf "(@[unify_correct `%a`@ `%a`@])" T.ZF.pp t T.ZF.pp u in
    check_eq ~msg t' u'

let check_unifier t u ~res =
  "check unifier", `Quick, fun () ->
    let t' = unifier t u in
    let msg = Fmt.sprintf "(@[unify `%a`@ `%a`@ :gives `%a`@])" T.ZF.pp t T.ZF.pp u T.ZF.pp res in
    check_variant ~msg t' res

let check_unifier_matches t u =
  "check unifier matches unified terms", `Quick, fun () ->
    let t' = unifier t u in
    let msg = Fmt.sprintf "(@[unify_matches `%a`@ `%a`@])" T.ZF.pp t T.ZF.pp u in
    check_matches ~msg t t';
    check_matches ~msg u t'

let check_same t u t1 sc1 t2 sc2 =
  "check unify makes same", `Quick, fun () ->
    let _, _, renaming, subst = unifier2 t u in
    let t1 = Subst.FO.apply renaming subst (t1,sc1) |> Lambda.snf in
    let t2 = Subst.FO.apply renaming subst (t2,sc2) |> Lambda.snf in
    let msg = Fmt.sprintf
        "(@[<h>unify `%a`@ `%a`@ :makes-eq @[`%a`[%d]@ and `%a`[%d]@]@])"
      T.ZF.pp t T.ZF.pp u T.ZF.pp t1 sc1 T.ZF.pp t2 sc2 in
    check_eq ~msg t1 t2

module Action : sig
  type 'a t = private
    | Yield of {t: 'a ; ty: 'a option}
    | Eq of {t1: 'a; sc1:int; t2: 'a; sc2: int; ty: 'a option}

  val yield : string -> string t
  val eq : string -> int -> string -> int -> string t
  val set_with_ty : 'a -> 'a t -> 'a t
  val parse : string t -> T.t t
  val check : T.t -> T.t -> T.t t -> unit Alcotest.test_case
end = struct
  type 'a t =
    | Yield of {t: 'a ; ty: 'a option}
    | Eq of {t1: 'a; sc1:int; t2: 'a; sc2: int; ty: 'a option}

  let eq t1 sc1 t2 sc2 = Eq{t1;t2;sc1;sc2;ty=None}
  let yield t = Yield{t; ty=None}

  let set_with_ty ty = function
    | Yield r -> Yield {r with ty=Some ty}
    | Eq r -> Eq {r with ty=Some ty}

  (* parse action *)
  let parse : string t -> T.t t = function
    | Yield r ->
      let t = pterm ?ty:r.ty r.t in
      Yield {t; ty=None}
    | Eq r ->
      let t1, t2 = pterm2 ~unif_types:false ?ty:r.ty r.t1 r.t2 in
      Eq {t1; t2; sc1=r.sc1; sc2=r.sc2; ty=None}

  let check t u a = match a with
    | Yield {t=res;_} -> check_unifier t u ~res
    | Eq {t1;t2;sc1;sc2;_} -> check_same t u t1 sc1 t2 sc2
end

let suite_unif1 : unit Alcotest.test_case list =
  let (=?=) a b = Task.mk_unif a b in (* unif pair *)
  let (<?>) a b = Task.mk_unif ~negated:true a b in (* unif pair *)
  let (>->) a b = Task.set_with_ty b a in (* specify return type *)
  let (>?->) a b = Action.set_with_ty b a in (* specify return type *)
  let mk_tests (pair,actions) =
    let t, u = Task.parse pair in
    let actions = List.map Action.parse actions in
    clear_scope();
    if Task.is_negated pair then
      check_unifiable ~negated:true t u ::
      List.map (Action.check t u) actions
    else (
      check_unifiable t u ::
      check_unify_correct t u ::
      check_unifier_matches t u ::
      List.map (Action.check t u) actions
    )
  in
  CCList.flat_map mk_tests
    [ "f X b" =?= "f a Y", [
          Action.yield "f a b";
          Action.eq "X" 0 "a" 0;
          Action.eq "Y" 1 "b" 0;
        ];
      "F a" =?= "f a (g (g a))", [
        Action.yield "f a (g (g a))";
        Action.eq "F" 0 "fun (x:term). f x (g (g x))" 0;
      ];
      ("fun (x y:term). F x" =?= "fun x y. G x y") >-> "term -> term -> term", [
        Action.yield "fun x y. H x" >?-> "term -> term -> term";
        Action.eq "G" 1 "fun x y. F x" 0 >?-> "term -> term -> term";
      ];
      ("fun (x y z:term). F x" =?= "fun x y z. G x y z") >-> "term -> term -> term -> term", [
        Action.yield "fun x y z. H x" >?-> "term -> term -> term -> term";
        Action.eq "G" 1 "fun x y z. F x" 0 >?-> "term -> term -> term -> term";
      ];
      ("X" =?= "(fun Y. X1) (fun (x y:term). c)") >-> "term", [
        Action.yield "Y" >?-> "term";
      ];
      ("p_ho2 (fun a. F1 a) (fun a. F2 a)" =?= "p_ho2 (fun a. G a) (fun a. G a)"), [
        Action.yield "p_ho2 (fun a. G a) (fun a. G a)";
        Action.eq "F1" 0 "G" 1 >?-> "term -> term";
        Action.eq "F2" 0 "G" 1 >?-> "term -> term";
      ];
      ("p_ho2 (fun Y0. d) (fun Y0. F1 Y0)" =?=
       "p_ho2 (fun Y0. d) (fun Y0. (f_ho2 (fun Y1. Y1) (fun Y2. X)))"), [
      ];
      ("f (f a b) X" =?= "F1 (f_poly A1 A2 F1 F2)") |> Task.set_unif_types false, [
        Action.eq "f (f a b)" 0 "F1" 1;
         Action.yield "f (f a b) (f_poly _ _ (f (f a b)) F_renamed)";
        (* FIXME
        Action.eq "X" 1 "f_poly _ _ (f (f a b)) F2" 0;
           *)
      ];
      ( "F (g_ho F)" <?> "a_poly A") |> Task.set_unif_types false, [];
    ]

let reg_matching1 = "regression matching", `Quick, fun () ->
  let t1, t2 =
    pterm "p_ho2 (fun a. F a) (fun a. F a)",
    pterm "p_ho2 (fun a. G a) (fun a. H a)"
  in
  try
    let _ = Unif.FO.matching ~pattern:(t1,0) (t2,1) in
    Alcotest.failf
      "@[<hv>`%a`@ and `%a@ should not match@]" T.ZF.pp t1 T.ZF.pp t2
  with Unif.Fail -> ()


(** Jensen-Pietrzykowski Unification tests *)
let test_jp_unif = "JP unification", `Quick, fun () ->
  Printexc.record_backtrace true;
  CCFormat.set_color_default true;
  Util.set_debug 1;
  InnerTerm.show_type_arguments := true;

  (** Find disagreement tests *)

  OUnit.assert_equal 
    (JP_unif.find_disagreement (pterm "g (g a)") (pterm "g (h a)")) 
    (Some ((pterm "g a", pterm "h a"), []));

  OUnit.assert_equal 
    (JP_unif.find_disagreement (pterm "g (g a)") (pterm "g (g b)")) 
    (Some ((pterm "a", pterm "b"), []));
  
  OUnit.assert_equal 
    (JP_unif.find_disagreement (pterm "f_ho2 (fun (x:term). x)") (pterm "f_ho2 (fun (x:term). a)")) 
    (Some ((T.bvar ~ty:(Type.Conv.of_simple_term_exn (Type.Conv.create ()) (psterm "term")) 0, pterm "a"), []));

  (** Rule tests *)

  let term = pterm ~ty:"term" "X a b" in
  let result = 
    JP_unif.project_onesided term 
    |> OSeq.map (fun subst -> Lambda.snf (Subst.FO.apply S.Renaming.none subst (term,0)))
    |> OSeq.to_list in
  let expected = [pterm "a"; pterm "b"] in
  OUnit.assert_equal expected result;

  let term1 = pterm ~ty:"term" "X a b" in
  let term2 = pterm "f c d" in
  let results = 
    JP_unif.imitate term1 term2 []
    |> OSeq.map (fun subst -> Lambda.snf (Subst.FO.apply S.Renaming.none subst (term1,0)))
    |> OSeq.to_array in
  OUnit.assert_equal 1 (Array.length results);
  check_variant (results.(0)) (pterm ~ty:"term" "f (X0 a b) (Y0 a b)");

  let term1 = pterm ~ty:"term" "X a b" in
  let term2 = pterm ~ty:"term" "Y c d" in
  let substs = JP_unif.identify term1 term2 [] in
  OUnit.assert_equal 1 (OSeq.length substs);
  let subst = OSeq.nth 0 substs in
  let result1 = Lambda.snf (Subst.FO.apply S.Renaming.none subst (term1,0)) in
  let result2 = Lambda.snf (Subst.FO.apply S.Renaming.none subst (term2,0)) in
  check_variant (result1) 
    (T.app (pterm ~ty:"term -> term -> term -> term -> term" "X1") 
      [pterm "a"; pterm "b";pterm ~ty:"term" "Y1 a b"; pterm ~ty:"term" "Z1 a b"]);
  check_variant (result2) 
    (T.app (pterm ~ty:"term -> term -> term -> term -> term" "X1") 
      [pterm ~ty:"term" "Y1 c d"; pterm ~ty:"term" "Z1 c d"; pterm "c"; pterm "d"]);

  (** Unification tests *)

  let term1 = pterm ~ty:"term" "X2 a" in
  let term2 = pterm ~ty:"term" "Y2 b" in
  OUnit.assert_equal 17 (OSeq.length (JP_unif.unify_nonterminating term1 term2));

  let term1 = pterm ~ty:"term" "X3 a" in
  let term2 = pterm ~ty:"term" "g (X3 a)" in
  OUnit.assert_bool "all None" (OSeq.for_all CCOpt.is_none (OSeq.take 20 (JP_unif.unify term1 term2)));

  let term1 = pterm ~ty:"term" "(g (x4 a))" in
  let term2 = pterm ~ty:"term" "(x4 (g a))" in
  let substs = JP_unif.unify term1 term2 in
  OUnit.assert_bool "Unif exists" (OSeq.exists (fun subst ->
    match subst with
    | None -> false
    | Some s ->
      let expected = pterm ~ty:"term" "g (g (g (g a)))" in
      let result = Lambda.snf (Subst.FO.apply S.Renaming.none s (term1,0)) in
      Unif.FO.are_variant expected result
  ) substs);

  (* Example 3 in the Jensen-Pietrzykowski paper *)
  (* Small hack: I added "(fun (x : term). x)" to declare the types of y5 and x5 *)
  let term1 = Lambda.snf (pterm ~ty:"term" "z5 (fun (zz : term). (fun (x : term). x) (y5 zz)) ((fun (x : term). x) x5)") in
  let term2 = Lambda.snf (pterm ~ty:"term" "z5 (fun (zz : term). zz) (g a)") in
  let substs = JP_unif.unify term1 term2 in
  OUnit.assert_bool "Unif exists" (OSeq.exists (fun subst -> 
    match subst with
    | None -> false
    | Some s ->
      Unif.FO.are_variant (Lambda.snf (Subst.FO.apply S.Renaming.none s (pterm "y5",0))) (pterm "g") &&
      Unif.FO.are_variant (Lambda.snf (Subst.FO.apply S.Renaming.none s (pterm "x5",0))) (pterm "a") &&
      Unif.FO.are_variant (Lambda.snf (Subst.FO.apply S.Renaming.none s (pterm "z5",0)))
        (pterm ~ty:"(term -> term) -> term -> term" "fun (z : term -> term). fun (x : term). x6 (z x)")
  ) substs);

  (* Iterate on head of disagreement pair *)
  let term1 = pterm ~ty:"term" "x9 g" in
  let term2 = pterm "g a" in
  let substs = JP_unif.unify term1 term2 in
  OUnit.assert_bool "Unif exists" (OSeq.exists (fun subst ->
    match subst with
    | None -> false
    | Some s ->
      let expected = pterm ~ty:"(term -> term) -> term" "fun z. z a" in
      let result = Lambda.snf (Subst.FO.apply S.Renaming.none s (pterm "x9",0)) in
      Unif.FO.are_variant expected result
  ) substs);

  (* Polymorphism *)

  let term1 = pterm "fun (x7 : alpha). x7" in
  let term2 = pterm "fun (x7 : term). x7" in
  let substs = JP_unif.unify_nonterminating term1 term2 in
  OUnit.assert_equal 1 (OSeq.length substs);
  let subst = OSeq.nth 0 substs in
  check_variant term2 (Subst.FO.apply S.Renaming.none subst (term1,0));

  let term1 = pterm "f_ho2 (a_poly term) (a_poly term)" in
  let term2 = pterm "f_ho2 x8 x8" in
  let substs = JP_unif.unify_nonterminating term1 term2 in
  OUnit.assert_equal 1 (OSeq.length substs);
  let subst = OSeq.nth 0 substs in
  check_variant term1 (Subst.FO.apply S.Renaming.none subst (term2,0));

  ()

let suite_unif2 = [ reg_matching1; test_jp_unif ]

let suite = suite_unif1 @ suite_unif2


(** {2 Properties} *)

let (==>) = QCheck.(==>)

let gen_fo = ArTerm.default
let gen_t = ArTerm.default_ho

let check_unify_gives_unifier =
  let gen = QCheck.(pair gen_t gen_t) in
  let name = "unify_gives_unifier" in
  let prop (t1, t2) =
    try
      let subst = Unif.FO.unify_syn (t1,0) (t2,1) in
      let renaming = S.Renaming.create () in
      let t1' = S.FO.apply renaming subst (t1,0) |> Lambda.snf in
      let t2' = S.FO.apply renaming subst (t2,1) |> Lambda.snf in
      if T.equal t1' t2' then true
      else QCheck.Test.fail_reportf
          "subst=%a,@ t1'=`%a`,@ t2'=`%a`" Subst.pp subst T.ZF.pp t1' T.ZF.pp t2'
    with Unif.Fail -> QCheck.assume_fail()
  in
  QCheck.Test.make ~long_factor:20 ~count:15_000 ~name gen prop

(* σ=mgu(t1,t2) means t1,t2 both match t1σ (== t2σ). In practice, with
   our matching, it only works for FO terms *)
let check_unifier_matches =
  let gen = QCheck.(pair gen_fo gen_fo) in
  let name = "unifier_matches_unified_terms" in
  let prop (t1, t2) =
    try
      let subst = Unif.FO.unify_syn (t1,0) (t2,1) in
      let renaming = S.Renaming.create () in
      let t1' = S.FO.apply renaming subst (t1,0) |> Lambda.snf in
      let t2' = S.FO.apply renaming subst (t2,1) |> Lambda.snf in
      if Unif.FO.matches ~pattern:t1 t1' &&
         Unif.FO.matches ~pattern:t2 t2'
      then true
      else ( QCheck.Test.fail_reportf
          "(@[<hv2>subst=%a,@ t1'=`%a`,@ t2'=`%a`@])"
          Subst.pp subst T.ZF.pp t1' T.ZF.pp t2'
      )
    with Unif.Fail -> QCheck.assume_fail()
  in
  QCheck.Test.make ~long_factor:20 ~count:15_000 ~name gen prop

let check_unify_makes_eq  =
  let gen = QCheck.(pair gen_t gen_t) in
  let name = "unify_makes_eq" in
  let prop (t1, t2) =
    try
      let subst = Unif.FO.unify_syn (t1,0) (t2,1) in
      if Unif.FO.equal ~subst (t1,0) (t2,1) then true
      else QCheck.Test.fail_reportf
          "subst=%a,@ t1=`%a`,@ t2=`%a`" Subst.pp subst T.ZF.pp t1 T.ZF.pp t2
    with Unif.Fail -> QCheck.assume_fail()
  in
  QCheck.Test.make ~long_factor:20 ~count:15_000 ~name gen prop

let check_equal =
  let gen = gen_t in
  let name = "unif_term_self_equal" in
  let prop t =
    Unif.FO.equal ~subst:Subst.empty (t,0) (t,0)
  in
  QCheck.Test.make ~long_factor:20 ~count:2_000 ~name gen prop

let check_variant =
  let gen = gen_fo in
  let name = "unif_term_self_variant" in
  let prop t =
    let renaming = S.Renaming.create () in
    let t' = S.FO.apply renaming S.empty (t,0) in
    Unif.FO.are_variant t t'
  in
  QCheck.Test.make ~long_factor:20 ~count:2_000 ~name gen prop

let check_variant2 =
  let gen = gen_t in
  let name = "unif_term_variant_sound" in
  let prop (t0,t1) =
    try
      let subst = Unif.FO.variant (t0,0)(t1,1) in
      (* check they are really variants *)
      let renaming = Subst.Renaming.create() in
      let t0' = Subst.FO.apply renaming subst (t0,0) |> Lambda.snf in
      let t1' = Subst.FO.apply renaming subst (t1,1) |> Lambda.snf in
      T.equal t0' t1'
    with Unif.Fail -> QCheck.assume_fail ()
  in
  QCheck.Test.make ~long_factor:20 ~name (Q.pair gen gen) prop

let check_variant_sym =
  let gen = gen_t in
  let name = "unif_term_variant_sym" in
  let prop (t0,t1) =
    Unif.FO.are_variant t0 t1 = Unif.FO.are_variant t1 t0
  in
  QCheck.Test.make ~long_factor:20 ~name (Q.pair gen gen) prop

let check_matching =
  let gen = QCheck.pair gen_t gen_t in
  let name = "unif_matching_gives_matcher" in
  let prop (t1, t2) =
    try
      let subst = Unif.FO.matching ~pattern:(t1,0) (t2,1) in
      let renaming = S.Renaming.create () in
      let t1' = S.FO.apply renaming subst (t1,0) |> Lambda.snf in
      let t2' = S.FO.apply renaming subst (t2,1) |> Lambda.snf in
      if T.equal t1' t2'
      then true
      else QCheck.Test.fail_reportf "@[<v>subst=%a,@ t1'=`%a`,@ t2'=`%a`@]"
          Subst.pp subst T.ZF.pp t1' T.ZF.pp t2'
    with Unif.Fail -> QCheck.assume_fail()
  in
  QCheck.Test.make ~long_factor:20 ~count:1000 ~name gen prop

let check_matching_variant =
  let gen = QCheck.pair gen_t gen_fo in
  let name = "unif_matching_preserves_rhs" in
  let prop (t1, t2) =
    try
      let subst = Unif.FO.matching ~pattern:(t1,0) (t2,1) in
      let renaming = S.Renaming.create () in
      let t2' = S.FO.apply renaming subst (t2,1) |> Lambda.snf in
      if Unif.FO.are_variant t2 t2'
      then true
      else QCheck.Test.fail_reportf "@[<v>subst=%a,@ t2'=`%a`@]"
          Subst.pp subst T.ZF.pp t2'
    with Unif.Fail -> QCheck.assume_fail()
  in
  QCheck.Test.make ~long_factor:20 ~count:1000 ~name gen prop

let check_matching_variant_same_scope =
  let gen = QCheck.pair gen_t gen_fo in
  let name = "unif_matching_same_scope_preserves_rhs" in
  let prop (t1, t2) =
    try
      let subst = Unif.FO.matching_same_scope ~scope:0 ~pattern:t1 t2 in
      let t2' = S.FO.apply Subst.Renaming.none subst (t2,0) |> Lambda.snf in
      if Unif.FO.are_variant t2 t2'
      then true
      else QCheck.Test.fail_reportf "@[<v>subst=%a,@ t2'=`%a`@]"
          Subst.pp subst T.ZF.pp t2'
    with Unif.Fail -> QCheck.assume_fail()
  in
  QCheck.Test.make ~long_factor:20 ~count:1000 ~name gen prop

let check_variant_bidir_match =
  let gen = gen_t in
  let name = "unif_term_variant_bidir_match" in
  let prop (t0,t1) =
    if Unif.FO.are_variant t0 t1
    then Unif.FO.matches ~pattern:t0 t1 && Unif.FO.matches ~pattern:t1 t0
    else QCheck.assume_fail()
  in
  QCheck.Test.make ~long_factor:20 ~name (Q.pair gen gen) prop

let check_lits_variant_bidir_match =
  let gen = ArLiteral.clause in
  let name = "unif_lits_variant_bidir_match" in
  let prop (lits0,lits1) =
    if Literals.are_variant lits0 lits1
    then Literals.matches lits0 lits1 && Literals.matches lits1 lits0
    else QCheck.assume_fail()
  in
  QCheck.Test.make ~long_factor:20 ~count:5_000 ~name (Q.pair gen gen) prop

let check_ho_unify_gives_unifiers =
  let gen = QCheck.(pair gen_t gen_t) in
  let name = "ho_unify_gives_unifiers" in
  let prop (t1, t2) =
    let offset =
      Sequence.doubleton t1 t2
      |> Sequence.flat_map T.Seq.vars
      |> T.Seq.max_var |> succ
    in
    (* only keep proper solutions *)
    let l =
      HO_unif.unif_pairs ~fuel:20 ~offset ([[],t1,t2],0)
      |> List.filter
        (fun (pairs,us,_,_) -> pairs=[] && not (Unif_subst.has_constr us))
    in
    if l=[] then QCheck.assume_fail()
    else (
      List.iter
        (fun (_,us,_,_) ->
           let subst = Unif_subst.subst us in
           let renaming = Subst.Renaming.create() in
           let u1 = Subst.FO.apply renaming subst (t1,0) |> Lambda.snf in
           let u2 = Subst.FO.apply renaming subst (t2,0) |> Lambda.snf in
           if not (T.equal u1 u2) then (
             QCheck.Test.fail_reportf
               "(@[<hv2>bad solution@ t1'=`%a`@ t2'=`%a`@ :subst %a@])"
               T.ZF.pp u1 T.ZF.pp u2 Subst.pp subst
           ))
        l;
      true
    )
  in
  QCheck.Test.make ~long_factor:20 ~count:8_000 ~name gen prop

(* TODO: generate random Literals.t, then check [variant a b <=> (matches a b && matches b a)] *)

let props =
  [ check_unify_gives_unifier;
    check_unify_makes_eq;
    check_unifier_matches;
    check_equal;
    check_variant;
    check_variant2;
    check_variant_sym;
    check_variant_bidir_match;
    check_lits_variant_bidir_match;
    check_matching;
    check_matching_variant;
    check_matching_variant_same_scope;
    check_ho_unify_gives_unifiers;
  ]
