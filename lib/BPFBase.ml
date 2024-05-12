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

(** BPF architecture, base definitions *)

open Printf
open Sign

let arch = Archs.bpf
let endian = Endian.Little
let base_type = CType.Base "int"

(*************)
(* Registers *)
(*************)

type ireg =
  | R0 | R1 | R2 | R3 | R4 | R5 | R6 | R7
  | R8 | R9 | R10

type reg =
  | IReg of ireg
  | PC
  | Symbolic_reg of string
  | Internal of int

let parse_ireg = function
  | "R0"|"r0"-> R0
  | "R1"|"r1" -> R1
  | "R2"|"r2" -> R2
  | "R3"|"r3" -> R3
  | "R4"|"r4" -> R4
  | "R5"|"r5" -> R5
  | "R6"|"r6" -> R6
  | "R7"|"r7" -> R7
  | "R8"|"r8" -> R8
  | "R9"|"r9" -> R9
  | "R10"|"r10"|"FP"|"fp" -> R10
  | _ -> raise Exit


let parse_reg s =
  try Some (IReg (parse_ireg s))
  with Exit -> None

open PPMode

let do_pp_ireg = function
  | R0 ->  "r0"
  | R1 ->  "r1"
  | R2 ->  "r2"
  | R3 ->  "r3"
  | R4 ->  "r4"
  | R5 ->  "r5"
  | R6 ->  "r6"
  | R7 ->  "r7"
  | R8 ->  "r8"
  | R9 ->  "r9"
  | R10 ->  "fp"

let pp_reg = function
  | IReg r -> do_pp_ireg r
  | Symbolic_reg r ->  r
  | Internal i -> sprintf "ir%i" i
  | PC -> "pc"

let reg_compare = compare

let symb_reg_name = function
  | Symbolic_reg s -> Some s
  | _ -> None

let symb_reg r = Symbolic_reg r
let type_reg _ = base_type

(************)
(* Barriers *)
(************)

type barrier = Sync

let all_kinds_of_barriers = [Sync;]

let pp_barrier = function
  | Sync -> "Sync"

let barrier_compare = compare

type lannot = RLX | SC

(****************)
(* Instructions *)
(****************)

type k = int
type lbl = Label.t

type op = ADD | SUB | MUL | DIV | REM | AND | OR | XOR | LSL | LSR | ASR

type width = Byte | Half | Word | Double

type aop = AMOADD | AMOOR | AMOAND | AMOXOR | AMOXCHG | AMOCMPXCHG

let tr_width = function
  | Byte -> MachSize.Byte
  | Half -> MachSize.Short
  | Word -> MachSize.Word
  | Double -> MachSize.Quad

type signed = Sign.t

type instruction =
  | NOP
  | OP of op * reg * reg
  | OPI of op * reg * k
  | LOAD of width * signed * reg * reg * k
  | STORE of width * reg * k * reg
  | STOREI of width * reg * k * k
  | MOV of reg * reg
  | MOVI of reg * k
  | AMO of aop * width * reg * k * reg * lannot * bool
  | SYNC

type parsedInstruction = instruction

let pp_lbl = fun i -> i

let pp_op = function
  | ADD -> "add"
  | SUB -> "sub"
  | AND -> "and"
  | OR -> "or"
  | XOR -> "xor"
  | MUL -> "mul"
  | DIV -> "div"
  | REM -> "rem"
  | LSL -> "lsl"
  | LSR -> "lsr"
  | ASR -> "asr"

let pp_instruction _m (i : instruction) = match i with
        | _ -> "Printing Not Supported!"

let dump_instruction = pp_instruction Ascii

let dump_instruction_hash = dump_instruction

(****************************)
(* Symbolic registers stuff *)
(****************************)

let allowed_for_symb =
  List.map
    (fun r -> IReg r)
    [R0; R1; R2; R3; R4; R5; R6; R7; R8; R9;
     R10;]

let fold_regs (f_reg,f_sreg) =
  let fold_reg reg (y_reg,y_sreg) = match reg with
  | IReg _|PC-> f_reg reg y_reg,y_sreg
  | Symbolic_reg reg -> y_reg,f_sreg reg y_sreg
  | Internal _ -> y_reg,y_sreg in

  fun c ins -> match ins with
  | OP (_,r1,r2)
  | LOAD (_,_,r1,r2,_)
  | MOV (r1, r2)
  | AMO (_,_,r1,_,r2,_,_)
  | STORE (_,r1,_,r2) ->
      fold_reg r1 (fold_reg r2 c)
  | MOVI (r1,_)
  | STOREI (_,r1,_,_)
  | OPI (_,r1,_) ->
      fold_reg r1 c
  | NOP|SYNC -> c

let map_regs f_reg f_symb =
  let map_reg reg = match reg with
  | IReg _|PC -> f_reg reg
  | Symbolic_reg reg -> f_symb reg
  | Internal _ -> reg in

  fun ins -> match ins with
  | OP (op,r1,r2) ->
      OP (op,map_reg r1,map_reg r2)
  | OPI (op,r1,k) ->
      OPI (op,map_reg r1,k)
  | AMO (op,w,r1,k,r2,s,f) ->
      AMO (op, w, map_reg r1, k, map_reg r2, s,f)
  | LOAD (w,s,r1,r2,k) ->
      LOAD (w,s,map_reg r1, map_reg r2, k)
  | STORE (w,r1,k,r2) ->
      STORE (w,map_reg r1, k, map_reg r2)
  | STOREI (w,r1,k1,k2) ->
      STOREI (w,map_reg r1, k1, k2)
  | MOV (r1, r2) ->
      MOV (map_reg r1, map_reg r2)
  | MOVI (r1, k) ->
      MOVI (map_reg r1, k)
  | NOP| SYNC -> ins

(* No addresses burried in BPF code *)
let fold_addrs _f c _ins = c

let map_addrs _f ins = ins

(* No normalisation (yet ?) *)
let norm_ins ins = ins

(* Instruction continuation *)
let get_next = function
  | NOP
  | OP _
  | OPI _
  | AMO _
  | LOAD _
  | STORE _
  | STOREI _
  | MOV _
  | MOVI _
  | SYNC -> [Label.Next]

let is_valid _ = true

include Pseudo.Make
    (struct
      type ins = instruction
      type pins = parsedInstruction
      type reg_arg = reg

      let parsed_tr i = i

      let get_naccesses = function
        | NOP
        | OP _
        | OPI _
        | MOV _
        | MOVI _
        | SYNC -> 0
        | STORE _
        | STOREI _
        | AMO _
        | LOAD _ -> 1

      let size_of_ins _ = 4

      let fold_labels k _f = function
        | _ -> k

      let map_labels _f =
        let open BranchTarget in
        function
        | ins -> ins

    end)

let get_macro _name = raise Not_found

let get_id_and_list _i = Warn.fatal "get_id_and_list is only for Bell"

let hash_pteval _ = assert false

module Instr =
  Instr.WithNop
    (struct
      type instr = instruction
      let nop = NOP
      let compare = compare
    end)
