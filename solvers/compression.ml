open Core


open Gc

open Tower
open Utils
open Type
open Program
open Enumeration
open Task
open Grammar

(* open Eg *)
open Versions

let verbose_compression = ref false;;

let restrict ~topK g frontier =
  let restriction =
    frontier.programs |> List.map ~f:(fun (p,ll) ->
        (ll+.likelihood_under_grammar g frontier.request p,p,ll)) |>
    sort_by (fun (posterior,_,_) -> 0.-.posterior) |>
    List.map ~f:(fun (_,p,ll) -> (p,ll))
  in
  {request=frontier.request; programs=List.take restriction topK}


let inside_outside ~pseudoCounts g (frontiers : frontier list) =
  let summaries = frontiers |> List.map ~f:(fun f ->
      f.programs |> List.map ~f:(fun (p,l) ->
          let s = make_likelihood_summary g f.request p in
          (l, s))) in

  let update g =
    let weighted_summaries = summaries |> List.map ~f:(fun ss ->
        let log_weights = ss |> List.map ~f:(fun (l,s) ->
            l+. summary_likelihood g s) in
        let z = lse_list log_weights in
        List.map2_exn log_weights ss ~f:(fun lw (_,s) -> (exp (lw-.z),s))) |>
                             List.concat
    in

    let s = mix_summaries weighted_summaries in
    let possible p = Hashtbl.fold ~init:0. s.normalizer_frequency  ~f:(fun ~key ~data accumulator ->
        if List.mem ~equal:program_equal key p then accumulator+.data else accumulator)
    in
    let actual p = match Hashtbl.find s.use_frequency p with
      | None -> 0.
      | Some(f) -> f
    in

    {g with
     logVariable = log (actual (Index(0)) +. pseudoCounts) -. log (possible (Index(0)) +. pseudoCounts);
     library = g.library |> List.map ~f:(fun (p,t,_,u) ->
         let l = log (actual p +. pseudoCounts) -. log (possible p +. pseudoCounts) in
       (p,t,l,u))}
  in
  let g = update g in
  (g,
   summaries |> List.map ~f:(fun ss ->
     ss |> List.map ~f:(fun (l,s) -> l+. summary_likelihood g s) |> lse_list) |> fold1 (+.))
    
    
let grammar_induction_score ~aic ~structurePenalty ~pseudoCounts frontiers g =
  let g,ll = inside_outside ~pseudoCounts g frontiers in

    let production_size = function
      | Primitive(_,_,_) -> 1
      | Invented(_,e) -> program_size e
      | _ -> raise (Failure "Element of grammar is neither primitive nor invented")
    in 

    (g,
     ll-. aic*.(List.length g.library |> Float.of_int) -.
     structurePenalty*.(g.library |> List.map ~f:(fun (p,_,_,_) ->
         production_size p) |> sum |> Float.of_int))

  

exception EtaExpandFailure;;

let eta_long request e =
  let context = ref empty_context in

  let make_long e request =
    if is_arrow request then Some(Abstraction(Apply(shift_free_variables 1 e, Index(0)))) else None
  in 

  let rec visit request environment e = match e with
    | Abstraction(b) when is_arrow request ->
      Abstraction(visit (right_of_arrow request) (left_of_arrow request :: environment) b)
    | Abstraction(_) -> raise EtaExpandFailure
    | _ -> match make_long e request with
      | Some(e') -> visit request environment e'
      | None -> (* match e with *)
        (* | Index(i) -> (unify' context request (List.nth_exn environment i); e) *)
        (* | Primitive(t,_,_) | Invented(t,_) -> *)
        (*   (let t = instantiate_type' context t in *)
        (*    unify' context t request; *)
        (*    e) *)
        (* | Abstraction(_) -> assert false *)
        (* | Apply(_,_) -> *)
        let f,xs = application_parse e in
        let ft = match f with
          | Index(i) -> environment $$ i |> applyContext' context
          | Primitive(t,_,_) | Invented(t,_) -> instantiate_type' context t
          | Abstraction(_) -> assert false (* not in beta long form *)
          | Apply(_,_) -> assert false
        in
        unify' context request (return_of_type ft);
        let ft = applyContext' context ft in
        let xt = arguments_of_type ft in
        if List.length xs <> List.length xt then raise EtaExpandFailure else
          let xs' =
            List.map2_exn xs xt ~f:(fun x t -> visit (applyContext' context t) environment x)
          in
          List.fold_left xs' ~init:f ~f:(fun return_value x ->
              Apply(return_value,x))
  in

  let e' = visit request [] e in
  
  assert (tp_eq
            (e |> closed_inference |> canonical_type)
            (e' |> closed_inference |> canonical_type));
  e'
;;

let normalize_invention i =
  (* Raises UnificationFailure if i is not well typed *)
  let mapping = free_variables i |> List.dedup_and_sort ~compare:(-) |> List.mapi ~f:(fun i v -> (v,i)) in

  let rec visit d = function
    | Index(i) when i < d -> Index(i)
    | Index(i) -> Index(d + List.Assoc.find_exn ~equal:(=) mapping (i - d))
    | Abstraction(b) -> Abstraction(visit (d + 1) b)
    | Apply(f,x) -> Apply(visit d f,
                          visit d x)
    | Primitive(_,_,_) | Invented(_,_) as e -> e
  in
  
  let renamed = visit 0 i in
  let abstracted = List.fold_right mapping ~init:renamed ~f:(fun _ e -> Abstraction(e)) in
  make_invention abstracted
    

let rewrite_with_invention i =
  (* Raises EtaExpandFailure if this is not successful *)
  let mapping = free_variables i |> List.dedup_and_sort ~compare:(-) |> List.mapi ~f:(fun i v -> (i,v)) in
  let closed = normalize_invention i in
  (* FIXME : no idea whether I got this correct or not... *)
  let applied_invention = List.fold_left ~init:closed
      (List.range ~start:`exclusive ~stop:`inclusive ~stride:(-1) (List.length mapping) 0)
      ~f:(fun e i -> Apply(e,Index(List.Assoc.find_exn ~equal:(=) mapping i)))
  in

  let rec visit e =
    if program_equal e i then applied_invention else
      match e with
      | Apply(f,x) -> Apply(visit f, visit x)
      | Abstraction(b) -> Abstraction(visit b)
      | Index(_) | Primitive(_,_,_) | Invented(_,_) -> e
  in
  fun request e ->
    let e' = visit e |> eta_long request in
    assert (program_equal
              (beta_normal_form ~reduceInventions:true e)
              (beta_normal_form ~reduceInventions:true e'));
    e'

let nontrivial e =
  let indices = ref [] in
  let duplicated_indices = ref 0 in
  let primitives = ref 0 in
  let rec visit d = function
    | Index(i) ->
      let i = i - d in
      if List.mem ~equal:(=) !indices i
      then incr duplicated_indices
      else indices := i :: !indices
    | Apply(f,x) -> (visit d f; visit d x)
    | Abstraction(b) -> visit (d + 1) b
    | Primitive(_,_,_) | Invented(_,_) -> incr primitives
  in
  visit 0 e;
  !primitives > 1 || !primitives = 1 && !duplicated_indices > 0
;;

open Zmq

type worker_command =
  | Rewrite of program list
  | RewriteEntireFrontiers of program
  | KillWorker
    
let compression_worker connection ~arity ~bs ~topK g frontiers =
  let context = Zmq.Context.create() in
  let socket = Zmq.Socket.create context Zmq.Socket.req in
  Zmq.Socket.connect socket connection;
  let send data = Zmq.Socket.send socket (Marshal.to_string data []) in
  let receive() = Marshal.from_string (Zmq.Socket.recv socket) 0 in


  let original_frontiers = frontiers in
  let frontiers = ref (List.map ~f:(restrict ~topK g) frontiers) in

  let v = new_version_table() in
  let cost_table = empty_cost_table v in

  (* calculate candidates from the frontiers we can see *)
  let frontier_indices : int list list = time_it ~verbose:!verbose_compression
      "(worker) calculated version spaces" (fun () ->
      !frontiers |> List.map ~f:(fun f -> f.programs |> List.map ~f:(fun (p,_) ->
              incorporate v p |> n_step_inversion v ~n:arity))) in
  if !verbose_compression then
    Printf.eprintf "(worker) %d distinct version spaces enumerated; %d accessible vs size; vs log sizes: %s\n"
      v.i2s.ra_occupancy
      (frontier_indices |> List.concat |> reachable_versions v |> List.length)
      (frontier_indices |> List.concat |> List.map ~f:(Float.to_string % log_version_size v)
       |> join ~separator:"; ");
  
  let candidates : program list list = time_it ~verbose:!verbose_compression "(worker) proposed candidates"
      (fun () ->
      let reachable : int list list = frontier_indices |> List.map ~f:(reachable_versions v) in
      let inhabitants : program list list = reachable |> List.map ~f:(fun indices ->
          List.concat_map ~f:(snd % minimum_cost_inhabitants cost_table) indices |>
          List.dedup_and_sort ~compare:(-) |> 
          List.map ~f:(List.hd_exn % extract v) |>
          List.filter ~f:nontrivial) in 
          inhabitants)
  in

  (* relay this information to the master, whose job it is to pool the candidates *)
  send candidates;  
  let candidates : program list = receive() in
  let candidates : int list = candidates |> List.map ~f:(incorporate v) in
  
  if !verbose_compression then
    (Printf.eprintf "(worker) Got %d candidates.\n" (List.length candidates);
     flush_everything());

  let candidate_scores : float list = time_it ~verbose:!verbose_compression "(worker) beamed version spaces"
      (fun () ->
      beam_costs' ~ct:cost_table ~bs candidates frontier_indices)
  in

  send candidate_scores;
   (* I hope that this leads to garbage collection *)
  let candidate_scores = ()
  and cost_table = ()
  in

  let rewrite_frontiers invention_source =
    let i = incorporate v invention_source in
    let rewriter = rewrite_with_invention invention_source in
    (* Extract the frontiers in terms of the new primitive *)
    let new_cost_table = empty_cost_table v in
    let new_frontiers = List.map !frontiers
        ~f:(fun frontier ->
            let programs' =
              List.map frontier.programs ~f:(fun (originalProgram, ll) ->
                  let index = incorporate v originalProgram |> n_step_inversion v ~n:arity in
                  let program = minimum_cost_inhabitants new_cost_table ~given:(Some(i)) index |> snd |> 
                                List.hd_exn |> extract v |> singleton_head in
                  let program' =
                    try rewriter frontier.request program
                    with EtaExpandFailure -> originalProgram
                  in
                  (program',ll))
            in 
            {request=frontier.request;
             programs=programs'})
    in
    new_frontiers
  in 

  while true do
    match receive() with
    | Rewrite(i) -> send (i |> List.map ~f:rewrite_frontiers)
    | RewriteEntireFrontiers(i) ->
      (frontiers := original_frontiers;
       send (rewrite_frontiers i))
    | KillWorker -> 
       (Zmq.Socket.close socket;
        Zmq.Context.terminate context;
       exit 0)
  done;;

let compression_step_master ~nc ~structurePenalty ~aic ~pseudoCounts ?arity:(arity=3) ~bs ~topI ~topK g frontiers =

  let sockets = ref [] in
  let fork_worker frontiers =
    let p = List.length !sockets in
    let address = Printf.sprintf "ipc:///tmp/compression_ipc_%d" p in
    sockets := !sockets @ [address];

    match Unix.fork() with
    | `In_the_child -> compression_worker address ~arity ~bs ~topK g frontiers
    | _ -> ()
  in

  let divide_work_fairly nc xs =
    let nt = List.length xs in
    let base_count = nt/nc in
    let residual = nt - base_count*nc in
    let rec partition residual xs =
      let this_count =
        base_count + (if residual > 0 then 1 else 0)
      in
      match xs with
      | [] -> []
      | _ :: _ ->
        let prefix, suffix = List.split_n xs this_count in
        prefix :: partition (residual - 1) suffix
    in
    partition residual xs
  in
  let start_time = Time.now () in
  divide_work_fairly nc frontiers |> List.iter ~f:fork_worker;

  (* Now that we have created the workers, we can make our own sockets *)
  let context = Zmq.Context.create() in
  let sockets = !sockets |> List.map ~f:(fun address ->
      let socket = Zmq.Socket.create context Zmq.Socket.rep in
      Zmq.Socket.bind socket address;
      socket)
  in
  let send data =
    let data = Marshal.to_string data [] in
    sockets |> List.iter ~f:(fun socket -> Zmq.Socket.send socket data)
  in
  let receive socket = Marshal.from_string (Zmq.Socket.recv socket) 0 in
  let finish() =
    send KillWorker;
    sockets |> List.iter ~f:(fun s -> Zmq.Socket.close s);
    Zmq.Context.terminate context
  in 
    
    
  
  let candidates : program list list = sockets |> List.map ~f:(fun s -> receive s) |> List.concat in  
  let candidates : program list = occurs_multiple_times (List.concat candidates) in
  Printf.eprintf "Total number of candidates: %d\n" (List.length candidates);
  Printf.eprintf "Constructed version spaces and coalesced candidates in %s.\n"
    (Time.diff (Time.now ()) start_time |> Time.Span.to_string);
  flush_everything();
  
  send candidates;

  let candidate_scores : float list list =
    sockets |> List.map ~f:(fun s -> let ss : float list = receive s in ss)
  in
  if !verbose_compression then (Printf.eprintf "(master) Received worker beams\n"; flush_everything());
  let candidates : program list = 
    candidate_scores |> List.transpose_exn |>
    List.map ~f:(fold1 (+.)) |> List.zip_exn candidates |>
    List.sort ~compare:(fun (_,s1) (_,s2) -> Float.compare s1 s2) |> List.map ~f:fst
  in
  let candidates = List.take candidates topI in
  let candidates = candidates |> List.filter ~f:(fun candidate ->
      try
        let candidate = normalize_invention candidate in
        not (List.mem ~equal:program_equal (grammar_primitives g) candidate)
      with UnificationFailure -> false) (* not well typed *)
  in
  Printf.eprintf "Trimmed down the beam, have only %d best candidates\n"
    (List.length candidates);
  flush_everything();

  match candidates with
  | [] -> (finish(); None)
  | _ -> 

  (* now we have our final list of candidates! *)
  (* ask each of the workers to rewrite w/ each candidate *)
  send @@ Rewrite(candidates);
  (* For each invention, the full rewritten frontiers *)
  let new_frontiers : frontier list list =
    time_it "Rewrote topK" (fun () ->
        sockets |> List.map ~f:receive |> List.transpose_exn |> List.map ~f:List.concat)
  in
  assert (List.length new_frontiers = List.length candidates);
  
  let score frontiers candidate =
    let new_grammar = uniform_grammar (normalize_invention candidate :: grammar_primitives g) in
    let g',s = grammar_induction_score ~aic ~pseudoCounts ~structurePenalty frontiers new_grammar in
    if !verbose_compression then
      (let source = normalize_invention candidate in
       Printf.eprintf "Invention %s : %s\n\tContinuous score %f\n"
         (string_of_program source)
         (closed_inference source |> string_of_type)
         s;
       frontiers |> List.iter ~f:(fun f -> Printf.eprintf "%s\n" (string_of_frontier f));
       Printf.eprintf "\n"; flush_everything());
    (g',s)
  in 
  
  let _,initial_score = grammar_induction_score ~aic ~structurePenalty ~pseudoCounts
      (frontiers |> List.map ~f:(restrict ~topK g)) g
  in
  Printf.eprintf "Initial score: %f\n" initial_score;

  let (g',best_score), best_candidate = time_it "Scored candidates" (fun () ->
      List.map2_exn candidates new_frontiers ~f:(fun candidate frontiers ->
          (score frontiers candidate, candidate)) |> minimum_by (fun ((_,s),_) -> -.s))
  in
  if best_score < initial_score then
      (Printf.eprintf "No improvement possible.\n"; finish(); None)
    else
      (let new_primitive = grammar_primitives g' |> List.hd_exn in
       Printf.eprintf "Improved score to %f (dScore=%f) w/ new primitive\n\t%s : %s\n"
         best_score (best_score-.initial_score)
         (string_of_program new_primitive) (closed_inference new_primitive |> canonical_type |> string_of_type);
       flush_everything();
       (* Rewrite the entire frontiers *)
       let frontiers'' = time_it "rewrote all of the frontiers" (fun () ->
           send @@ RewriteEntireFrontiers(best_candidate);
           sockets |> List.map ~f:receive |> List.concat)
       in
       finish();
       let g'' = inside_outside ~pseudoCounts g' frontiers'' |> fst in
       Some(g'',frontiers''))

        
  

  
  
  
  
  
let compression_step ~structurePenalty ~aic ~pseudoCounts ?arity:(arity=3) ~bs ~topI ~topK g frontiers =

  let restrict frontier =
    let restriction =
      frontier.programs |> List.map ~f:(fun (p,ll) ->
          (ll+.likelihood_under_grammar g frontier.request p,p,ll)) |>
      sort_by (fun (posterior,_,_) -> 0.-.posterior) |>
      List.map ~f:(fun (_,p,ll) -> (p,ll))
    in
    {request=frontier.request; programs=List.take restriction topK}
  in

  let original_frontiers = frontiers in
  let frontiers = ref (List.map ~f:restrict frontiers) in
  
  let score g frontiers =
    grammar_induction_score ~aic ~pseudoCounts ~structurePenalty frontiers g
  in
  
  let v = new_version_table() in
  let cost_table = empty_cost_table v in

  (* calculate candidates *)
  let frontier_indices : int list list = time_it "calculated version spaces" (fun () ->
      !frontiers |> List.map ~f:(fun f -> f.programs |> List.map ~f:(fun (p,_) ->
          incorporate v p |> n_step_inversion v ~n:arity))) in
  

  let candidates : int list = time_it "proposed candidates" (fun () ->
      let reachable : int list list = frontier_indices |> List.map ~f:(reachable_versions v) in
      let inhabitants : int list list = reachable |> List.map ~f:(fun indices ->
          List.concat_map ~f:(snd % minimum_cost_inhabitants cost_table) indices |>
          List.dedup_and_sort ~compare:(-)) in
      inhabitants |> List.concat |> occurs_multiple_times)
  in
  let candidates = candidates |> List.filter ~f:(fun candidate ->
      let candidate = List.hd_exn (extract v candidate) in
      try (ignore(normalize_invention candidate); nontrivial candidate)
      with UnificationFailure -> false)
  in 
  Printf.eprintf "Got %d candidates.\n" (List.length candidates);

  match candidates with
  | [] -> None
  | _ -> 

    let ranked_candidates = time_it "beamed version spaces" (fun () ->
        beam_costs ~ct:cost_table ~bs candidates frontier_indices)
    in
    let ranked_candidates = List.take ranked_candidates topI in

    let try_invention_and_rewrite_frontiers (i : int) =
      let invention_source = extract v i |> singleton_head in
      try
        let new_primitive = invention_source |> normalize_invention in
        if List.mem ~equal:program_equal (grammar_primitives g) new_primitive then raise DuplicatePrimitive;
        let new_grammar =
          uniform_grammar (new_primitive :: (grammar_primitives g))
        in 

        let rewriter = rewrite_with_invention invention_source in
        (* Extract the frontiers in terms of the new primitive *)
        let new_cost_table = empty_cost_table v in
        let new_frontiers = List.map !frontiers
            ~f:(fun frontier ->
                let programs' =
                  List.map frontier.programs ~f:(fun (originalProgram, ll) ->
                      let index = incorporate v originalProgram |> n_step_inversion v ~n:arity in
                      let program = minimum_cost_inhabitants new_cost_table ~given:(Some(i)) index |> snd |> 
                                    List.hd_exn |> extract v |> singleton_head in
                      let program' =
                        try rewriter frontier.request program
                        with EtaExpandFailure -> originalProgram
                      in
                      (program',ll))
                in 
                {request=frontier.request;
                 programs=programs'})
        in
        let new_grammar,s = score new_grammar new_frontiers in
        (s,new_grammar,new_frontiers)
      with UnificationFailure | DuplicatePrimitive -> (* ill-typed / duplicatedprimitive *)
        (Float.neg_infinity, g, !frontiers)
    in

    let _,initial_score = score g !frontiers in
    Printf.eprintf "Initial score: %f\n" initial_score;


    let best_score,g',frontiers',best_index =
      time_it (Printf.sprintf "Evaluated top-%d candidates" topI) (fun () -> 
      ranked_candidates |> List.map ~f:(fun (c,i) ->
          let source = extract v i |> singleton_head in
          let source = normalize_invention source in

          let s,g',frontiers' = try_invention_and_rewrite_frontiers i in
          if !verbose_compression then
            (Printf.eprintf "Invention %s : %s\nDiscrete score %f\n\tContinuous score %f\n"
              (string_of_program source)
              (closed_inference source |> string_of_type)
              c s;
             frontiers' |> List.iter ~f:(fun f -> Printf.eprintf "%s\n" (string_of_frontier f));
             Printf.eprintf "\n"; flush_everything());
          (s,g',frontiers',i))
      |> minimum_by (fun (s,_,_,_) -> -.s)) in

    if best_score < initial_score then
      (Printf.eprintf "No improvement possible.\n"; None)
    else
      (let new_primitive = grammar_primitives g' |> List.hd_exn in
       Printf.eprintf "Improved score to %f (dScore=%f) w/ new primitive\n\t%s : %s\n"
         best_score (best_score-.initial_score)
         (string_of_program new_primitive) (closed_inference new_primitive |> canonical_type |> string_of_type);
       flush_everything();
       (* Rewrite the entire frontiers *)
       frontiers := original_frontiers;
       let _,g'',frontiers'' = time_it "rewrote all of the frontiers" (fun () ->
           try_invention_and_rewrite_frontiers best_index)
       in

       Some(g'',frontiers''))
;;

let compression_loop
    ?nc:(nc=1) ~structurePenalty ~aic ~topK ~pseudoCounts ?arity:(arity=3) ~bs ~topI g frontiers =

  let find_new_primitive old_grammar new_grammar =
    new_grammar |> grammar_primitives |> List.filter ~f:(fun p ->
        not (List.mem ~equal:program_equal (old_grammar |> grammar_primitives) p)) |>
    singleton_head
  in
  let illustrate_new_primitive new_grammar primitive frontiers =
    let illustrations = 
      frontiers |> List.filter_map ~f:(fun frontier ->
          let best_program = (restrict ~topK:1 new_grammar frontier).programs |> List.hd_exn |> fst in
          if List.mem ~equal:program_equal (program_subexpressions best_program) primitive then
            Some(best_program)
          else None)
    in
    Printf.eprintf "New primitive is used %d times in the best programs in each of the frontiers.\n"
      (List.length illustrations);
    Printf.eprintf "Here is where it is used:\n";
    illustrations |> List.iter ~f:(fun program -> Printf.eprintf "  %s\n" (string_of_program program))
  in 

  let step = if nc = 1 then compression_step else compression_step_master ~nc in 

  let rec loop g frontiers = 
    match step ~structurePenalty ~topK ~aic ~pseudoCounts ~arity ~bs ~topI g frontiers with
    | None -> g, frontiers
    | Some(g',frontiers') ->
      illustrate_new_primitive g' (find_new_primitive g g') frontiers';
      flush_everything();
      loop g' frontiers'
  in
  time_it "completed ocaml compression" (fun () ->
      loop g frontiers)
;;

  




  
  

let () =
  let open Yojson.Basic.Util in
  let open Yojson.Basic in
  let j =
    if Array.length Sys.argv > 1 then
      (assert (Array.length Sys.argv = 2);
       Yojson.Basic.from_file Sys.argv.(1))
    else 
      Yojson.Basic.from_channel Pervasives.stdin
  in
  let g = j |> member "DSL" |> deserialize_grammar |> strip_grammar in
  let topK = j |> member "topK" |> to_int in
  let topI = j |> member "topI" |> to_int in
  let bs = j |> member "bs" |> to_int in
  let arity = j |> member "arity" |> to_int in
  let aic = j |> member "aic" |> to_float in
  let pseudoCounts = j |> member "pseudoCounts" |> to_float in
  let structurePenalty = j |> member "structurePenalty" |> to_float in

  verbose_compression := (try
      j |> member "verbose" |> to_bool
                          with _ -> false);

  let nc =
    try j |> member "CPUs" |> to_int
    with _ -> 1
  in

  let frontiers = j |> member "frontiers" |> to_list |> List.map ~f:deserialize_frontier in
  
  let g, frontiers = compression_loop ~nc ~topK ~aic ~structurePenalty ~pseudoCounts ~arity ~topI ~bs g frontiers in

  let j = `Assoc(["DSL",serialize_grammar g;
                  "frontiers",`List(frontiers |> List.map ~f:serialize_frontier)])
  in
  pretty_to_string j |> print_string
