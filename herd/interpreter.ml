(*********************************************************************)
(*                        Herd                                       *)
(*                                                                   *)
(* Luc Maranget, INRIA Paris-Rocquencourt, France.                   *)
(* Jade Alglave, University College London, UK.                      *)
(* John Wickerson, Imperial College London, UK.                      *)
(*                                                                   *)
(*  Copyright 2013 Institut National de Recherche en Informatique et *)
(*  en Automatique and the authors. All rights reserved.             *)
(*  This file is distributed  under the terms of the Lesser GNU      *)
(*  General Public License.                                          *)
(*********************************************************************)

(** Interpreter for a user-specified model *)

open Printf


module type S = sig

  module S : Sem.Semantics

(* Values *)
  type ks =
      { id : S.event_rel Lazy.t; unv : S.event_rel Lazy.t;
        evts : S.event_set;  conc : S.concrete; }

  module V : sig type env type v val universe : v end


(* Helpers, initialisation *)
  val env_empty : V.env
  val add_rels : V.env -> (string * S.event_rel Lazy.t) list -> V.env
  val add_sets : V.env -> (string * S.event_set Lazy.t) list -> V.env
  val add_vs : V.env -> (string * V.v Lazy.t) list -> V.env

(* State of interpreter *)

  type st = {
      env : V.env ;
      show : S.event_rel StringMap.t Lazy.t ;
      skipped : StringSet.t ;
      silent : bool ; undef : bool;
      ks : ks ;
      bell_info : BellCheck.info ;
      stack : TxtLoc.t list;
  }


  val show_to_vbpp :
    st -> (StringMap.key * S.event_rel) list

  val interpret :
    S.test ->
    ks ->
    V.env ->
    (string * S.event_rel) list Lazy.t ->
    (st -> 'a -> 'a) -> 'a -> 'a

end


module type Config = sig
  val m : AST.pp_t
  val bell : bool (* executing bell file *)
  val bell_fname : string option (* name of bell file if present *)
  include Model.Config
end

module Make
    (O:Config)
    (S:Sem.Semantics)
    :
    (S with module S = S)
    =
  struct

    let _dbg = false

(****************************)
(* Convenient abbreviations *)
(****************************)

    module S = S
    module A = S.A
    module E = S.E
    module U = MemUtils.Make(S)
    module MU = ModelUtils.Make(O)(S)
    module W = Warn.Make(O)


(*  Model interpret *)
    let (txt,(_,_,prog)) = O.m

(*
  mutable association lists for gathering bell information.
  This could also be passed around, this seems like the least
  intrusive method for now. When integrated, it can be discussed
  what we really do with it.
 *)

    let _debug_proc chan p = fprintf chan "%i" p
    let debug_event chan e = fprintf chan "%s" (E.pp_eiid e)
    let debug_set chan s =
      output_char chan '{' ;
      E.EventSet.pp chan "," debug_event s ;
      output_char chan '}'

    let debug_rel chan r =
      E.EventRel.pp chan ","
        (fun chan (e1,e2) -> fprintf chan "%a -> %a"
            debug_event e1 debug_event e2)
        r

    type ks =
        { id : S.event_rel Lazy.t; unv : S.event_rel Lazy.t;
          evts : S.event_set; conc : S.concrete; }

(* Internal typing *)
    type typ =
      | TEmpty | TEvents | TRel | TTag of string |TClo | TProc | TSet of typ
      | TAnyTag

    let rec eq_type t1 t2 = match t1,t2 with
    | TEmpty,TSet _ -> Some t2
    | TSet _,TEmpty -> Some t1
    | TAnyTag,TTag _
    | TTag _,TAnyTag -> Some TAnyTag
    | TTag s1,TTag s2 when s1 <> s2 -> Some TAnyTag
    | TSet t1,TSet t2 ->
        begin match eq_type t1 t2 with
        | None -> None
        | Some t -> Some (TSet t)
        end
    | _,_ -> if t1 = t2 then Some t1 else None


    let type_equal t1 t2 = match eq_type t1 t2 with
    | None -> false
    | Some _ -> true

    exception CompError of string
    exception PrimError of string


    let rec pp_typ = function
      | TEmpty -> "{}"
      | TEvents -> "event set"
      | TRel -> "rel"
      | TTag ty -> ty
      | TAnyTag -> "anytag"
      | TClo -> "closure"
      | TProc -> "procedure"
      | TSet elt -> sprintf "%s set" (pp_typ elt)



(*
  module V = Ivalue.Make(S)
 *)

    module rec V : sig
      type v =
        | Empty | Unv
        | Rel of S.event_rel
        | Set of S.event_set
        | Clo of closure
        | Prim of string * (v list -> v)
        | Proc of procedure
        | Tag of string * string     (* type  X name *)
        | ValSet of typ * ValSet.t   (* elt type X set *)
      and env =
          { vals  : v Lazy.t StringMap.t;
            enums : string list StringMap.t;
            tags  : string StringMap.t; }
      and closure =
          { clo_args : AST.var list ;
            mutable clo_env : env ;
            clo_body : AST.exp;
            clo_name : string; }
      and procedure = {
          proc_args : AST.var list;
          proc_env : env;
          proc_body : AST.ins list; }
      val universe : v
      val type_val : v -> typ
    end = struct

      type v =
        | Empty | Unv
        | Rel of S.event_rel
        | Set of S.event_set
        | Clo of closure
        | Prim of string * (v list -> v)
        | Proc of procedure
        | Tag of string * string     (* type  X name *)
        | ValSet of typ * ValSet.t   (* elt type X set *)

      and env =
          { vals  : v Lazy.t StringMap.t;
            enums : string list StringMap.t;
            tags  : string StringMap.t; }

      and closure =
          { clo_args : AST.var list ;
            mutable clo_env : env ;
            clo_body : AST.exp;
            clo_name : string; }

      and procedure = {
          proc_args : AST.var list;
          proc_env : env;
          proc_body : AST.ins list; }

      let universe = Unv

      let type_val = function
        | Empty -> TEmpty
        | Unv -> assert false (* Discarded before *)
        | Rel _ -> TRel
        | Set _ -> TEvents
        | Clo _|Prim _ -> TClo
        | Proc _ -> TProc
        | Tag (t,_) -> TTag t
        | ValSet (t,_) -> TSet t


    end
    and ValOrder : Set.OrderedType = struct
      (* Note: cannot use Full in sets.. *)
      type t = V.v
      open V

      let error fmt = ksprintf (fun msg -> raise (CompError msg)) fmt


      let compare v1 v2 = match v1,v2 with
      | V.Empty,V.Empty -> 0
(* Expand all legitimate empty's *)
      | V.Empty,ValSet (_,s) -> ValSet.compare ValSet.empty s
      | ValSet (_,s),V.Empty -> ValSet.compare s ValSet.empty
      | V.Empty,Rel r -> E.EventRel.compare E.EventRel.empty r
      | Rel r,V.Empty -> E.EventRel.compare r E.EventRel.empty
      | V.Empty,Set s -> E.EventSet.compare E.EventSet.empty s
      | Set s,V.Empty -> E.EventSet.compare s E.EventSet.empty
(* Legitimate cmp *)
      | Tag (_,s1), Tag (_,s2) ->
          String.compare s1 s2
      | ValSet (_,s1),ValSet (_,s2) -> ValSet.compare s1 s2
      | Rel r1,Rel r2 -> E.EventRel.compare r1 r2
      | Set s1,Set s2 -> E.EventSet.compare s1 s2
(* Errors *)
      | (Unv,_)|(_,Unv) -> error "Universe in compare"
      | _,_ ->
          let t1 = V.type_val v1
          and t2 = V.type_val v2 in
          if type_equal t1 t2 then
            error "Sets of %s are illegal" (pp_typ t1)
          else
            error
              "Heterogeneous set elements: types %s and %s "
              (pp_typ t1) (pp_typ t2)

    end and ValSet : (MySet.S with type elt = V.v) = MySet.Make(ValOrder)


    let error silent loc fmt =
      ksprintf
        (fun msg ->
          if O.debug || not silent then eprintf "%a: %s\n" TxtLoc.pp loc msg ;
          raise Misc.Exit) (* Silent failure *)
        fmt

    let warn loc fmt =      
      ksprintf
        (fun msg ->
          Warn.warn_always "%a: %s" TxtLoc.pp loc msg)
        fmt

    let pp_failure test conc msg vb_pp =
      MU.pp_failure test conc msg vb_pp

    open V

(* pretty *)
    let pp_type_val v = pp_typ (type_val v)

    let rec pp_val = function
      | Unv -> "<universe>"
      | V.Empty -> "{}"
      | Tag (_,s) -> sprintf "'%s" s
      | ValSet (_,s) ->
          sprintf "{%s}" (ValSet.pp_str "," pp_val s)
      | v -> sprintf "<%s>" (pp_type_val v)

(* lift a tag to a singleton set *)
    let tag2set v = match v with
    | Tag (t,_) -> ValSet (TTag t,ValSet.singleton v)
    | _ -> v


(* Add values to env *)
    let add_val k v env =
      { env with vals = StringMap.add k v env.vals; }

    let env_empty =
      {vals=StringMap.empty;
       enums=StringMap.empty;
       tags=StringMap.empty; }

    let add_vals mk env bds =
      let vals =
        List.fold_left
          (fun vals (k,v) -> StringMap.add k (mk v) vals)
          env.vals bds in
      { env with vals; }


    let add_rels env bds =
      add_vals (fun v -> lazy (Rel (Lazy.force v))) env bds

    and add_sets env bds =
      add_vals (fun v -> lazy (Set (Lazy.force v))) env bds

    and add_vs env bds =
      add_vals (fun v -> v) env bds

    and add_prims env bds =
      let bds =
        List.map (fun (k,f) -> k,Prim (k,f)) bds in
      add_vals (fun v -> lazy v) env bds

    type st = {
        env : V.env ;
        show : S.event_rel StringMap.t Lazy.t ;
        skipped : StringSet.t ;
        silent : bool ; undef : bool ;
        ks : ks ;
        bell_info : BellCheck.info ;
        stack : TxtLoc.t list;
      }

    let push_loc st loc = { st with stack = loc :: st.stack; }
    let pop_loc st = match st.stack with
    | [] -> assert false
    | _::stack -> { st with stack; }

    let protect_call st f x =
      try f x
      with Misc.Exit ->
        List.iter
          (fun loc ->
            if O.debug || not st.silent then
              eprintf "%a: Calling procedure\n" TxtLoc.pp loc)
          st.stack ;
        raise Misc.Exit

(* Type of eval env *)
    module EV = struct
      type env =
          { env : V.env ; silent : bool; ks : ks; }
    end
    let from_st st = { EV.env=st.env; silent=st.silent; ks=st.ks; }

    let set_op env loc t op s1 s2 =
      try V.ValSet (t,op s1 s2)
      with CompError msg -> error env.EV.silent loc "%s" msg

    let tags_universe {enums=env} t =
      let tags =
        try StringMap.find t env
        with Not_found -> assert false in
      let tags = ValSet.of_list (List.map (fun s -> Tag (t,s)) tags) in
      tags

    let find_env {vals=env} k =
      Lazy.force begin
        try StringMap.find k env
        with
        | Not_found -> Warn.user_error "unbound var: %s" k
      end

    let find_env_loc loc env k =
      try  find_env env.EV.env k
      with Misc.UserError msg -> error env.EV.silent loc "%s" msg

(* find without forcing lazy's *)
    let just_find_env fail loc env k =
      try StringMap.find k env.EV.env.vals
      with Not_found ->
        if fail then error env.EV.silent loc "unbound var: %s" k
        else raise Not_found

    let as_rel ks = function
      | Rel r -> r
      | Empty -> E.EventRel.empty
      | Unv -> Lazy.force ks.unv
      | v ->
          eprintf "not a relation: '%s'\n" (pp_val v) ;
          assert false

    let as_set ks = function
      | Set s -> s
      | Empty -> E.EventSet.empty
      | Unv -> ks.evts
      | _ -> assert false

    let as_valset = function
      | ValSet (_,v) -> v
      | _ -> assert false

    let as_tag = function
      | V.Tag (_,tag) -> tag
      | _ -> assert false

    let as_tags tags =
      let ss = ValSet.fold (fun v k -> as_tag v::k) tags [] in
      StringSet.of_list ss

    exception Stabilised of typ

    let stabilised ks env =
      let rec stabilised vs ws = match vs,ws with
      | [],[] -> true
      | v::vs,w::ws -> begin match v,w with
        | (_,V.Empty)|(Unv,_) -> stabilised vs ws
(* Relation *)
        | (V.Empty,Rel w) -> E.EventRel.is_empty w && stabilised vs ws
        | (Rel v,Unv) ->
            E.EventRel.subset (Lazy.force ks.unv) v && stabilised vs ws
        | Rel v,Rel w ->
            E.EventRel.subset w v && stabilised vs ws
(* Event Set *)
        | (V.Empty,Set w) -> E.EventSet.is_empty w && stabilised vs ws
        | (Set v,Unv) ->
            E.EventSet.subset ks.evts v && stabilised vs ws
        | Set v,Set w ->
            E.EventSet.subset w v && stabilised vs ws
(* Value Set *)
        | (V.Empty,ValSet (_,w)) -> ValSet.is_empty w && stabilised vs ws
        | (ValSet (TTag t,v),Unv) ->
            ValSet.subset (tags_universe env t) v && stabilised vs ws
        | ValSet (_,v),ValSet (_,w) ->
            ValSet.subset w v && stabilised vs ws
        | _,_ ->
            raise (Stabilised (type_val w))

      end
      | _,_ -> assert false in
      stabilised

    open AST

(* check if memory location is in certain memory region *)
    let _mem_region_match target mem_map e =
      let is_mem_map = match mem_map with 
      | Some _ -> true
      | None -> false in
      if not is_mem_map then 
	false
      else
	let mem_map = match mem_map with
	| Some m -> m
	| None -> Warn.fatal "error getting memory map"
	in
	match (E.Act.location_of e.E.action) with
	| Some x -> List.mem (E.Act.A.pp_location x, target) mem_map
	| None -> false
	      



(* Syntactic function *)
    let is_fun = function
      | Fun _ -> true
      | _ -> false


(* Get an expression location *)
    let get_loc = function
      | Konst (loc,_)
      | Tag (loc,_)
      | Var (loc,_)
      | ExplicitSet (loc,_)
      | Op1 (loc,_,_)
      | Op (loc,_,_)
      | Bind (loc,_,_)
      | BindRec (loc,_,_)
      | App (loc,_,_)
      | Fun (loc,_,_,_,_)
      | Match (loc,_,_,_)
      | MatchSet (loc,_,_,_)
      | Try (loc,_,_)
        -> loc

(* Remove transitive edges, except if instructed not to *)
    let rt_loc lbl =
      if
        O.verbose <= 1 &&
        not (StringSet.mem lbl S.O.PC.symetric) &&
        not (StringSet.mem lbl S.O.PC.showraw)
      then S.rt else (fun x -> x)

    let show_to_vbpp st =
      StringMap.fold (fun tag v k -> (tag,v)::k)   (Lazy.force st.show) []

    let empty_rel = Rel E.EventRel.empty
        
    let error_typ silent loc t0 t1  =
      error silent loc"type %s expected, %s found" (pp_typ t0) (pp_typ t1)

    let error_rel silent loc v = error_typ silent loc TRel (type_val v)
(*    and error_set loc v = error_typ loc TEvents (type_val v) *)



(********************************)
(* Helpers for n-ary operations *)
(********************************)

    let type_list silent = function
      | [] -> assert false
      | (_,v)::vs ->
          let rec type_rec t0 = function
            | [] -> t0,[]
            | (loc,v)::vs ->
                let t1 = type_val v in
                match eq_type t0 t1 with
                | Some t0 ->
                    let t0,vs = type_rec t0 vs in
                    t0,v::vs
                | None ->
                    error silent loc
                      "type %s expected, %s found" (pp_typ t0) (pp_typ t1) in
          let t0,vs = type_rec (type_val v) vs in
          t0,v::vs


(* Check explicit set arguments *)
    let set_args silent =
      let rec s_rec = function
        | [] -> []
        | (loc,Unv)::_ ->
            error silent loc "universe in explicit set"
        | x::xs -> x::s_rec xs in
      s_rec

(* Union is polymorphic *)
    let union_args =
      let rec u_rec = function
        | [] -> []
        | (_,V.Empty)::xs -> u_rec xs
        | (_,Unv)::_ -> raise Exit
        | (loc,v)::xs ->
            (loc,tag2set v)::u_rec xs in
      u_rec

(* Sequence applies to relations *)
    let seq_args silent ks =
      let rec seq_rec = function
        | [] -> []
        | (_,V.Empty)::_ -> raise Exit
        | (_,V.Unv)::xs -> Lazy.force ks.unv::seq_rec xs
        | (_,Rel r)::xs -> r::seq_rec xs
        | (loc,v)::_ -> error_rel silent loc v in
      seq_rec

(* Definition of primitives *)
    let arg_mismatch () = raise (PrimError "argument mismatch")

    let partition args = match args with
    | [Set evts] ->
        let r = U.partition_events evts in
        let vs = List.map (fun es -> Set es) r in
        ValSet (TEvents,ValSet.of_list vs)
    | _ -> arg_mismatch ()
          
    and linearisations args = match args with
    | [Set es;Rel r;] ->
        if O.debug then begin
          eprintf "Linearisations:\n" ;
          eprintf "  %a\n" debug_set es ;
          eprintf "  {%a}\n"
            debug_rel
            (E.EventRel.filter
               (fun (e1,e2) ->
                 E.EventSet.mem e1 es && E.EventSet.mem e2 es)
               r)
        end ;
        let rs =
          U.apply_orders es r
            (fun o ->
              let o =
                E.EventRel.filter
                  (fun (e1,e2) ->
                    E.EventSet.mem e1 es && E.EventSet.mem e2 es)
                  o in
              if O.debug then eprintf "  -> FAIL {%a}\n%!" debug_rel o ;
              ValSet.singleton (Rel o))
            (fun o os ->
              if O.debug then eprintf "  -> {%a}\n%!" debug_rel o ;
              ValSet.add (Rel o) os)
            ValSet.empty in
        ValSet (TRel,rs)
    | _ -> arg_mismatch ()

    and tag2scope env args = match args with
    | [V.Tag (_,tag)] ->
        begin try
          let v = Lazy.force (StringMap.find tag env.vals) in
          match v with
          | V.Empty|V.Unv|V.Rel _ ->  v
          | _ ->
          raise
            (PrimError
               (sprintf
                  "value %s is not a relation, found %s"
                  tag  (pp_type_val v)))
              
        with Not_found ->
          raise
            (PrimError (sprintf "cannot find scope instance %s" tag))
        end
    | _ -> arg_mismatch ()

    and tag2events env args = match args with
    | [V.Tag (_,tag)] ->
        let x = BellName.tag2events_var tag in
        begin try
          let v = Lazy.force (StringMap.find x env.vals) in
          match v with
          | V.Empty|V.Unv|V.Set _ ->  v
          | _ ->
          raise
            (PrimError
               (sprintf
                  "value %s is not a set of events, found %s"
                  x  (pp_type_val v)))
              
        with Not_found ->
          raise
            (PrimError (sprintf "cannot find event set %s" x))
        end
    | _ -> arg_mismatch ()

    and domain args = match args with
    | [V.Empty] ->  V.Empty
    | [V.Unv] -> V.Unv
    | [V.Rel r] ->  V.Set (E.EventRel.domain r)
    | _ -> arg_mismatch ()

    and range args = match args with
    | [V.Empty] ->  V.Empty
    | [V.Unv] -> V.Unv
    | [V.Rel r] ->  V.Set (E.EventRel.codomain r)
    | _ -> arg_mismatch ()

    let add_primitives m =
      add_prims m
        [
         "partition",partition;
         "linearisations",linearisations;
         "tag2scope",tag2scope m;
         "tag2events",tag2events m;
         "domain",domain;
         "range",range;
        ]

       
(***************)
(* Interpreter *)
(***************)

(* For all success call kont, accumulating results *)
    let interpret test =

      let rec eval_loc env e = get_loc e,eval env e

      and eval env = function
        | Konst (_,Empty SET) -> V.Empty (* Polymorphic empty *)
        | Konst (_,Empty RLN) -> empty_rel
        | Konst (_,Universe _) -> Unv
        | AST.Tag (loc,s) ->
            begin try
              V.Tag (StringMap.find s env.EV.env.tags,s)
            with Not_found ->
              error env.EV.silent loc "tag '%s is undefined" s
            end
        | Var (loc,k) ->
            find_env_loc loc env k
        | Fun (loc,xs,body,name,fvs) ->
            Clo (eval_fun false env loc xs body name fvs)
(* Unary operators *)
        | Op1 (_,Plus,e) ->
            begin match eval env e with
            | V.Empty -> V.Empty
            | Unv -> Unv
            | Rel r -> Rel (S.tr r)
            | v -> error_rel env.EV.silent (get_loc e) v
            end
        | Op1 (_,Star,e) ->
            begin match eval env e with
            | V.Empty -> Rel (Lazy.force env.EV.ks.id)
            | Unv -> Unv
            | Rel r -> Rel (S.union (S.tr r) (Lazy.force env.EV.ks.id))
            | v -> error_rel env.EV.silent (get_loc e) v
            end
        | Op1 (_,Opt,e) ->
            begin match eval env e with
            | V.Empty -> Rel (Lazy.force env.EV.ks.id)
            | Unv -> Unv
            | Rel r -> Rel (S.union r (Lazy.force env.EV.ks.id))
            | v -> error_rel env.EV.silent (get_loc e) v
            end
        | Op1 (_,Comp,e) -> (* Back to polymorphism *)
            begin match eval env e with
            | V.Empty -> Unv
            | Unv -> V.Empty
            | Set s ->
                Set (E.EventSet.diff env.EV.ks.evts s)
            | Rel r ->
                Rel (E.EventRel.diff (Lazy.force env.EV.ks.unv) r)
            | ValSet (TTag ts as t,s) ->
                ValSet (t,ValSet.diff (tags_universe env.EV.env ts) s)
            | v ->
                error env.EV.silent (get_loc e)
                  "set or relation expected, %s found"
                  (pp_typ (type_val v))
            end
        | Op1 (_,Inv,e) ->
            begin match eval env e with
            | V.Empty -> V.Empty
            | Unv -> Unv
            | Rel r -> Rel (E.EventRel.inverse r)
            | v -> error_rel env.EV.silent (get_loc e) v
            end
(* One xplicit N-ary operator *)
        | ExplicitSet (loc,es) ->
            let vs = List.map (eval_loc env) es in
            let vs = set_args env.EV.silent vs in
            begin match vs with
            | [] -> V.Empty
            | _ ->
                let t,vs = type_list env.EV.silent vs in
                try ValSet (t,ValSet.of_list vs)
                with CompError msg ->
                  error env.EV.silent loc "%s" msg
            end
(* N-ary operators, those associative binary operators are optimized *)
        | Op (loc,Union,es) ->
            let vs = List.map (eval_loc env) es in
            begin try
              let vs = union_args vs in
              match vs with
              | [] -> V.Empty
              | _ ->
                  let t,vs = type_list env.EV.silent vs in
                  match t with
                  | TRel -> Rel (S.unions (List.map (as_rel env.EV.ks) vs))
                  | TEvents ->
                      Set (E.EventSet.unions  (List.map (as_set env.EV.ks) vs))
                  | TSet telt ->
                      ValSet (telt,ValSet.unions (List.map as_valset vs))
                  | ty ->
                      error env.EV.silent loc
                        "cannot perform union on type '%s'" (pp_typ ty)
            with Exit -> Unv end
        | Op (_,Seq,es) ->
            let vs = List.map (eval_loc env) es in
            begin try
              let vs = seq_args env.EV.silent env.EV.ks vs in
              match vs with
              | [] -> Rel (Lazy.force env.EV.ks.id)
              | _ -> Rel (S.seqs vs)
            with Exit -> empty_rel
            end
(* Binary operators *)
        | Op (_loc1,Inter,[e1;Op (_loc2,Cartesian,[e2;e3])])
        | Op (_loc1,Inter,[Op (_loc2,Cartesian,[e2;e3]);e1]) ->
            let r = eval_rel env e1
            and f1 = eval_set_mem env e2
            and f2 = eval_set_mem env e3 in
            let r =
              E.EventRel.filter
                (fun (e1,e2) -> f1 e1 && f2 e2)
                r in
            Rel r              
        | Op (loc,Inter,[e1;e2;]) -> (* Binary notation kept in parser *)
            let loc1,v1 = eval_loc env e1
            and loc2,v2 = eval_loc env e2 in
            begin match tag2set v1,tag2set v2 with
            | (V.Tag _,_)|(_,V.Tag _) -> assert false
            | Rel r1,Rel r2 -> Rel (E.EventRel.inter r1 r2)
            | Set s1,Set s2 -> Set (E.EventSet.inter s1 s2)
            | ValSet (t,s1),ValSet (_,s2) ->
                set_op env loc t ValSet.inter s1 s2
            | (Unv,r)|(r,Unv) -> r
            | (V.Empty,_)|(_,V.Empty) -> V.Empty
            | (Clo _|Prim _|Proc _),_ ->
                error env.EV.silent loc1
                  "intersection on %s" (pp_typ (type_val v1))
            | _,(Clo _|Prim _|Proc _) ->
                error env.EV.silent loc2
                  "intersection on %s" (pp_typ (type_val v2))
            | (Rel _,Set _)
            | (Set _,Rel _)
            | (Rel _,ValSet _)
            | (ValSet _,Rel _) ->
                error env.EV.silent
                  loc "mixing sets and relations in intersection"
            | (ValSet _,Set _)
            | (Set _,ValSet _) ->
                error env.EV.silent
                  loc "mixing event sets and sets in intersection"
            end
        | Op (loc,Diff,[e1;e2;]) ->
            let loc1,v1 = eval_loc env e1
            and loc2,v2 = eval_loc env e2 in
            begin match tag2set v1,tag2set v2 with
            | (V.Tag _,_)|(_,V.Tag _) -> assert false
            | Rel r1,Rel r2 -> Rel (E.EventRel.diff r1 r2)
            | Set s1,Set s2 -> Set (E.EventSet.diff s1 s2)
            | ValSet (t,s1),ValSet (_,s2) ->
                set_op env loc t ValSet.diff s1 s2
            | Unv,Rel r -> Rel (E.EventRel.diff (Lazy.force env.EV.ks.unv) r)
            | Unv,Set s -> Set (E.EventSet.diff env.EV.ks.evts s)
            | Unv,ValSet (TTag ts as t,s) ->
                ValSet (t,ValSet.diff (tags_universe env.EV.env ts) s)
            | Unv,ValSet (t,_) ->
                error env.EV.silent
                  loc1 "cannot build universe for element type %s"
                  (pp_typ t)
            | Unv,V.Empty -> Unv
            | (Rel _|Set _|V.Empty|Unv|ValSet _),Unv
            | V.Empty,(Rel _|Set _|V.Empty|ValSet _) -> V.Empty
            | (Rel _|Set _|ValSet _),V.Empty -> v1
            | (Clo _|Proc _|Prim _),_ ->
                error env.EV.silent loc1
                  "difference on %s" (pp_typ (type_val v1))
            | _,(Clo _|Proc _|Prim _) ->
                error env.EV.silent loc2
                  "difference on %s" (pp_typ (type_val v2))
            | ((Set _|ValSet _),Rel _)|(Rel _,(Set _|ValSet _)) ->
                error env.EV.silent
                  loc "mixing set and relation in difference"
            | (Set _,ValSet _)|(ValSet _,Set _) ->
                error env.EV.silent
                  loc "mixing event set and set in difference"
            end
        | Op (_,Cartesian,[e1;e2;]) ->
            let s1 = eval_set env e1
            and s2 = eval_set env e2 in
            Rel (E.EventRel.cartesian s1 s2)
        | Op (loc,Add,[e1;e2;]) ->
            let v1 = eval env e1
            and v2 = eval env e2 in
            begin match v1,v2 with
            | V.Unv,_ -> error env.EV.silent loc "universe in set ++"
            | _,V.Unv -> V.Unv
            | _,V.Empty -> V.ValSet (type_val v1,ValSet.singleton v1)
            | V.Empty,V.ValSet (TSet e2 as t2,s2) ->
                let v1 = ValSet (e2,ValSet.empty) in
                set_op env loc t2 ValSet.add v1 s2
            | _,V.ValSet (_,s2) ->
                set_op env loc (type_val v1) ValSet.add v1 s2
            | _,(Rel _|Set _|Clo _|Prim _|Proc _|V.Tag (_, _)) ->
                error env.EV.silent (get_loc e2)
                  "this expression of type '%s' should be a set"
                  (pp_typ (type_val v2))
            end
        | Op (_,(Diff|Inter|Cartesian|Add),_) -> assert false (* By parsing *)
(* Application/bindings *)
        | App (loc,f,es) ->
            eval_app loc env (eval env f) (List.map (eval env) es)
        | Bind (_,bds,e) ->
            let m = eval_bds env bds in
            eval { env with EV.env = m;} e
        | BindRec (loc,bds,e) ->
            let m = env_rec env loc (fun pp -> pp) bds in
            eval { env with EV.env=m;} e
        | Match (loc,e,cls,d) ->
            let v = eval env e in
            begin match v with
            | V.Tag (_,s) ->
                let rec match_rec = function
                  | [] ->
                      begin match d with
                      | Some e ->  eval env e
                      | None ->
                          error env.EV.silent
                            loc "pattern matching failed on value '%s'" s
                      end
                  | (ps,es)::cls ->
                      if s = ps then eval env es
                      else match_rec cls in
                match_rec cls
            | V.Empty ->
                error env.EV.silent (get_loc e) "matching on empty"
            | V.Unv ->
                error env.EV.silent (get_loc e) "matching on universe"
            | _ ->
                error env.EV.silent (get_loc e)
                  "matching on non-tag value of type '%s'"
                  (pp_typ (type_val v))
            end
        | MatchSet (loc,e,ife,(x,xs,ex)) ->
            let v = eval env e in
            begin match v with
            | V.Empty -> eval env ife
            | V.Unv ->
                error env.EV.silent loc
                  "%s" "Cannot set-match on universe"
            | V.ValSet (t,s) ->
                if ValSet.is_empty s then
                  eval env ife
                else
                  let elt =
                    lazy begin
                      try ValSet.choose s
                      with Not_found -> assert false
                    end in
                  let s =
                    lazy begin
                      try ValSet (t,ValSet.remove (Lazy.force elt) s)
                      with  CompError _ -> assert false
                    end in
                  let m = env.EV.env in
                  let m = add_val x elt m in
                  let m = add_val xs s m in
                  eval { env with EV.env = m; }ex
            | _ ->
                error env.EV.silent
                  (get_loc e) "set-matching on non-set value of type '%s'"
                  (pp_typ (type_val v))
            end
        | Try (loc,e1,e2) ->
            begin
              try eval { env with EV.silent = true; } e1
              with Misc.Exit ->
                if O.debug then warn loc "caught failure" ;
                eval env e2
            end
  
    and eval_app loc env vf vs = match vf with
      | Clo f ->
          let env =
            { env with
              EV.env=add_args loc f.clo_args vs env f.clo_env;} in
          begin try eval env f.clo_body with
            Misc.Exit ->
            error env.EV.silent loc "Calling"
          end
      | Prim (name,f) ->
          begin try f vs with
          | PrimError msg ->
              error env.EV.silent loc "primitive %s: %s" name msg
          | Misc.Exit ->
              error env.EV.silent loc "Calling primitive %s" name
          end
      | _ -> error env.EV.silent loc "closure or primitive expected"
  
      and eval_fun is_rec env loc xs body name fvs =
        if O.debug then begin
          let sz =
            StringMap.fold
              (fun _ _ k -> k+1) env.EV.env.vals 0 in
          let fs = StringSet.pp_str "," (fun x -> x) fvs in
          eprintf "Closure %s, env=%i, free={%s}\n" name sz fs
        end ;
        let vals =
          StringSet.fold
            (fun x k ->
              try
                let v = just_find_env (not is_rec) loc env x in
                StringMap.add x v k
              with Not_found -> k)
            fvs StringMap.empty in
        let env = { env.EV.env with vals; } in
        {clo_args=xs; clo_env=env; clo_body=body; clo_name=name; }

      and add_args loc xs vs env_es env_clo =
        let bds =
          try
            List.combine xs vs
          with _ -> error env_es.EV.silent loc "argument_mismatch" in
        let env_call =
          List.fold_right
            (fun (x,v) env -> add_val x (lazy v) env)
            bds env_clo in
        env_call

      and eval_rel env e =  match eval env e with
      | Rel v -> v
      | _ -> error env.EV.silent (get_loc e) "relation expected"

      and eval_set env e = match eval env e with
      | Set v -> v
      | V.Empty -> E.EventSet.empty
      | Unv -> env.EV.ks.evts
      | _ -> error env.EV.silent (get_loc e) "set expected"

      and eval_set_mem env e = match eval env e with
      | Set s -> fun e -> E.EventSet.mem e s
      | V.Empty -> fun _ -> false
      | Unv -> fun _ -> true
      |  _ -> error env.EV.silent (get_loc e) "set expected"

      and eval_proc loc env x = match find_env_loc loc env x with
      | Proc p -> p
      | _ ->
          Warn.user_error "procedure expected"

(* For let *)
      and eval_bds env_bd  =
        let rec do_rec bds = match bds with
        | [] -> env_bd.EV.env
        | (k,e)::bds ->
            (*
              begin match v with
              | Rel r -> printf "Defining relation %s = {%a}.\n" k debug_rel r
              | Set s -> printf "Defining set %s = %a.\n" k debug_set s
              | Clo _ -> printf "Defining function %s.\n" k
              end;
             *)
            add_val k (lazy (eval env_bd e)) (do_rec bds) in
        do_rec

(* For let rec *)

      and env_rec env loc pp bds =
        let fs,nfs =  List.partition  (fun (_,e) -> is_fun e) bds in
        match nfs with
        | [] -> env_rec_funs env loc fs
        | _  -> env_rec_vals env loc pp fs nfs


(* Recursive functions *)
      and env_rec_funs env_bd _loc bds =
        let env = env_bd.EV.env in
        let clos =
          List.map
            (function
              | f,Fun (loc,xs,body,name,fvs) ->
                  f,eval_fun true env_bd loc xs body name fvs,fvs
              | _ -> assert false)
            bds in
        let add_funs pred env =
          List.fold_left
            (fun env (f,clo,_) ->
              if pred f then add_val f (lazy (Clo clo)) env
              else env)
            env clos in
        List.iter
          (fun (_,clo,fvs) ->
            clo.clo_env <-
              add_funs (fun x -> StringSet.mem x fvs) clo.clo_env)
          clos ;
        add_funs (fun _ -> true) env


(* Compute fixpoint of relations *)
      and env_rec_vals env_bd loc pp funs bds =
        let rec fix k env vs =
          if O.debug && O.verbose > 1 then begin
            let vb_pp =
              List.fold_left2
                (fun k (x,_) v ->
                  try
                    let v = match v with
                    | V.Empty -> E.EventRel.empty
                    | Unv -> Lazy.force env_bd.EV.ks.unv
                    | Rel r -> r
                    | _ -> raise Exit in
                    (x, rt_loc x v)::k
                  with Exit -> k)
                [] bds vs in
            let vb_pp = pp vb_pp in
            pp_failure test env_bd.EV.ks.conc (sprintf "Fix %i" k) vb_pp
          end ;
          let env,ws = fix_step env_bd env bds in
          let ok =
            try stabilised env_bd.EV.ks env vs ws
            with Stabilised t ->
              error env_bd.EV.silent loc "illegal recursion on type '%s'"
                (pp_typ t) in
          if ok then env
          else
            (* Update recursive functions *)
            let env = env_rec_funs {env_bd with EV.env=env;} loc funs in
            fix (k+1) env ws in

        let env0 =
          List.fold_left
            (fun env (k,_) -> add_val k (lazy V.Empty) env)
            env_bd.EV.env bds in
        let env0 = env_rec_funs { env_bd with EV.env=env0;} loc funs in
        let env = fix 0 env0 (List.map (fun _ -> V.Empty) bds) in
        if O.debug then warn loc "Fix point over" ;
        env

      and fix_step env_bd env bds = match bds with
      | [] -> env,[]
      | (k,e)::bds ->
          let v = eval {env_bd with EV.env=env;} e in
          let env = add_val k (lazy v) env in
          let env,vs = fix_step env_bd env bds in
          env,(v::vs) in

(* Showing bound variables, (-doshow option) *)

      let find_show_rel ks env x =

        let as_rel v = match v with
        | Rel r -> r
        | V.Empty -> E.EventRel.empty
        | Unv -> Lazy.force ks.unv
        | v ->
            Warn.warn_always
              "Warning show: %s is not a relation: '%s'" x (pp_val v) ;
            raise Not_found in
        try
          rt_loc x (as_rel (Lazy.force (StringMap.find x env.vals)))
        with Not_found -> E.EventRel.empty in

      let doshowone x st =
        if O.showsome && StringSet.mem x  S.O.PC.doshow then
          let show =
            lazy begin
              StringMap.add x
                (find_show_rel st.ks st.env x) (Lazy.force st.show)
            end in
          { st with show;}
        else st in

      let doshow bds st =
        let to_show =
          StringSet.inter S.O.PC.doshow (StringSet.of_list (List.map fst bds)) in
        if StringSet.is_empty to_show then st
        else
          let show = lazy begin
            StringSet.fold
              (fun x show  ->
                let r = find_show_rel st.ks st.env x in
                StringMap.add x r show)
              to_show
              (Lazy.force st.show)
          end in
          { st with show;} in

      let check_bell_enum =
        if O.bell then
          fun loc st name tags ->
            try
              if name = BellName.scopes then
                let bell_info = BellCheck.add_rel name tags st.bell_info in
                { st with bell_info;}                  
              else if name = BellName.regions then
                let bell_info = BellCheck.add_regions tags st.bell_info in
                { st with bell_info;}              
              else st
            with BellCheck.Defined ->
              error st.silent loc "second definition of bell enum %s" name
        else
          fun _loc st _v _tags -> st in

(* Check if order is being defined by a "narrower" function *)
      let check_bell_order = 
        if O.bell then
          fun bds st ->
            List.fold_left
              (fun st (v,e) ->
                if v = BellName.narrower then
                  let loc = get_loc e in
(* Now evaluate all calls to narrower for all scope tags *)
                  let env = from_st st in                  
                  let narrower =
                    try find_env_loc TxtLoc.none env v
                    with _ -> assert false in
                  let scopes =
                    let scopes =
                      try StringMap.find BellName.scopes env.EV.env.vals
                      with Not_found ->
                        error false
                          loc "tag set %s must be defined while defining %s"
                          BellName.scopes BellName.narrower in
                    match Lazy.force scopes with
                    | V.ValSet ((TTag _|TAnyTag),scs) -> scs
                    | v ->
                        error false loc "%s must be a tag set, found %s"
                          BellName.scopes (pp_typ (type_val v)) in
                  let order =
                    ValSet.fold
                      (fun tag order ->                        
                        let tgt =
                          try
                            eval_app loc
                              { env with EV.silent=true;}
                              narrower [tag]
                          with Misc.Exit -> V.Empty in
                        let tag = as_tag tag in
                        let add tgt order =
                          let tgt = as_tag tgt in
                          StringRel.add (tgt,tag) order in
                        match tgt with
                        | V.Empty -> order
                        | V.Tag (_,_) -> add tgt order
                        | V.ValSet (_,tgts) -> ValSet.fold add tgts order
                        | _ ->
                            error false loc
                              "implicit call %s('%s) must return a tag or a set of tags, found %s"
                              BellName.narrower tag (pp_typ (type_val tgt)))
                      scopes StringRel.empty in
                  if not (StringRel.is_hierarchy (as_tags scopes) order) then
                    error false loc
                      "%s defines the non-hierarchical relation %s"
                      BellName.narrower
                      (BellCheck.pp_order_dec order) ;
                  try
                    let bell_info =
                      BellCheck.add_order BellName.scopes order st.bell_info in
                    { st with bell_info;}
                  with BellCheck.Defined ->
                    error st.silent
                      loc "second definition of %s" BellName.narrower
              else st)
              st bds
        else fun _bds st -> st in


(* Execute one instruction *)

      let eval_st st e = eval (from_st st) e in

      let rec exec txt st i kont res =  match i with
      | Debug (_,e) ->
          let v = eval_st st e in
          eprintf "%a: value is %s\n%!"
            TxtLoc.pp (get_loc e) (pp_val v) ;
          kont st res
      | Show (_,xs) when not O.bell ->
          if O.showsome then
            let show = lazy begin
              List.fold_left
                (fun show x ->
                  StringMap.add x (find_show_rel st.ks st.env x) show)
                (Lazy.force st.show) xs
            end in
            kont { st with show;} res
          else kont st res
      | UnShow (_,xs) when not O.bell ->
          if O.showsome then
            let show = lazy begin
              List.fold_left
                (fun show x -> StringMap.remove x show)
                (Lazy.force st.show) xs
            end in
            kont { st with show;} res
          else kont st res
      | ShowAs (_,e,id) when not O.bell  ->
          if O.showsome then
            let show = lazy begin
              StringMap.add id
                (rt_loc id (eval_rel (from_st st) e)) (Lazy.force st.show)
            end in
            kont { st with show; } res
          else kont st res
      | ProcedureTest (loc,pname,es,name) when not O.bell ->
          let skip_this_check =
            match name with
            | Some name -> StringSet.mem name O.skipchecks
            | None -> false in
          if
            O.strictskip || not skip_this_check
          then
            let env0 = from_st st in
            let p = eval_proc loc env0 pname in
            let vs = List.map (eval env0) es in
            let env1 = add_args loc p.proc_args vs env0 p.proc_env in
            run txt  { st with env = env1; } p.proc_body
              (fun st_call res ->  kont { st_call with env=st.env;} res)
              res
          else
            let () = W.warn "Skipping check %s" (Misc.as_some name) in
            kont st res
      | Test (loc,pos,t,e,name,test_type) when not O.bell  ->
          let skip_this_check =
            match name with
            | Some name -> StringSet.mem name O.skipchecks
            | None -> false in
          if O.debug &&  skip_this_check then
            warn loc "skipping check: %s" (Misc.as_some name) ;
          if
            O.strictskip || not skip_this_check
          then
            let v = eval_rel (from_st st) e in
            let pred = match t with
            | Acyclic -> E.EventRel.is_acyclic
            | Irreflexive -> E.EventRel.is_irreflexive
            | TestEmpty -> E.EventRel.is_empty in
            let ok = pred v in
            let ok = MU.check_through ok in
            if ok then kont st res
            else if skip_this_check then begin
              assert O.strictskip ;
              kont
                { st with
                  skipped = StringSet.add (Misc.as_some name) st.skipped;}
                res
            end else begin
              if (O.debug && O.verbose > 0) then begin
                let pp = String.sub txt pos.pos pos.len in
                let cy = E.EventRel.get_cycle v in
                pp_failure test st.ks.conc
                  (sprintf "%s: Failure of '%s'" test.Test.name.Name.name pp)
                  (let k = show_to_vbpp st in
                  match cy with
                  | None -> k
                  | Some r -> ("CY",U.cycle_to_rel r)::k)
              end ;
              match test_type with
              | Provides -> res
              | Requires ->
                  kont {st with undef=true;} res
            end
          else begin
            W.warn "Skipping check %s" (Misc.as_some name) ;
            kont st res
          end
      | Let (_loc,bds) ->
          let env = eval_bds (from_st st) bds in
          let st = { st with env; } in
          let st = doshow bds st in
          let st = check_bell_order bds st in
          kont st res
      | Rec (loc,bds) ->
          let env =
            env_rec (from_st st) loc (fun pp -> pp@show_to_vbpp st) bds in
          let st = { st with env; } in
          let st = doshow bds st in          
          let st = check_bell_order bds st in
          kont st res
      | Include (loc,fname) ->
          do_include loc fname st kont res
      | Procedure (_,name,args,body) ->
          let p =
            Proc { proc_args=args; proc_env=st.env; proc_body=body; } in
          kont { st with env = add_val name (lazy p) st.env } res
      | Call (loc,name,es) when not O.bell ->
          let env0 = from_st st
          and show0 = st.show in
          let p = protect_call st (eval_proc loc env0) name in
          let env1 =
            protect_call st
              (fun e ->
                add_args loc p.proc_args (List.map (eval env0) es) env0 e)
              p.proc_env in
          let st = push_loc st loc in
          run txt { st with env = env1; } p.proc_body
            (fun st_call res ->
              let st_call = pop_loc st_call in
              kont { st_call with env = st.env ; show=show0;} res)
            res
      | Enum (loc,name,xs) ->
          let env = st.env in
          let tags =
            List.fold_left
              (fun env x -> StringMap.add x name env)
              env.tags xs in
          let enums = StringMap.add name xs env.enums in
(* add a set of all tags... *)
          let alltags =
            lazy begin
              let vs =
                List.fold_left
                  (fun k x -> ValSet.add (V.Tag (name,x)) k)
                  ValSet.empty xs in
              V.ValSet (TTag name,vs)
            end in
          let env = add_val name alltags env in
          if O.debug then
            warn loc "adding set of all tags for %s" name ;
          let env = { env with tags; enums; } in
          let st = { st with env;} in
          let st = check_bell_enum loc st name xs in
          kont st res
      | Forall (_loc,x,e,body) when not O.bell  ->
          let st0 = st in
          let env0 = st0.env in
          let v = eval (from_st st0) e in
          begin match tag2set v with
          | V.Empty -> kont st res
          | ValSet (_,set) ->
              let rec run_set st vs res =
                if ValSet.is_empty vs then
                  kont st res
                else
                  let v =
                    try ValSet.choose vs
                    with Not_found -> assert false in
                  let env = add_val x (lazy v) env0 in
                  run txt { st with env;} body
                    (fun st res ->
                      run_set { st with env=env0;} (ValSet.remove v vs) res)
                    res in
              run_set st set res
          | _ ->
              error st.silent
                (get_loc e) "forall instruction applied to non-set value"
          end
      | WithFrom (_,x,e) when not O.bell  ->
          let st0 = st in
          let env0 = st0.env in
          let v = eval (from_st st0) e in
          begin match v with
          | V.Empty -> res
          | ValSet (_,vs) ->
              ValSet.fold
                (fun v res ->
                  let env = add_val x (lazy v) env0 in
                  kont (doshowone x {st with env;}) res)
                vs res
          | _ -> error st.silent (get_loc e) "set expected"
          end
      | Latex _ -> kont st res
(*
      | EnumSet(_loc,_name,xs) -> 
          warn _loc "Deprecated" ;
	  let test_bi = match test.Test.bell_info with
	  | Some t_bi -> t_bi
	  | None ->
              Warn.user_error
                "Using enum set requires bell info and should only be used when analyzing a bell litmus test"
	  in
	  let new_env_sets = 
	    List.map (fun k -> 
	      k, lazy (E.EventSet.filter (fun e -> 
	        (mem_region_match k test_bi.Bell_info.regions e) ||(E.Act.annot_in_list k e.E.action)) st.ks.evts))
	      xs in
	  let env = add_sets st.env new_env_sets in		
	  kont {st with env} res

      | EnumRel(_loc,_name,xs) -> 
          warn _loc "Deprecated" ;
	  let test_bi = match test.Test.bell_info with
	  | Some t_bi -> t_bi
	  | None -> Warn.user_error "Using enum rln requires bell info"
	  in
	  let scopes = match test_bi.Bell_info.scopes with
	  | Some s -> s
	  | None -> Warn.user_error "Using enum rln requires scopes in the litmus test" 
	  in
	  let bds = 
	    List.map (fun k ->
	      k, lazy (U.int_scope_bell k scopes (Lazy.force st.ks.unv)))
	      xs in
	  let env = add_rels st.env bds in
	  let st = { st with env;} in
          let st = doshow bds st in
	  kont st res
*)
      | Event_dec(_loc,x,es) when O.bell ->
	  let vs = List.map (eval_loc (from_st st)) es in
	  let event_sets =
            List.map
              (fun (loc,v) -> match v with 
	      | ValSet((TTag _|TAnyTag),elts) -> 
                  let tags = 
	            ValSet.fold
                      (fun elt k -> as_tag elt::k)
                      elts [] in
                  StringSet.of_list tags
              | _ ->
                  error false loc
                    "event declaration expected a set of tags, found %s"
                    (pp_val v))
              vs in
          let bell_info =
            BellCheck.add_events x event_sets st.bell_info in
          let st = { st with bell_info;} in
	  kont st res

(*
      | Relation_dec(loc, v, e) when O.bell ->
	  let evaled = eval (from_st st) e in
	  let strs = 
	    match evaled with
	    | ValSet(_t,vs) -> List.map (fun vs_e -> 
	        (		
	           match vs_e with 
	           | V.Tag(_s1,s2) -> s2
	           | _ -> error false loc "relations declaration expected a set of tags. %s is not a tag" (pp_val vs_e)
	          ))  (ValSet.elements vs)		
	    | _ -> error false loc "event declaration expected a set of tags. %s is not a tag" (pp_val evaled)
	  in
          let bell_dec =
            { st.bell_dec with
              rel_dec = add_dec (@) v strs st.bell_dec.rel_dec;} in
          let st = { st with bell_dec;} in
	  kont st res
      | Order_dec(loc,v,ep_l) when O.bell ->
	  let evaled =
            let env = from_st st in
            List.map
              (fun (f,s) -> eval env f, eval env s)
              ep_l
	  in
	  let str_pairs = 
            List.map
              (fun (f,s) -> match f,s with
	      | V.Tag(_,tag1), V.Tag(_,tag2) ->
                  tag1,tag2
	      | (V.Tag _ ,bad)
              | (bad,V.Tag _) ->
                  error st.silent loc
                  "order declarations expected tag pairs, %s is not a tag"
                  (pp_val bad)
	      | _,_ ->
                  error st.silent loc
                    "order declarations expect tag pairs, %s and %s are not tags"
                    (pp_val f) (pp_val s))
              evaled in
          let bell_dec =
            { st.bell_dec with
              order_dec = add_dec (@) v str_pairs st.bell_dec.order_dec;} in
          let st = { st with bell_dec;} in
	  kont st res
*)
      | Order_dec (loc,_,_) | Relation_dec (loc,_,_) when O.bell ->
          warn loc "deprecated" ;
          kont st res          
      | Event_dec (_, _, _)|Relation_dec (_, _, _)|Order_dec (_, _, _) ->
          assert (not O.bell) ;
          kont st res (* Ignore bell constructs when executing model *)
      | EnumSet (loc,_,_) | EnumRel (loc,_,_) ->
          warn loc "deprecated" ;
          kont st res
      | Test _|UnShow _|Show _|ShowAs _
      | ProcedureTest _|Call _|Forall _
      | WithFrom _ ->
          assert O.bell ;
          kont st res (* Ignore cat constructs when executing bell *)

      and do_include loc fname st kont res =
        (* Run sub-model file *)
        if O.debug then warn loc "include \"%s\"" fname ;
        let module P = ParseModel.Make(LexUtils.Default) in
        let itxt,(_,_,iprog) =
          try P.parse fname
          with Misc.Fatal msg | Misc.UserError msg ->
            error st.silent loc "%s" msg  in
        run itxt st iprog kont res

      and run txt st c kont res = match c with
      | [] ->  kont st res
      | i::c ->
          exec txt st i
            (fun st res -> run txt st c kont res)
            res in

      fun ks m vb_pp kont res ->
(* Primitives *)
        let m = add_primitives m in
(* Initial show's *)
        let show =
          if O.showsome then
            lazy begin
              let show =
                List.fold_left
                  (fun show (tag,v) -> StringMap.add tag v show)
                  StringMap.empty (Lazy.force vb_pp) in
              StringSet.fold
                (fun tag show -> StringMap.add tag (find_show_rel ks m tag) show)
                S.O.PC.doshow show
            end else lazy StringMap.empty in

        let st =
          {env=m; show=show; skipped=StringSet.empty;
           silent=false; undef=false; ks; bell_info=BellCheck.empty_info;
           stack =[];} in        
        let just_run st res = run txt st prog kont res in
        do_include TxtLoc.none "stdlib.cat" st
          (fun st res ->
            match O.bell_fname with
(* No bell file, just run *)
            | None -> just_run st res
(* Run bell file first, to get all its definitions... *)
            | Some fname ->
                do_include TxtLoc.none fname st just_run res)
          res

  end
