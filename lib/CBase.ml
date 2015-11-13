(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* Jade Alglave, University College London, UK.                             *)
(* Luc Maranget, INRIA Paris-Rocquencourt, France.                          *)
(*                                                                          *)
(* Copyright 2015-present Institut National de Recherche en Informatique et *)
(* en Automatique and the authors. All rights reserved.                     *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law and   *)
(* abiding by the rules of distribution of free software. You can use,      *)
(* modify and/ or redistribute the software under the terms of the CeCILL-B *)
(* license as circulated by CEA, CNRS and INRIA at the following URL        *)
(* "http://www.cecill.info". We also give a copy in LICENSE.txt.            *)
(****************************************************************************)
open Printf

let arch = Archs.c

type reg = string

let parse_reg s = Some s
let pp_reg r = r
let reg_compare = String.compare
let symb_reg_name r = Some r

type loc = 
  | Reg of reg
  | Mem of reg

let loc_compare l1 l2 = match l1,l2 with
  | Reg s1,Reg s2 -> reg_compare s1 s2
  | Mem s1,Mem s2 -> reg_compare s1 s2
  | Reg _,Mem _ -> -1
  | Mem _,Reg _ -> 1

let dump_loc = function
  | Reg r -> r
  | Mem r -> "*"^r

type mem_order = MemOrder.t 

type barrier = F of MemOrder.t

let pp_barrier (F(m)) = "Fence("^(MemOrder.pp_mem_order m)^")"
let barrier_compare = Pervasives.compare

type expression = 
  | Const of SymbConstant.v
  | Load of loc * mem_order option
  | Op of Op.op * expression * expression
  | Exchange of loc * expression * mem_order
  | Fetch of loc * Op.op * expression * mem_order

type instruction = 
  | Fence of barrier
  | Seq of instruction list
  | If of expression * instruction * instruction option
  | Store of loc * expression * mem_order option
  | Lock of loc
  | Unlock of loc
  | Symb of string

type parsedInstruction = instruction

let rec dump_instruction = 
  let dump_op =
    let open Op in
    function
    | Add -> "add"
    | Sub -> "sub"
    | Or -> "or"
    | Xor -> "xor"
    | And -> "and"
    | _ -> assert false in

  let rec dump_expr = function
    | Const c -> SymbConstant.pp_v c
    | Load(l,None) -> dump_loc l
    | Load(l,Some mo) ->
       sprintf "atomic_load_explicit(%s,%s)"
	       (dump_loc l) (MemOrder.pp_mem_order mo)
    | Op(op,e1,e2) -> 
       sprintf "%s %s %s" (dump_expr e1) (Op.pp_op op) (dump_expr e2)
    | Exchange(l,e,mo) ->
        sprintf "atomic_exchange_explicit(%s,%s,%s)"
	  (dump_loc l) (dump_expr e) (MemOrder.pp_mem_order mo)
  | Fetch(l,op,e,mo) -> 
     sprintf "atomic_fetch_%s_explicit(%s,%s,%s);" 
	     (dump_op op) (dump_loc l) (dump_expr e) 
	     (MemOrder.pp_mem_order mo)
  in function
  | Fence b -> (pp_barrier b)^";\n"
  | Seq l -> 
     let seq = List.fold_left (fun a i -> a^(dump_instruction i)^"\n") 
			      "" l in
     if List.length l < 2
     then seq
     else "{\n"^seq^"}\n"
  | If(c,t,e) ->
     let els =  match e with
       | None -> ""
       | Some e -> dump_instruction e
     in "if("^dump_expr c^") "^(dump_instruction t)^"else "^els
  | Store(l,e,None) -> 
     sprintf "%s = %s;" (dump_loc l) (dump_expr e)
  | Store(l,e,Some mo) -> 
     sprintf "atomic_store_explicit(%s,%s,%s);"
	     (dump_loc l) (dump_expr e) (MemOrder.pp_mem_order mo)
  | Lock l -> 
     sprintf "lock(%s);" (dump_loc l) 
  | Unlock l -> 
     sprintf "unlock(%s);" (dump_loc l)
  | Symb s -> sprintf "codevar:%s;" s


let pp_instruction _mode = dump_instruction 

let allowed_for_symb = List.map (fun x -> "r"^(string_of_int x)) 
				(Misc.interval 0 64)

let fold_regs (_fc,_fs) acc _ins = acc
let map_regs _fc _fs ins = ins
let fold_addrs _f acc _ins = acc
let map_addrs _f ins = ins
let norm_ins ins = ins
let get_next _ins = Warn.fatal "C get_next not implemented"

include Pseudo.Make
	  (struct
	    type ins = instruction
	    type pins = parsedInstruction
	    type reg_arg = reg

	    let rec parsed_expr_tr = function
	      | Const(Constant.Concrete _) as k -> k 
	      | Const(Constant.Symbolic _) -> 
		 Warn.fatal "No constant variable allowed"
	      | Load _ as l -> l
	      | Op(op,e1,e2) -> Op(op,parsed_expr_tr e1,parsed_expr_tr e2)
	      | Exchange(l,e,mo) -> Exchange(l,parsed_expr_tr e,mo)
	      | Fetch(l,op,e,mo) -> Fetch(l,op,parsed_expr_tr e,mo)

	    and parsed_tr = function
	      | Fence _ as f -> f
	      | Seq(li) -> Seq(List.map parsed_tr li)
	      | If(e,it,ie) -> 
		 let tr_ie = match ie with
		   | None -> None
		   | Some ie -> Some(parsed_tr ie) in
		 If(parsed_expr_tr e,parsed_tr it,tr_ie)
	      | Store(l,e,mo) -> Store(l,parsed_expr_tr e,mo)
	      | Lock _ | Unlock _ as i -> i
	      | Symb _ -> Warn.fatal "No term variable allowed"

	    let get_naccesses =

              let get_loc k = function
                | Mem _ -> k+1
                | Reg _ -> k in

              let rec get_exp k = function
                | Const _ -> k
                | Load (loc,None) -> get_loc k loc
                | Load (loc,Some _) -> get_loc (k+1) loc
                | Op (_,e1,e2) -> get_exp (get_exp k e1) e2
                | Fetch (_,_,e,_)
                | Exchange (_,e,_) -> get_exp (k+2) e in

              let rec get_rec k = function
                | Fence _|Symb _-> k
                | Seq seq -> List.fold_left get_rec k seq
                | If (cond,ifso,ifno) ->
                    let k = get_exp k cond in
                    get_opt (get_rec k ifso) ifno
                | Store (loc,e,None) -> get_exp (get_loc k loc) e
                | Store (loc,e,Some _) -> get_exp (get_loc (k+1) loc) e
                | Lock _|Unlock _ -> k+1

              and get_opt k = function
                | None -> k
                | Some i -> get_rec k i in

              fun i -> get_rec 0 i


	    let fold_labels acc _f _ins = acc
	    let map_labels _f ins = ins
	  end)

let get_macro _s = assert false
