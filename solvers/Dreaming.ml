open Core

open Pregex
open Program
open Enumeration
open Grammar
open Utils
open Timeout
open Type
open Tower
    
open Yojson.Basic

let remove_bad_dreams behavior_to_programs =
  let start_time = Time.now () in
  
  let containers = Hashtbl.Poly.create() in
  let output_vectors = empty_resizable() in
  
  Hashtbl.iteri behavior_to_programs ~f:(fun ~key ~data ->
      let this_index = output_vectors.ra_occupancy in
      push_resizable output_vectors (key, data);

      let _, outputs = key in
      outputs |> List.iteri ~f:(fun output_index this_output ->
          (* Record that we are one of the behaviors that produces this output *)
          if this_output = `Null then () else
            match Hashtbl.find containers (output_index, this_output) with
            | None -> Hashtbl.set containers ~key:(output_index, this_output)
                        ~data:(Int.Set.singleton this_index)
            | Some(others) -> Hashtbl.set containers ~key:(output_index, this_output)
                                ~data:(Int.Set.add others this_index)
        ));

  (* Checks whether there exists another output vector that contains everything in this vector *)
  let is_bad_index i =
    let dominating = ref None in 
    
    let (_, outputs), _ = get_resizable output_vectors i in
    outputs |> List.iteri ~f:(fun output_index this_output ->
        if this_output = `Null then () else
          match Hashtbl.find containers (output_index, this_output) with
          | None -> assert (false)
          | Some(others) ->
            match !dominating with
            | None -> dominating := Some(others)
            | Some(d) -> dominating := Some(Int.Set.inter d others));
    let nightmare = Int.Set.length (!dominating |> get_some) > 1 in
    if nightmare then begin 
      Printf.eprintf "NIGHTMARE!!!";
      get_resizable output_vectors i |> snd |> snd |> List.iter ~f:(fun p -> p |> string_of_program |> Printf.eprintf "%s\n")
    end;
    nightmare
  in

  let number_of_nightmares = ref 0 in
  let sweet_dreams = 
    List.range 0 output_vectors.ra_occupancy |>
    List.filter_map ~f:(fun i ->
        if is_bad_index i then (incr number_of_nightmares; None) else
          Some(get_resizable output_vectors i))  
  in
  Printf.eprintf "Removed %d nightmares in %s.\n"
    (!number_of_nightmares) (Time.diff (Time.now ()) start_time |> Time.Span.to_string);
  sweet_dreams

  
let helmholtz_enumeration (behavior_hash : program -> (int*(json list)) option) ?nc:(nc=1) g request ~timeout ~maximumSize =
  assert (nc = 1); (* FIXME *)
  
  let behavior_to_programs = Hashtbl.Poly.create() in

  let update ~key ~data =
    let l,ps = data in
    match Hashtbl.find behavior_to_programs key with
    | None -> Hashtbl.set behavior_to_programs ~key ~data:data
    | Some((l',_)) when l' < l -> Hashtbl.set behavior_to_programs ~key ~data
    | Some((l',_)) when l' > l -> ()
    | Some((_,ps')) ->
      Hashtbl.set behavior_to_programs ~key ~data:(l, ps @ ps' |> List.dedup_and_sort ~compare:compare_program)
  in

  let merge other =
    Hashtbl.iteri other ~f:update
  in 

  set_enumeration_timeout timeout;

  let rec loop lb =
    if enumeration_timed_out() then () else begin 
      let final_results = 
        enumerate_programs ~extraQuiet:true ~nc:nc ~final:(fun () -> [behavior_to_programs])
          g request lb (lb+.1.5) (fun p l ->
              if Hashtbl.length behavior_to_programs > maximumSize then set_enumeration_timeout (-1.0) else
                match behavior_hash p with
                | Some(key) -> update ~key ~data:(l,[p])
                | None -> ()
            ) |> List.concat
      in
      if nc > 1 then final_results |> List.iter ~f:merge;
      loop (lb+.1.5)
    end
  in

  loop 0.;

  behavior_to_programs

let rec unpack x =
  let open Yojson.Basic.Util in
  
  try magical (x |> to_int) with _ ->
  try magical (x |> to_float) with _ ->
  try magical (x |> to_bool) with _ ->
  try
    let v = x |> to_string in
    if String.length v = 1 then magical v.[0] else magical v
  with _ ->
  try
    x |> to_list |> List.map ~f:unpack |> magical
  with _ -> raise (Failure "could not unpack")

let rec pack t v : json =
  let open Yojson.Basic.Util in
  match t with
  | TCon("list",[t'],_) -> `List(magical v |> List.map ~f:(pack t'))
  | TCon("int",[],_) -> `Int(magical v)
  | TCon("bool",[],_) -> `Bool(magical v)
  | TCon("char",[],_) -> `String(magical v |> String.of_char)
  | _ -> assert false

let rec hash_json (j : json) : int =
  match j with
  | `List(xs) -> List.fold_right ~init:17 ~f:(fun x h -> Hashtbl.hash (h, hash_json x)) xs
  | `Int(n) -> Hashtbl.hash n
  | `String(x) -> Hashtbl.hash x
  | `Bool(x) -> Hashtbl.hash x
  | `Null -> Hashtbl.hash None
  | _ -> assert false

let special_helmholtz =   Hashtbl.Poly.create();;
let register_special_helmholtz name handle = Hashtbl.set special_helmholtz name handle;;


let default_hash ?timeout:(timeout=0.001) request inputs : program -> (int*(json list)) option =
  let open Yojson.Basic.Util in

  (* convert json -> ocaml *)
  let inputs : 'a list list = unpack inputs in
  let return = return_of_type request in

  fun program ->
    let p = analyze_lazy_evaluation program in
    let outputs = inputs |> List.map ~f:(fun input ->
        try
          match run_for_interval timeout                  
                  (fun () -> run_lazy_analyzed_with_arguments p input)
          with
          | Some(value) -> Some(value |> pack return)            
          | _ -> None
        with (* We have to be a bit careful with exceptions if the
              * synthesized program generated an exception, then we just
              * terminate w/ false but if the enumeration timeout was
              * triggered during program evaluation, we need to pass the
              * exception on
             *)
        | UnknownPrimitive(n) -> raise (Failure ("Unknown primitive: "^n))
        | _                   -> None) in
    if List.exists outputs ~f:is_some then
      let outputs' = outputs |> List.map ~f:(function
          | None -> `Null
          | Some(j) -> j) in
      Some((hash_json (`List(outputs')), outputs'))
    else None

let string_hash ?timeout:(timeout=0.001) request inputs : program -> (int*(json list)) option =
  let open Yojson.Basic.Util in

  (* convert json -> ocaml *)
  let inputs : 'a list list = unpack inputs in
  let return = return_of_type request in

  let testConstants=["x4";"a bc d"]  in
  let constants = testConstants |> List.map ~f:String.to_list in 

  fun program ->
    let constant_results = (* results from substituting with each constant *)
      constants |> List.concat_map ~f:(fun constant ->
          match substitute_string_constants [constant] program with
          | [program'] -> 
            let p = analyze_lazy_evaluation program' in    
            inputs |> List.map ~f:(fun input ->
                try
                  match run_for_interval timeout (fun () -> run_lazy_analyzed_with_arguments p input) with
                  | Some(value) -> value |> pack return
                  | _ -> `Null
                with
                | UnknownPrimitive(n) -> raise (Failure ("Unknown primitive: "^n))
                | _                   -> `Null)
          | _ -> assert false)
    in
    if List.exists constant_results ~f:(function | `Null -> false | _ -> true) then
      Some((`List(constant_results) |> hash_json, constant_results))
    else None
;;


register_special_helmholtz "string" string_hash;;

let tower_hash ?timeout:(timeout=0.001) request inputs : program -> (int*(json list)) option =
  let open Yojson.Basic.Util in

  assert (request = (ttower @> ttower));
  
  fun program ->
    let arrangement = evaluate_discrete_tower_program timeout program in
    let l = List.length arrangement in
    let w = blocks_extent arrangement in
    let h = tower_height arrangement in
    if l = 0 || l > 100 || w > 360 || h > 250 then None else
      let j = `List(arrangement |> List.map ~f:(fun (a,b,c,d) -> `List([`Int(a);
                                                                        `Int(b);
                                                                        `Int(c);
                                                                        `Int(d);]))) in
      Some((hash_json j, [j]))
;;
register_special_helmholtz "tower" tower_hash;;

let logo_hash ?timeout:(timeout=0.001) request inputs : program -> (int*(json list)) option =
  let open Yojson.Basic.Util in

  assert (request = (turtle @> turtle));
  
  let table = Hashtbl.Poly.create() in

  fun program ->
    let p = analyze_lazy_evaluation program in
    let l = run_for_interval timeout (fun () ->
        let x = run_lazy_analyzed_with_arguments p [] in
        let l = LogoLib.LogoInterpreter.turtle_to_list x in
        if not (LogoLib.LogoInterpreter.logo_contained_in_canvas l) then None else 
          match Hashtbl.find table l with
          | Some(a) -> Some(a)
          | None -> begin
              let a = LogoLib.LogoInterpreter.turtle_to_array x 28 in
              Hashtbl.set table ~key:l ~data:a;
              Some(a)
            end)
    in
    match l with
    | None -> None (* timeout *)
    | Some(None) -> None (* escaped the canvas *)
    | Some(Some(a)) ->
      let j = `List(range (28*28) |> List.map ~f:(fun i -> `Int(a.{i}))) in
      Some(((hash_json j, [j])));;
register_special_helmholtz "LOGO" logo_hash;;

let regex_hash  ?timeout:(timeout=0.001) request inputs : program -> (int*(json list)) option =
  let open Yojson.Basic.Util in
  assert (request = (tregex @> tregex));


  fun expression ->
    run_for_interval timeout
      (fun () -> 
         let r = expression |> regex_of_program |> canonical_regex in
         let h = hash_regex r in
         (* TODO: the json should actually incurred the regular expression *)
         (h, [`Int(h)]))
;;
register_special_helmholtz "regex" regex_hash;;
