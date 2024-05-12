%{
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

module A=BPFBase

%}

%token EOF
%token <BPFBase.reg> ARCH_REG
%token <string> SYMB_REG
%token <int> NUM
%token <string> NAME
%token <int> PROC
%token <BPFBase.signed * BPFBase.width> SIZE

%token SEMI PIPE COLON LPAR RPAR MINUS EQUAL STAR SLASH PLUS LAND XOR
%token COMMA

/* Instruction tokens */
%token NOP SYNC
%token PERCENT LSL LSR ASR
%token <BPFBase.aop> AMOF
%token <BPFBase.width> AMOXCHGT
%token LOCK

%type <MiscParser.proc list * (BPFBase.pseudo) list list> main
%start  main

%%

main:
| semi_opt proc_list iol_list EOF { $2,$3 }

semi_opt:
| { () }
| SEMI { () }

proc_list:
| ps=separated_nonempty_list(PIPE,PROC) SEMI
  { List.map (fun p -> p,None,MiscParser.Main) ps }

iol_list :
|  instr_option_list SEMI
    {[$1]}
|  instr_option_list SEMI iol_list {$1::$3}

instr_option_list :
  | instr_option
      {[$1]}
  | instr_option PIPE instr_option_list
      {$1::$3}

instr_option :
|            { A.Nop }
| NAME COLON instr_option { A.Label ($1,$3) }
| instr      { A.Instruction $1}

reg:
| SYMB_REG { A.Symbolic_reg $1 }
| ARCH_REG { $1 }

k:
| NUM { $1 }

instr:
| NOP
  { A.NOP }

/* ALU OPS */

/* ADD */
| reg PLUS EQUAL reg
  { A.OP (A.ADD,$1,$4) }
| reg PLUS EQUAL k
  { A.OPI (A.ADD,$1,$4) }

/* SUB */
| reg MINUS EQUAL reg
  { A.OP (A.SUB,$1,$4) }
| reg MINUS EQUAL k
  { A.OPI (A.SUB,$1,$4) }

/* MUL */
| reg STAR EQUAL reg
  { A.OP (A.MUL,$1,$4) }
| reg STAR EQUAL k
  { A.OPI (A.MUL,$1,$4) }

/* DIV */
| reg SLASH EQUAL reg
  { A.OP (A.DIV,$1,$4) }
| reg SLASH EQUAL k
  { A.OPI (A.DIV,$1,$4) }

/* REM */
| reg PERCENT EQUAL reg
  { A.OP (A.REM,$1,$4) }
| reg PERCENT EQUAL k
  { A.OPI (A.REM,$1,$4) }

/* AND */
| reg LAND EQUAL reg
  { A.OP (A.AND,$1,$4) }
| reg LAND EQUAL k
  { A.OPI (A.AND,$1,$4) }

/* OR */
| reg PIPE EQUAL reg
  { A.OP (A.OR,$1,$4) }
| reg PIPE EQUAL k
  { A.OPI (A.OR,$1,$4) }

/* XOR */
| reg XOR EQUAL reg
  { A.OP (A.XOR,$1,$4) }
| reg XOR EQUAL k
  { A.OPI (A.XOR,$1,$4) }

/* LSR */
| reg LSR EQUAL reg
  { A.OP (A.LSR,$1,$4) }
| reg LSR EQUAL k
  { A.OPI (A.LSR,$1,$4) }

/* LSL */
| reg LSL EQUAL reg
  { A.OP (A.LSL,$1,$4) }
| reg LSL EQUAL k
  { A.OPI (A.LSL,$1,$4) }

/* ASR */
| reg ASR EQUAL reg
  { A.OP (A.ASR,$1,$4) }
| reg ASR EQUAL k
  { A.OPI (A.ASR,$1,$4) }

/* LDX r0 = *(size *)(r1 + 0) */
| reg EQUAL STAR LPAR SIZE STAR RPAR LPAR reg PLUS k RPAR
  { let s,w = $5 in
    A.LOAD (w,s,$1,$9,$11) }

/* STX *(size *)(r1 + 0) = r2  */
| STAR LPAR SIZE STAR RPAR LPAR reg PLUS k RPAR EQUAL reg
  { let _,w = $3 in
    A.STORE (w,$7,$9,$12) }

/* ST *(size *)(r1 + 0) = imm  */
| STAR LPAR SIZE STAR RPAR LPAR reg PLUS k RPAR EQUAL k
  { let _,w = $3 in
    A.STOREI (w,$7,$9,$12) }

/* atomic ops with fetch rs = atomic_fetch_or ((u64 *)(rd + offset16), rs)  */
| reg EQUAL AMOF LPAR LPAR SIZE STAR RPAR LPAR reg PLUS k RPAR COMMA reg RPAR
  { let op = $3 in
    let _,w = $6 in
   A.AMO(op, w, $10, $12, $15, A.SC, true) }

/* atomic exchange rs = xchg_64 (rd + offset16, rs) */
| reg EQUAL AMOXCHGT LPAR reg PLUS k COMMA reg RPAR
  { let sz = $3 in
   A.AMO(A.AMOXCHG, sz, $5, $7, $9, A.SC, true) }

/* atomic operations without fetch lock *(u64 *)(rd + offset16) = rs  */
| LOCK STAR LPAR SIZE STAR RPAR LPAR reg PLUS k RPAR PLUS EQUAL reg
  { let _,w = $4 in
    A.AMO(A.AMOADD, w, $8, $10, $14, A.RLX, false) }
| LOCK STAR LPAR SIZE STAR RPAR LPAR reg PLUS k RPAR LAND EQUAL reg
  { let _,w = $4 in
    A.AMO(A.AMOAND, w, $8, $10, $14, A.RLX, false) }
| LOCK STAR LPAR SIZE STAR RPAR LPAR reg PLUS k RPAR PIPE EQUAL reg
  { let _,w = $4 in
    A.AMO(A.AMOOR, w, $8, $10, $14, A.RLX, false) }
| LOCK STAR LPAR SIZE STAR RPAR LPAR reg PLUS k RPAR XOR EQUAL reg
  { let _,w = $4 in
    A.AMO(A.AMOXOR, w, $8, $10, $14, A.RLX, false) }

/* MOV r0 = r1 */
| reg EQUAL reg
  { A.MOV($1, $3)}

/* MOV r0 = 10 */
| reg EQUAL k
  { A.MOVI($1, $3)}

| SYNC
  { A.SYNC }
