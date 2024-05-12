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

(** Semantics of BPF instructions *)

module
  Make
    (C:Sem.Config)
    (V:Value.S with type Cst.Instr.t = BPFBase.instruction)
=
  struct
    module BPF = BPFArch_herd.Make(SemExtra.ConfigToArchConfig(C))(V)
    module Act = MachAction.Make(C.PC)(BPF)
    include SemExtra.Make(C)(BPF)(Act)

(* Barrier pretty print *)
    let sync = {barrier=BPF.Sync; pp="sync";}

    let barriers = [sync;]
    let isync = None
(*  TODO: let nat_sz = MachSize.Quad (* 64-bit Registers *) *)
    let nat_sz = V.Cst.Scalar.machsize
    let atomic_pair_allowed _ _ = true

(********************)
(* Semantics proper *)
(********************)

    module Mixed(SZ:ByteSize.S) = struct

      let (>>=) = M.(>>=)
      let (>>*=) = M.(>>*=)
      let (>>|) = M.(>>|)
      let (>>!) = M.(>>!)
      let (>>::) = M.(>>::)

      let unimplemented op = Warn.user_error "BPF operation %s is not implemented (yet)" op

      let tr_op = function
        | BPF.ADD -> Op.Add
        | BPF.SUB -> Op.Sub
        | BPF.AND -> Op.And
        | BPF.OR -> Op.Or
        | BPF.XOR -> Op.Xor
        | BPF.MUL -> Op.Mul
        | BPF.DIV -> Op.Div
        | BPF.REM -> Op.Rem
        | BPF.LSL -> Op.ShiftLeft
        | BPF.LSR -> Op.Lsr
        | BPF.ASR
          -> unimplemented (BPF.pp_op BPF.ASR)

      let tr_opamo op = match op with
        | BPF.AMOXCHG -> assert false
        | BPF.AMOADD -> Op.Add
        | BPF.AMOAND -> Op.And
        | BPF.AMOOR -> Op.Or
        | BPF.AMOXOR -> Op.Xor
        | BPF.AMOCMPXCHG ->
          unimplemented "atomic op"

      let mk_read sz ato loc v =
        Act.Access
          (Dir.R, loc, v, ato, (), sz, Act.access_of_location_std loc)

      let read_reg is_data r ii =
          M.read_loc is_data (mk_read nat_sz BPF.RLX) (A.Location_reg (ii.A.proc,r)) ii

      let read_reg_ord = read_reg false
      let read_reg_data = read_reg true

      let do_read_mem sz ato a ii = M.read_loc false (mk_read sz ato) (A.Location_global a) ii
      let read_mem sz a ii = do_read_mem sz BPF.RLX a ii
      let read_mem_atomic sz a ii = do_read_mem sz BPF.SC a ii

      let write_reg r v ii =
          M.mk_singleton_es
            (Act.Access
               (Dir.W, (A.Location_reg (ii.A.proc,r)), v, BPF.RLX, (), nat_sz, Access.REG))
            ii

      let write_mem sz a v ii  =
        M.mk_singleton_es
          (Act.Access (Dir.W, A.Location_global a, v, BPF.RLX, (), sz, Access.VIR)) ii

      let write_mem_atomic sz a v resa ii =
        let eq = [M.VC.Assign (a,M.VC.Atom resa)] in
        M.mk_singleton_es_eq
          (Act.Access (Dir.W, A.Location_global a, v, BPF.SC, (), sz, Access.VIR))
          eq ii

      let create_barrier b ii =
        M.mk_singleton_es (Act.Barrier b) ii

      let commit ii =
        M.mk_singleton_es (Act.Commit (Act.Bcc,None)) ii

(* Signed *)
      let imm16ToV k =
        V.Cst.Scalar.of_int (k land 0xffff)
        |> V.Cst.Scalar.sxt MachSize.Short
        |> fun sc -> V.Val (Constant.Concrete sc)

      let imm16To64 k =
        V.Cst.Scalar.of_int (k land 0xffff)
        |> V.Cst.Scalar.sxt MachSize.Quad
        |> fun sc -> V.Val (Constant.Concrete sc)

      let imm16To32 k =
        V.Cst.Scalar.of_int (k land 0xffff)
        |> V.Cst.Scalar.sxt MachSize.Word
        |> fun sc -> V.Val (Constant.Concrete sc)

      let amo sz op an rd rs k f ii =
        let open BPF in
          let ra = read_reg_ord rd ii
          and rv = read_reg_data rs ii
          and ca v = M.add v (imm16ToV k) in
          match op with
          | AMOXCHG ->
              (ra >>| rv) >>=
              (fun (ea, vstore) ->
                (ca ea) >>=
              (fun (loc) ->
                M.read_loc false
                  (fun loc v -> Act.Amo (loc,v,vstore, an,(),sz,Access.VIR))
                  (A.Location_global loc) ii)) >>= fun r -> write_reg rs r ii
          | _ ->
              (ra >>| rv) >>=
              (fun (ea, v) ->
                (ca ea) >>=
              (fun (loc) ->
                M.fetch (tr_opamo op) v
                  (fun v vstored ->
                    Act.Amo (A.Location_global loc,v,vstored, an,(),sz,Access.VIR))
                  ii))  >>=  fun v -> match f with
                                | true -> write_reg rs v ii
                                | false -> M.unitT ()

(* Entry point *)

      let tr_sz = BPF.tr_width

      let build_semantics _ ii =
        M.addT (A.next_po_index ii.A.program_order_index)
          begin match ii.A.inst with
          | BPF.NOP -> B.nextT
          | BPF.OP (op,r1,r2) ->
              (read_reg_ord r1 ii >>|  read_reg_ord r2 ii) >>=
              (fun (v1,v2) -> M.op (tr_op op) v1 v2) >>=
              (fun v -> write_reg r1 v ii) >>= B.next1T
          | BPF.OPI (op,r1,k) ->
              read_reg_ord r1 ii >>=
              fun v -> M.op (tr_op op) v (V.intToV k) >>=
              fun v -> write_reg r1 v ii >>= B.next1T
          | BPF.LOAD (w,_s,r1,r2,k) ->
              let sz = tr_sz w in
              read_reg_ord r2 ii >>=
              (fun a -> M.add a (imm16ToV k)) >>=
              (fun ea -> read_mem sz ea ii) >>=
              (fun v -> write_reg r1 v ii)  >>= B.next1T
          | BPF.STORE (sz,r1,k,r2) ->
              (read_reg_data r1 ii >>| read_reg_ord r2 ii) >>=
              (fun (d,a) ->
                (M.add d (imm16ToV k)) >>=
                (fun ea -> write_mem (tr_sz sz) ea a ii)) >>= B.next1T
          | BPF.STOREI (sz,r1,k1,k2) ->
               read_reg_data r1 ii  >>=
              (fun d ->
                (M.add d (imm16ToV k1)) >>=
                (fun ea -> write_mem (tr_sz sz) ea (V.intToV k2) ii)) >>= B.next1T
          | BPF.MOV (rd, rs) ->
                read_reg_data rs ii >>= fun v -> write_reg rd v ii
                >>= B.next1T
          | BPF.MOVI (rd, k) ->
                write_reg rd (V.intToV k) ii >>= B.next1T
          | BPF.AMO (aop, w, rd, k, rs, annot, f) ->
                amo (tr_sz w) aop annot rd rs k f ii >>= B.next1T
          | BPF.SYNC ->
              create_barrier BPF.Sync ii >>= B.next1T
          end

      let spurious_setaf _ = assert false

    end
  end
