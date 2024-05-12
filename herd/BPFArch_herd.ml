(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* Copyright (c) 2024 Puranjay Mohan <puranjay@kernel.org>                  *)
(*                                                                          *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law and   *)
(* abiding by the rules of distribution of free software. You can use,      *)
(* modify and/ or redistribute the software under the terms of the CeCILL-B *)
(* license as circulated by CEA, CNRS and INRIA at the following URL        *)
(* "http://www.cecill.info". We also give a copy in LICENSE.txt.            *)
(****************************************************************************)

(** Define BPF architecture *)

module Make
         (C:Arch_herd.Config)
         (V:Value.S with type Cst.Instr.t  = BPFBase.instruction ) =
  struct
    include BPFBase
    let is_amo = function
            | AMO(_,_,_,_,_,SC,_) -> true
            | _ -> false

    let pp_barrier_short = pp_barrier
    let reject_mixed = false

    let get_machsize _ = V.Cst.Scalar.machsize

    let empty_annot = RLX
    let is_sc = function
            | SC -> true
            | RLX -> false

    let is_atomic = function
            | SC -> true
            | RLX -> false

    let ifetch_value_sets = []

    let barrier_sets = ["SYNC",(function Sync -> true);]

    let cmo_sets = []

    let annot_sets = ["SC", is_sc; "X", is_atomic;]

    include Explicit.No
    include PteValSets.No

    let is_isync _ = false
    let pp_isync = "???"

    let pp_annot = function
                | RLX -> ""
                | SC -> "SC"

    module V = V

    let mem_access_size = function
            | LOAD (w,_,_,_,_)
            | AMO (_,w,_,_,_,_,_)
            | STORE (w,_,_,_) -> Some (tr_width w)
            | _ -> None

    include NoSemEnv

    include NoLevelNorTLBI

    include ArchExtra_herd.Make(C)
	(struct
	  module V = V
          let endian = endian

	  type arch_reg = reg
	  let pp_reg = pp_reg
	  let reg_compare = reg_compare

          let fromto_of_instr _ = None

          let get_val _ v = v

          module FaultType=FaultType.No
	end)

    module MemType=MemoryType.No

    module NoConf = struct
      type v = V.v
      type loc = location
      type value_set = V.ValueSet.t
      type solution = V.solution
      type arch_lannot = lannot
      type arch_explicit = explicit
    end

    module ArchAction = ArchAction.No(NoConf)

    module Barrier = struct

      type a = barrier

      let a_to_b = function
        | Sync -> AllBarrier.SYNC

      let pp_isync = "???"

    end

    module CMO = Cmo.No
  end
