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

{
module Make(O:LexUtils.Config) = struct
open Lexing
open LexMisc
open Sign
open BPFBase
open BPFParser

module LU = LexUtils.Make(O)

let parse_reg name = begin match BPFBase.parse_reg name with
  | Some r -> ARCH_REG r;
  | None -> NAME name
end

let check_name = function
  | "nop"-> NOP
  | "u8" -> SIZE (Unsigned, Byte)
  | "u16" -> SIZE (Unsigned, Half)
  | "u32" -> SIZE (Unsigned, Word)
  | "u64" -> SIZE (Unsigned, Double)
  | "atomic_fetch_add" -> AMOF (AMOADD)
  | "atomic_fetch_and" -> AMOF (AMOAND)
  | "atomic_fetch_or" -> AMOF (AMOOR)
  | "atomic_fetch_xor" -> AMOF (AMOXOR)
  | "xchg_64"          -> AMOXCHGT (Double)
  | "xchg_32"          -> AMOXCHGT (Word)
  | "lock"             -> LOCK
  | "sync" -> SYNC
  | name -> parse_reg name

}
let digit = [ '0'-'9' ]
let alpha = [ 'a'-'z' 'A'-'Z']
let name  = alpha (alpha|digit|'_' | '/' | '.' | '-')*
let num = digit+

rule token = parse
| [' ''\t''\r'] { token lexbuf }
| '\n'      { incr_lineno lexbuf; token lexbuf }
| "(*"      { LU.skip_comment lexbuf ; token lexbuf }
| '-' ? num as x { NUM (int_of_string x) }
| 'P' (num as x)
    { PROC (int_of_string x) }
| ';' { SEMI }
| ',' { COMMA }
| '|' { PIPE }
| '(' { LPAR }
| ')' { RPAR }
| ':' { COLON }
| '=' { EQUAL }
| '-' { MINUS }
| '*' { STAR }
| '%' { PERCENT }
| '/' { SLASH }
| '+' { PLUS }
| '^' { XOR }
| '&' { LAND }
| ">>" { LSR }
| "<<" { LSL }
| "s>>" { ASR }
| name as x
  { check_name x }
| eof { EOF }
| ""  { error "BPF lexer" lexbuf }

{
let token lexbuf =
   let tok = token lexbuf in
   if O.debug then begin
     Printf.eprintf
       "%a: Lexed '%s'\n"
       Pos.pp_pos2
       (lexeme_start_p lexbuf,lexeme_end_p lexbuf)
       (lexeme lexbuf)
   end ;
   tok
end
}
