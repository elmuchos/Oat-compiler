(** Alias Analysis *)

open Ll
open Datastructures

(* The lattice of abstract pointers ----------------------------------------- *)
module SymPtr =
  struct
    type t = MayAlias           (* uid names a pointer that may be aliased *)
           | Unique             (* uid is the unique name for a pointer *)
           | UndefAlias         (* uid is not in scope or not a pointer *)

    let compare : t -> t -> int = Stdlib.compare

    let to_string = function
      | MayAlias -> "MayAlias"
      | Unique -> "Unique"
      | UndefAlias -> "UndefAlias"

  end

(* The analysis computes, at each program point, which UIDs in scope are a unique name
   for a stack slot and which may have aliases *)
type fact = SymPtr.t UidM.t

(* flow function across Ll instructions ------------------------------------- *)
(* TASK: complete the flow function for alias analysis. 

   - After an alloca, the defined UID is the unique name for a stack slot
   - A pointer returned by a load, call, bitcast, or GEP may be aliased
   - A pointer passed as an argument to a call, bitcast, GEP, or store
     (as the value being stored) may be aliased
   - Other instructions do not define pointers

 *)
let insn_flow ((u,i):uid * insn) (d:fact) : fact =
  match i with
  | Alloca _ -> UidM.add u SymPtr.Unique d
  | Load (Ptr (Ptr _), _) -> UidM.add u SymPtr.MayAlias d
  | Store (Ptr _, Ll.Id uid1, _) -> UidM.add uid1 SymPtr.MayAlias d
  | Bitcast (Ptr _, op, _)| Gep (Ptr _, op, _) -> 
      let insn_fact = UidM.add u SymPtr.MayAlias d in
        begin match op with
          | Ll.Id uid1 -> (UidM.add uid1 SymPtr.MayAlias insn_fact)
          | _ -> insn_fact
        end
  | Call (_, Ll.Id uid1, typ_op_lst) ->
      let insn_fact = UidM.add u SymPtr.MayAlias d in
        List.fold_left (fun arg_fact (typ, op)->
                          match typ, op with
                          | Ptr _, Ll.Id uid1 -> UidM.add uid1 SymPtr.MayAlias arg_fact
                          | _ -> arg_fact) insn_fact typ_op_lst
  | _ -> d

(* The flow function across terminators is trivial: they never change alias info *)
let terminator_flow t (d:fact) : fact = d

(* module for instantiating the generic framework --------------------------- *)
module Fact =
  struct
    type t = fact
    let forwards = true

    let insn_flow = insn_flow
    let terminator_flow = terminator_flow
    
    (* UndefAlias is logically the same as not having a mapping in the fact. To
       compare dataflow facts, we first remove all of these *)
    let normalize : fact -> fact = 
      UidM.filter (fun _ v -> v != SymPtr.UndefAlias)

    let compare (d:fact) (e:fact) : int = 
      UidM.compare SymPtr.compare (normalize d) (normalize e)

    let to_string : fact -> string =
      UidM.to_string (fun _ v -> SymPtr.to_string v)

    (* TASK: complete the "combine" operation for alias analysis.

       The alias analysis should take the meet over predecessors to compute the
       flow into a node. You may find the UidM.merge function useful.

       It may be useful to define a helper function that knows how to take the
       meet of two SymPtr.t facts.
    *)
    let combine (ds:fact list) : fact =
      (* failwith "Alias.Fact.combine not implemented" *)
      let lub _key (symptr1: SymPtr.t option) (symptr2: SymPtr.t option) : SymPtr.t option =
        match symptr1, symptr2 with
        | Some symp1, Some symp2 ->
            let meet = [(SymPtr.MayAlias, 0); (SymPtr.Unique, 1); (SymPtr.UndefAlias, 2)] in
              begin if List.assoc symp1 meet < List.assoc symp2 meet
                      then symptr1
                    else symptr2
              end
        | None, symp | symp, None -> symp in 
           normalize (List.fold_left (UidM.merge lub) UidM.empty (ds))
  end

(* instantiate the general framework ---------------------------------------- *)
module Graph = Cfg.AsGraph (Fact)
module Solver = Solver.Make (Fact) (Graph)

(* expose a top-level analysis operation ------------------------------------ *)
let analyze (g:Cfg.t) : Graph.t =
  (* the analysis starts with every node set to bottom (the map of every uid 
     in the function to UndefAlias *)
  let init l = UidM.empty in

  (* the flow into the entry node should indicate that any pointer parameter 
     to the function may be aliased *)
  let alias_in = 
    List.fold_right 
      (fun (u,t) -> match t with
                    | Ptr _ -> UidM.add u SymPtr.MayAlias
                    | _ -> fun m -> m) 
      g.Cfg.args UidM.empty 
  in
  let fg = Graph.of_cfg init alias_in g in
  Solver.solve fg
