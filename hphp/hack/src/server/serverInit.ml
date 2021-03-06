(**
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

open Hh_core
open ServerEnv
open ServerCheckUtils
open Reordered_argument_collections
open Utils
open String_utils
open SearchServiceRunner

open Core_result.Export
open Core_result.Monad_infix

module DepSet = Typing_deps.DepSet
module Dep = Typing_deps.Dep
module SLC = ServerLocalConfig

type error =
  (* With_timout exceeded the timeout *)
  | Timeout of {stage: string;}
  (* With_timeout got an unhandled exception *)
  | Timeout_unhandled_exception of {stage: string; exn: exn; stack: Utils.callstack;}
  (* the hg process to fetch dirty files exited abnormally *)
  | Dirty_files_failure of Future.error
  (* the load_mini_approach passed to 'init' was None *)
  | No_loader
  (* we did an eager init; saved states aren't implemented for that case *)
  | Saved_state_not_supported_for_eager_init
  (* an unhandled exception in invoke_loading_state_natively *)
  | Download_and_load_ss_unhandled_exception of {exn: exn; stack: Utils.callstack;}
  (* an error reported by mk_state_future as invoked by invoke_loading_state_natively *)
  | Native_loader_failure of State_loader.error
  (* an unhandled exception in the lambda returned by invoke_loading_state_natively *)
  | Wait_for_dirty_unhandled_exception of {exn: exn; stack: Utils.callstack;}

type load_mini_approach =
  | Precomputed of ServerArgs.mini_state_target_info
  | Load_state_natively of bool
  | Load_state_natively_with_target of ServerMonitorUtils.target_mini_state

(** Docs are in .mli *)
type init_result =
  | Mini_load of int option
  | Mini_load_failed of string

let error_to_verbose_string (err: error) : string =
  match err with
  | Timeout {stage} ->
    Printf.sprintf "Timeout during stage %s" stage
  | Timeout_unhandled_exception {stage; exn; stack=Utils.Callstack stack;} ->
    Printf.sprintf "Unhandled exception during stage %s: %s\n%s"
      stage (Printexc.to_string exn) stack
  | Dirty_files_failure error ->
    let ({Process_types.stack=Utils.Callstack stack; _}, _) = error in
    Printf.sprintf "Hg query dirty files error: %s\n%s"
      (Future.error_to_string error) stack
  | No_loader ->
    Printf.sprintf "load_mini_approach was None"
  | Saved_state_not_supported_for_eager_init ->
    Printf.sprintf "Saved-state not supported for eager init"
  | Download_and_load_ss_unhandled_exception {exn; stack=Utils.Callstack stack;} ->
    Printf.sprintf "Unhandled exception downloading+loading ss: %s\n%s"
      (Printexc.to_string exn) stack
  | Native_loader_failure err ->
    Printf.sprintf "Error downloading saved-state: %s"
      (State_loader.error_string_verbose err)
  | Wait_for_dirty_unhandled_exception {exn; stack=Utils.Callstack stack;} ->
    Printf.sprintf "Unhandled exception waiting for dirty files: %s\n%s"
      (Printexc.to_string exn) stack

type files_changed_while_parsing = Relative_path.Set.t

type loaded_info =
{
  saved_state_fn : string;
  corresponding_rev : Hg.rev;
  mergebase_rev : Hg.svn_rev option;
  (* Files changed between saved state revision and current public merge base *)
  dirty_master_files : Relative_path.Set.t;
  (* Files changed between public merge base and current revision *)
  dirty_local_files : Relative_path.Set.t;
  old_saved : FileInfo.saved_state_info;
  old_errors : SaveStateService.saved_state_errors;
  state_distance: int option;
}



module ServerInitCommon = struct

  let lock_and_load_deptable (fn: string) ~(ignore_hh_version: bool) : unit =
    (* The sql deptable must be loaded in the master process *)
    try
      (* Take a lock on the info file for the sql *)
      LoadScriptUtils.lock_saved_state fn;
      let read_deptable_time =
        SharedMem.load_dep_table_sqlite fn ignore_hh_version
      in
      Hh_logger.log
        "Reading the dependency file took (sec): %d" read_deptable_time;
      HackEventLogger.load_deptable_end read_deptable_time;
    with
    | SharedMem.Sql_assertion_failure 11
    | SharedMem.Sql_assertion_failure 14 as e -> (* SQL_corrupt *)
      LoadScriptUtils.delete_corrupted_saved_state fn;
      raise e

  (* Return all the files that we need to typecheck *)
  let make_next_files (genv: ServerEnv.genv) : Relative_path.t list Bucket.next =
    let next_files_root = compose
      (List.map ~f:(Relative_path.(create Root)))
      (genv.indexer FindUtils.file_filter) in
    let hhi_root = Hhi.get_hhi_root () in
    let hhi_filter = FindUtils.is_php in
    let next_files_hhi = compose
      (List.map ~f:(Relative_path.(create Hhi)))
      (Find.make_next_files
         ~name:"hhi" ~filter:hhi_filter hhi_root) in
    let rec concat_next_files l () =
      begin match l with
      | [] -> []
      | hd::tl -> begin match hd () with
        | [] -> concat_next_files tl ()
        | x -> x
        end
      end
    in
    let extra_roots = ServerConfig.extra_paths genv.config in
    let next_files_extra = List.map extra_roots
      (fun root -> compose
        (List.map ~f:Relative_path.create_detect_prefix)
        (Find.make_next_files
          ~filter:FindUtils.file_filter
          root)
      ) |> concat_next_files
    in
    fun () ->
      let next = concat_next_files [next_files_hhi; next_files_extra; next_files_root] () in
      Bucket.of_list next

  let with_loader_timeout
      (timeout: int)
      (stage: string)
      (f: unit -> 'a)
    : ('a, error) result =
    try
      Timeout.with_timeout ~timeout ~do_:(fun _id -> Ok (f ()))
        ~on_timeout:(fun () -> Error (Timeout {stage}))
    with exn ->
      let stack = Utils.Callstack (Printexc.get_backtrace ()) in
      Error (Timeout_unhandled_exception {stage; exn; stack;})

(* invoke_loading_state_natively:
 * - Eagerly does mk_state_future which synchronously downloads ss and kicks of async dirty query
 * - Eagerly does lock_and_load_deptable
 * - Eagerly does load_saved_state
 * Next it returns a lamdba, so the caller can determine when the following happens:
 * - Lazily waits 200s for the async dirty query to finish
 *
 * All errors and internal exceptions are returned in the result monad.
 * In particular, you'll never see the errors from the eager steps until
 * you invoke the lambda.
 *)
  let invoke_loading_state_natively
      ?(use_canary=false)
      ?(target: ServerMonitorUtils.target_mini_state option)
      (genv: ServerEnv.genv)
      (root: Path.t)
    : unit -> (loaded_info, error) result =
    let open ServerMonitorUtils in
    let download_and_load_result = begin try
      let mini_state_handle = match target with
        | None -> None
        | Some { mini_state_everstore_handle; target_svn_rev; watchman_mergebase } ->
          Some {
            State_loader.mini_state_everstore_handle = mini_state_everstore_handle;
            mini_state_for_rev = (Hg.Svn_rev target_svn_rev);
            watchman_mergebase;
          } in
      let ignore_hh_version = ServerArgs.ignore_hh_version genv.options in
      let use_prechecked_files = ServerPrecheckedFiles.should_use genv.options genv.local_config in

      let state_future : (State_loader.native_load_result, State_loader.error) result =
        State_loader.mk_state_future
          ~config:genv.local_config.SLC.state_loader_timeouts
          ~use_canary ?mini_state_handle
          ~config_hash:(ServerConfig.config_hash genv.config) root
          ~ignore_hh_version
          ~use_prechecked_files in

      match state_future with
      | Error error ->
        Error (Native_loader_failure error)
      | Ok result ->
        lock_and_load_deptable result.State_loader.deptable_fn ~ignore_hh_version;
        let (old_saved, old_errors) =
          SaveStateService.load_saved_state result.State_loader.saved_state_fn in
        Ok (old_saved, old_errors, result)
    with exn ->
      let stack = Utils.Callstack (Printexc.get_backtrace ()) in
      Error (Download_and_load_ss_unhandled_exception {exn; stack;})
    end in

    match download_and_load_result with
    | Error err ->
      fun () -> Error err
    | Ok (old_saved, old_errors, result) ->
      (* Upon error we'll want to record the callstack associated with when *)
      (* the lazy lambda was created, not when it was invoked. *)
      let call_stack = Printexc.get_callstack 100 |> Printexc.raw_backtrace_to_string in
      fun () -> begin try
        let t = Unix.time () in
        result.State_loader.dirty_files
          (** Mercurial can respond with 90 thousand file changes in about 3 minutes. *)
          |> Future.get ~timeout:200
          |> Core_result.map_error ~f:(fun error -> Dirty_files_failure error)
          >>= fun (dirty_master_files, dirty_local_files) ->
        let () = HackEventLogger.state_loader_dirty_files t in
        let list_to_set x =
          List.map x Relative_path.from_root |> Relative_path.set_of_list in

        let dirty_master_files = list_to_set dirty_master_files in
        let dirty_local_files = list_to_set dirty_local_files in

        Ok {
          saved_state_fn = result.State_loader.saved_state_fn;
          corresponding_rev = result.State_loader.corresponding_rev;
          mergebase_rev = result.State_loader.mergebase_rev;
          dirty_master_files;
          dirty_local_files;
          old_saved;
          old_errors;
          state_distance = Some result.State_loader.state_distance;
        }
      with exn ->
        let raise_stack = Printexc.get_backtrace () in
        let stack = Utils.Callstack (Printf.sprintf "%s\nRAISED AT:\n%s" call_stack raise_stack) in
        Error (Wait_for_dirty_unhandled_exception {exn; stack;})
      end

  (* invoke_approach:
   * This returns a "double-lambda", and thus the caller determines deferred execution.
   * First lambda: upon the caller executing this, download the saved state,
   *   read some files on disk, kick off async work for an hg query, load s.s.
   *   Any and all errors in this stage are deferred until the second lambda.
   * Second lambda: upon the caller executing this, we wait up to 200s for the aysnc
   *   hg query to finish, returning either loaded_info or an error.
   *)
  let invoke_approach
      (genv: ServerEnv.genv)
      (root: Path.t)
      (approach: load_mini_approach)
    : unit -> unit -> (loaded_info, error) result =
    let ignore_hh_version = ServerArgs.ignore_hh_version genv.options in
    match approach with
    | Precomputed { ServerArgs.saved_state_fn;
      corresponding_base_revision; deptable_fn; changes; prechecked_changes } ->
      lock_and_load_deptable deptable_fn ~ignore_hh_version;
      let changes = Relative_path.set_of_list changes in
      let prechecked_changes = Relative_path.set_of_list prechecked_changes in
      let (old_saved, old_errors) = SaveStateService.load_saved_state saved_state_fn in
      let get_loaded_info = (fun () -> Ok {
        saved_state_fn;
        corresponding_rev = (Hg.Svn_rev (int_of_string (corresponding_base_revision)));
        mergebase_rev  = None;
        dirty_master_files = prechecked_changes;
        dirty_local_files = changes;
        old_saved;
        old_errors;
        state_distance = None;
      }) in
      fun () -> get_loaded_info
    | Load_state_natively use_canary ->
      fun () -> (invoke_loading_state_natively ~use_canary genv root)
    | Load_state_natively_with_target target ->
      fun () -> (invoke_loading_state_natively ~target genv root)

  let is_check_mode (options: ServerArgs.options) : bool =
    ServerArgs.check_mode options &&
    ServerArgs.convert options = None &&
    (* Note: we need to run update_files to get an accurate saved state *)
    ServerArgs.save_filename options = None

  let indexing (genv: ServerEnv.genv) : Relative_path.t list Bucket.next * float =
    let logstring = "Indexing" in
    Hh_logger.log "Begin %s" logstring;
    let t = Unix.gettimeofday () in
    let get_next = make_next_files genv in
    HackEventLogger.indexing_end t;
    let t = Hh_logger.log_duration logstring t in
    get_next, t

  let parsing
      ~(lazy_parse: bool)
      (genv: ServerEnv.genv)
      (env: ServerEnv.env)
      ~(get_next: Relative_path.t list Bucket.next)
      ?(count: int option)
      (t: float)
      ~(trace: bool)
    : ServerEnv.env * float =
    let logstring =
      match count with
      | None -> "Parsing"
      | Some c -> Printf.sprintf "Parsing %d files" c in
    Hh_logger.log "Begin %s" logstring;
    let quick = lazy_parse in
    let files_info, errorl, _=
      Parsing_service.go
        ~quick
        genv.workers
        Relative_path.Set.empty
        ~get_next
        ~trace
        env.popt in
    let files_info = Relative_path.Map.union files_info env.files_info in
    let hs = SharedMem.heap_size () in
    Hh_logger.log "Heap size: %d" hs;
    Stats.(stats.init_parsing_heap_size <- hs);
    (* TODO: log a count of the number of files parsed... 0 is a placeholder *)
    HackEventLogger.parsing_end t hs  ~parsed_count:0;
    let env = { env with
      files_info;
      errorl = Errors.merge errorl env.errorl;
    } in
    env, (Hh_logger.log_duration logstring t)

  let update_files
      (genv: ServerEnv.genv)
      (files_info: FileInfo.t Relative_path.Map.t)
      (t: float)
    : float =
    if is_check_mode genv.options then t else begin
      Typing_deps.update_files files_info;
      HackEventLogger.updating_deps_end t;
      Hh_logger.log_duration "Updating deps" t
    end

  let naming (env: ServerEnv.env) (t: float) : ServerEnv.env * float =
    let logstring = "Naming" in
    Hh_logger.log "Begin %s" logstring;
    let env =
      Relative_path.Map.fold env.files_info ~f:begin fun k v env ->
        let errorl, failed_naming = NamingGlobal.ndecl_file env.tcopt k v in
        { env with
          errorl = Errors.merge errorl env.errorl;
          failed_naming =
            Relative_path.Set.union env.failed_naming failed_naming;
        }
      end ~init:env
    in
    let hs = SharedMem.heap_size () in
    Hh_logger.log "Heap size: %d" hs;
    HackEventLogger.global_naming_end t;
    env, (Hh_logger.log_duration logstring t)

  let type_decl
      (genv: ServerEnv.genv)
      (env: ServerEnv.env)
      (fast: FileInfo.fast)
      (t: float)
    : ServerEnv.env * float =
    let logstring = "Type-decl" in
    Hh_logger.log "Begin %s" logstring;
    let bucket_size = genv.local_config.SLC.type_decl_bucket_size in
    let errorl =
      Decl_service.go ~bucket_size genv.workers env.tcopt fast in
    let hs = SharedMem.heap_size () in
    Hh_logger.log "Heap size: %d" hs;
    Stats.(stats.init_heap_size <- hs);
    HackEventLogger.type_decl_end t;
    let t = Hh_logger.log_duration logstring t in
    let env = {
      env with
      errorl = Errors.merge errorl env.errorl;
    } in
    env, t

  (* Run naming from a fast generated from saved state.
   * No errors are generated because we assume the fast is directly from
   * a clean state.
   *)
  let naming_with_fast (fast: FileInfo.names Relative_path.Map.t) (t: float) : float =
    Relative_path.Map.iter fast ~f:begin fun k info ->
    let { FileInfo.n_classes=classes;
         n_types=typedefs;
         n_funs=funs;
         n_consts=consts} = info in
    NamingGlobal.ndecl_file_fast k ~funs ~classes ~typedefs ~consts
    end;
    HackEventLogger.fast_naming_end t;
    let hs = SharedMem.heap_size () in
    Hh_logger.log "Heap size: %d" hs;
    (Hh_logger.log_duration "Naming fast" t)

  (*
   * In eager initialization, this is done at the parsing step with
   * parsing hooks. During lazy init, need to do it manually from the fast
   * instead since we aren't parsing the codebase.
   *)
  let update_search (genv: ServerEnv.genv) (saved: FileInfo.saved_state_info) (t: float) : float =
    (* Don't update search index when in check mode *)
    (* We can't use is_check_mode here because we want to
      skip this step even while saving saved states.
    *)
    if ServerArgs.check_mode genv.options then t else
    (* Only look at Hack files *)
    let fast = FileInfo.saved_to_hack_files saved in
    (* Filter out non php files *)
    let fast = Relative_path.Map.filter fast
      ~f:(fun s _ -> FindUtils.path_filter s) in

    Relative_path.Map.iter fast
    ~f: (fun fn names ->
      SearchServiceRunner.update (fn, (SearchServiceRunner.Fast names));
    );
    HackEventLogger.update_search_end t;
    Hh_logger.log_duration "Loading search indices" t

  (* Prechecked files are gated with a flag and not supported in AI/check/saving
   * of saved state modes. *)
  let use_prechecked_files (genv: ServerEnv.genv) : bool =
    ServerPrecheckedFiles.should_use genv.options genv.local_config &&
    ServerArgs.ai_mode genv.options = None &&
    (not @@ is_check_mode genv.options) &&
    ServerArgs.save_filename genv.options = None

  let type_check
      (genv: ServerEnv.genv)
      (env: ServerEnv.env)
      (fast: FileInfo.names Relative_path.Map.t)
      (t: float)
    : ServerEnv.env * float =
    if ServerArgs.ai_mode genv.options <> None then env, t
    else if
      is_check_mode genv.options ||
      (ServerArgs.save_filename genv.options <> None)
    then begin
      (* Prechecked files are not supported in AI/check/saving-state modes, we
       * should always recheck everything necessary up-front.*)
      assert (env.prechecked_files = Prechecked_files_disabled);
      let count = Relative_path.Map.cardinal fast in
      let logstring = Printf.sprintf "Type-check %d files" count in
      Hh_logger.log "Begin %s" logstring;
      let errorl =
        let memory_cap = genv.local_config.ServerLocalConfig.max_typechecker_worker_memory_mb in
        Typing_check_service.go genv.workers env.tcopt Relative_path.Set.empty fast ~memory_cap in
      let hs = SharedMem.heap_size () in
      Hh_logger.log "Heap size: %d" hs;
      HackEventLogger.type_check_end count count t;
      let env = { env with
        errorl = Errors.merge errorl env.errorl;
      } in
      env, (Hh_logger.log_duration logstring t)
    end else begin
      let needs_recheck = Relative_path.Map.fold fast
        ~init:Relative_path.Set.empty
        ~f:(fun fn _ acc -> Relative_path.Set.add acc fn)
      in
      let env = { env with
        needs_recheck = Relative_path.Set.union env.needs_recheck needs_recheck;
        (* eagerly start rechecking after init *)
        full_check = Full_check_started;
        init_env = { env.init_env with
          needs_full_init = true;
        };
      } in
      env, t
    end

  let get_dirty_fast
      (old_fast: FileInfo.names Relative_path.Map.t)
      (fast: FileInfo.names Relative_path.Map.t)
      (dirty: Relative_path.Set.t)
    : FileInfo.names Relative_path.Map.t =
    Relative_path.Set.fold dirty ~f:begin fun fn acc ->
      let dirty_fast = Relative_path.Map.get fast fn in
      let dirty_old_fast = Relative_path.Map.get old_fast fn in
      let fast = Option.merge dirty_old_fast dirty_fast FileInfo.merge_names in
      match fast with
      | Some fast -> Relative_path.Map.add acc ~key:fn ~data:fast
      | None -> acc
    end ~init:Relative_path.Map.empty

  let names_to_deps (names: FileInfo.names) : DepSet.t =
    let {FileInfo.n_funs; n_classes; n_types; n_consts} = names in
    let add_deps_of_sset dep_ctor sset depset =
      SSet.fold sset ~init:depset ~f:begin fun n acc ->
        DepSet.add acc (Dep.make (dep_ctor n))
      end
    in
    let deps = add_deps_of_sset (fun n -> Dep.Fun n) n_funs DepSet.empty in
    let deps = add_deps_of_sset (fun n -> Dep.FunName n) n_funs deps in
    let deps = add_deps_of_sset (fun n -> Dep.Class n) n_classes deps in
    let deps = add_deps_of_sset (fun n -> Dep.Class n) n_types deps in
    let deps = add_deps_of_sset (fun n -> Dep.GConst n) n_consts deps in
    let deps = add_deps_of_sset (fun n -> Dep.GConstName n) n_consts deps in
    deps

  (* We start of with a list of files that have changed since the state was
   * saved (dirty_files), and two maps of the class / function declarations
   * -- one made when the state was saved (old_fast) and one made for the
   * current files in the repository (fast). We grab the declarations from both
   * , to account for both the declaratons that were deleted and those that
   * are newly created. Then we use the deptable to figure out the files
   * that referred to them. Finally we recheck the lot.
   * Args:
   *
   * genv, env : environments
   * old_fast: old file-ast from saved state
   * fast: newly parsed file ast
   * dirty_files: we need to typecheck these and,
   *    since their decl have changed, also all of their dependencies
   * similar_files: we only need to typecheck these,
   *    not their dependencies since their decl are unchanged
   **)
  let type_check_dirty
      (genv: ServerEnv.genv)
      (env: ServerEnv.env)
      (old_fast: FileInfo.names Relative_path.Map.t)
      (fast: FileInfo.names Relative_path.Map.t)
      (dirty_master_files: Relative_path.Set.t)
      (dirty_local_files: Relative_path.Set.t)
      (similar_files: Relative_path.Set.t)
      (t: float)
    : ServerEnv.env * float =
    let dirty_files =
      Relative_path.Set.union dirty_master_files dirty_local_files in
    let start_t = Unix.gettimeofday () in
    let fast = get_dirty_fast old_fast fast dirty_files in
    let names s = Relative_path.Map.fold fast ~f:begin fun k v acc ->
      if Relative_path.Set.mem s k then FileInfo.merge_names v acc
      else acc
    end ~init:FileInfo.empty_names in
    let master_deps = names dirty_master_files |> names_to_deps in
    let local_deps = names dirty_local_files |> names_to_deps in

    let env, to_recheck = if use_prechecked_files genv then begin
      (* Start with dirty files and fan-out of local changes only *)
      let deps = Typing_deps.add_all_deps local_deps in
      let to_recheck = Typing_deps.get_files deps in
      ServerPrecheckedFiles.set env (Initial_typechecking {
        rechecked_files = Relative_path.Set.empty;
        dirty_local_deps = local_deps;
        dirty_master_deps = master_deps;
        clean_local_deps = Typing_deps.DepSet.empty;
      }), to_recheck
    end else begin
      (* Start with full fan-out immediately *)
      let deps = Typing_deps.DepSet.union master_deps local_deps in
      let deps = Typing_deps.add_all_deps deps in
      let to_recheck = Typing_deps.get_files deps in
      env, to_recheck
    end in
    (* We still need to typecheck files whose declarations did not change *)
    let to_recheck = Relative_path.Set.union to_recheck similar_files in
    let fast = extend_fast fast env.files_info to_recheck in
    let result = type_check genv env fast t in
    HackEventLogger.type_check_dirty ~start_t
      ~dirty_count:(Relative_path.Set.cardinal dirty_files)
      ~recheck_count:(Relative_path.Set.cardinal to_recheck);
    Hh_logger.log "ServerInit type_check_dirty count: %d. recheck count: %d"
      (Relative_path.Set.cardinal dirty_files)
      (Relative_path.Set.cardinal to_recheck);
    result

  (* get the (untracked, tracked) build targets *)
  let get_build_targets (env: ServerEnv.env) : Relative_path.Set.t * Relative_path.Set.t =
    let untracked, tracked = BuildMain.get_live_targets env in
    let untracked =
      List.map untracked Relative_path.from_root in
    let tracked =
      List.map tracked Relative_path.from_root in
    Relative_path.set_of_list untracked, Relative_path.set_of_list tracked

  let get_state_future
      (genv: ServerEnv.genv)
      (root: Path.t)
      (state_future: (unit -> (loaded_info, error) result, error) result)
      (timeout: int)
    : (loaded_info * Relative_path.Set.t, error) result =
    (* Here we execute the remaining lambda of state_future, whose implementation *)
    (* I happen to know will wait up to 200s for a certain async process to terminate *)
    (* and will return Ok loaded_info or Error for the results of that process. *)
    (* But we're executing it inside our own wrapper timeout. *)
    (* The outer result represents any errors that happened during that wrapper wait_for_timeout. *)
    (* The inner result represents any errors that happened during the process's 200s. *)
    let loaded_result : ((loaded_info, error) result, error) result = state_future
      >>= with_loader_timeout timeout "wait_for_changes" in
    (* Let's coalesce the outer and inner results, i.e. both sources of errors. *)
    let loaded_result : (loaded_info, error) result = Core_result.join loaded_result in

    loaded_result >>= fun loaded_info ->
    genv.wait_until_ready ();
    let root = Path.to_string root in
    let updates = genv.notifier_async () in
    let open ServerNotifierTypes in
    let updates = match updates with
      | Notifier_state_enter _
      | Notifier_state_leave _
      | Notifier_unavailable -> SSet.empty
      | Notifier_synchronous_changes updates
      | Notifier_async_changes updates -> updates in
    let updates = SSet.filter updates (fun p ->
      string_starts_with p root && FindUtils.file_filter p) in
    let changed_while_parsing = Relative_path.(relativize_set Root updates) in
    Ok (loaded_info, changed_while_parsing)

    (* If we fail to load a saved state, fall back to typechecking everything *)
    let fallback_init
        (genv: ServerEnv.genv)
        (env: ServerEnv.env)
        (err: error)
      : ServerEnv.env * float =
      SharedMem.cleanup_sqlite ();
      if err <> No_loader then begin
        let err_str = error_to_verbose_string err in
        HackEventLogger.load_mini_exn err_str;
        (* CARE! the following string literal is matched by clientConnect.ml *)
        (* in its log-scraping function. Do not change. *)
        Hh_logger.log "Could not load mini state: %s" err_str;
      end;
      let get_next, t = indexing genv in
      (* The full_fidelity_parser currently works better in both memory and time
        with a full parse rather than parsing decl asts and then parsing full ones *)
      let lazy_parse = not genv.local_config.SLC.use_full_fidelity_parser in
      (* full init - too many files to trace all of them *)
      let trace = false in
      let env, t = parsing ~lazy_parse genv env ~get_next t ~trace in
      if not (ServerArgs.check_mode genv.options) then
        SearchServiceRunner.update_fileinfo_map env.files_info;
      let t = update_files genv env.files_info t in
      let env, t = naming env t in
      let fast = FileInfo.simplify_fast env.files_info in
      let failed_parsing = Errors.get_failed_files env.errorl Errors.Parsing  in
      let fast = Relative_path.Set.fold failed_parsing
        ~f:(fun x m -> Relative_path.Map.remove m x) ~init:fast in
      type_check genv env fast t

end

(* Laziness *)
type lazy_level = Off | Decl | Parse | Init

module type InitKind = sig
  val init :
    load_mini_approach:(load_mini_approach, error) result ->
    ServerEnv.genv ->
    lazy_level ->
    ServerEnv.env ->
    Path.t ->
    (ServerEnv.env * float) * (loaded_info * files_changed_while_parsing, error) result
end

(* Eager Initialization:
* hh_server can initialize either by typechecking the entire project (aka
* starting from a "fresh state") or by loading from a saved state and
* typechecking what has changed.
*
* If we start from a fresh state, we run the following phases:
*
*   Parsing -> Naming -> Type-decl(skipped if lazy_decl)-> Type-check
*
* If we are loading a state, we do
*
*   Run load script and parsing concurrently -> Naming -> Type-decl
*
* Then we typecheck only the files that have changed since the state was
* saved.
*
* This is done in fairly similar manner to the incremental update
* code in ServerTypeCheck. The key difference is that incremental mode
* can compare the files that it has just parsed with their old versions,
* thereby (in theory) recomputing the least amount possible. OTOH,
* ServerInit only has the latest version of each file, so it has to make
* the most conservative estimate about what to recheck.
*)
module ServerEagerInit : InitKind = struct
  open ServerInitCommon

  let init
      ~(load_mini_approach: (load_mini_approach, error) result)
      (genv: ServerEnv.genv)
      (lazy_level: lazy_level)
      (env: ServerEnv.env)
      (root: Path.t)
    : (ServerEnv.env * float) * (loaded_info * Relative_path.Set.t, error) result =
    (* We don't support a saved state for eager init. *)
    ignore (load_mini_approach, root);
    let get_next, t = indexing genv in
    let lazy_parse = lazy_level = Parse in
    (* Parsing entire repo, too many files to trace. TODO: why do we parse
     * entire repo WHILE loading saved state that is supposed to prevent having
     * to do that? *)
    let trace = false in
    let env, t = parsing ~lazy_parse genv env ~get_next t ~trace in
    if not (ServerArgs.check_mode genv.options) then
      SearchServiceRunner.update_fileinfo_map env.files_info;

    let t = update_files genv env.files_info t in
    let env, t = naming env t in
    let fast = FileInfo.simplify_fast env.files_info in
    let failed_parsing = Errors.get_failed_files env.errorl Errors.Parsing in
    let fast = Relative_path.Set.fold failed_parsing
      ~f:(fun x m -> Relative_path.Map.remove m x) ~init:fast in
    let env, t =
      if lazy_level <> Off then env, t
      else type_decl genv env fast t in

    (* Type-checking everything *)
    SharedMem.cleanup_sqlite ();
    type_check genv env fast t, Error Saved_state_not_supported_for_eager_init
end

(* Lazy Initialization:
 * During Lazy initialization, hh_server tries to do as little work as possible.
 * If we load from saved state, our steps are:
 * Load from saved state -> Parse dirty files -> Naming -> Dirty Typecheck
 * Otherwise, we fall back to the original with lazy decl and parse turned on:
 * Full Parsing -> Naming -> Full Typecheck
 *)
module ServerLazyInit : InitKind = struct
  open ServerInitCommon

  let init
    ~(load_mini_approach: (load_mini_approach, error) result)
    (genv: ServerEnv.genv)
    (lazy_level: lazy_level)
    (env: ServerEnv.env)
    (root: Path.t)
  : (ServerEnv.env * float) * (loaded_info * Relative_path.Set.t, error) result =
    assert(lazy_level = Init);
    Hh_logger.log "Begin loading mini-state";
    let trace = genv.local_config.SLC.trace_parsing in
    let state_future : (unit -> unit -> (loaded_info, error) result, error) result =
      load_mini_approach >>| invoke_approach genv root in
    let timeout = genv.local_config.SLC.load_mini_script_timeout in
    let hg_aware = genv.local_config.SLC.hg_aware in
    (* If state_future was Ok, then we'll execute the first lambda in it. *)
    (* This kicks off an async process, and does some other preparatory stuff. *)
    (* Any exceptions in it, or the timeout exceeded, will result in Error. *)
    let state_future : (unit -> (loaded_info, error) result, error) result =
      state_future >>= with_loader_timeout timeout "wait_for_state"
    in

    let state : (loaded_info * Relative_path.Set.t, error) result =
      get_state_future genv root state_future timeout
    in

    match state with
    | Ok ({
        dirty_local_files;
        dirty_master_files;
        old_saved;
        mergebase_rev;
        old_errors;
        _},
      changed_while_parsing) ->
      Hh_logger.log "Successfully loaded mini-state";

      if hg_aware then Option.iter mergebase_rev ~f:ServerRevisionTracker.initialize;
      Bad_files.check dirty_local_files;
      Bad_files.check changed_while_parsing;

      let (decl_and_typing_error_files, naming_and_parsing_error_files) =
        SaveStateService.partition_error_files_tf
          old_errors
          [ Errors.Decl; Errors.Typing; ] in

      let (_old_parsing_phase, old_parsing_error_files) = match List.find
        old_errors
        ~f:(fun (phase, _files) -> (phase = Errors.Parsing)) with
          | Some (a, b) -> (a, b)
          | None -> (Errors.Parsing, Relative_path.Set.empty)
      in

      Hh_logger.log
        "Number of files with Decl and Typing errors: %d"
        (Relative_path.Set.cardinal decl_and_typing_error_files);

      Hh_logger.log
        "Number of files with Naming and Parsing errors: %d"
        (Relative_path.Set.cardinal naming_and_parsing_error_files);

      let (decl_and_typing_error_files, naming_and_parsing_error_files) =
        SaveStateService.partition_error_files_tf
          old_errors
          [ Errors.Decl; Errors.Typing; ] in

      (* Parse and name all dirty files uniformly *)
      let dirty_files =
        Relative_path.Set.union naming_and_parsing_error_files (
        Relative_path.Set.union dirty_master_files dirty_local_files) in
      let build_targets, tracked_targets = get_build_targets env in
      let t = Unix.gettimeofday () in
      (* Build targets are untracked by version control, so we must always
       * recheck them. While we could query hg / git for the untracked files,
       * it's much slower. *)
      let dirty_files =
        Relative_path.Set.union dirty_files build_targets in
      let dirty_files =
        Relative_path.Set.union dirty_files changed_while_parsing in
      let dirty_files =
        Relative_path.Set.filter dirty_files ~f:FindUtils.path_filter
      in
      (*
        Tracked targets are build files that are tracked by version control.
        We don't need to typecheck them, but we do need to parse them to load
        them into memory, since arc rebuild deletes them before running.
        This avoids build step dependencies and file_heap_stale errors crashing
        the server when build fails and the deleted files aren't properly
        regenerated.
      *)
      let parsing_files =
        Relative_path.Set.union dirty_files tracked_targets in
      let parsing_files_list = Relative_path.Set.elements parsing_files in
      let old_fast = FileInfo.saved_to_fast old_saved in

      (* Get only the hack files for global naming *)
      let old_hack_files = FileInfo.saved_to_hack_files old_saved in
      let old_info = FileInfo.saved_to_info old_saved in
      (* Parse dirty files only *)
      let next = MultiWorker.next genv.workers parsing_files_list in
      let env, t = parsing genv env ~lazy_parse:true ~get_next:next
        ~count:(List.length parsing_files_list) t ~trace in
      SearchServiceRunner.update_fileinfo_map env.files_info;

      let t = update_files genv env.files_info t in
      (* Name all the files from the old fast (except the new ones we parsed) *)
      let old_hack_names = Relative_path.Map.filter old_hack_files (fun k _v ->
          not (Relative_path.Set.mem parsing_files k)
        ) in

      let t = naming_with_fast old_hack_names t in
      (* Do global naming on all dirty files *)
      let env, t = naming env t in

      (* Add all files from fast to the files_info object *)
      let fast = FileInfo.simplify_fast env.files_info in
      let failed_parsing = Errors.get_failed_files env.errorl Errors.Parsing in
      let fast = Relative_path.Set.fold failed_parsing
        ~f:(fun x m -> Relative_path.Map.remove m x) ~init:fast in

      let env = { env with
        disk_needs_parsing =
          Relative_path.Set.union env.disk_needs_parsing changed_while_parsing;
      } in

      (* Separate the dirty files from the files whose decl only changed *)
      (* Here, for each dirty file, we compare its hash to the one saved
      in the saved state. If the hashes are the same, then the declarations
      on the file have not changed and we only need to retypecheck that file,
      not all of its dependencies.
      We call these files "similar" to their previous versions. *)
      let partition_similar dirty_files = Relative_path.Set.partition
      (fun f ->
          let info1 = Relative_path.Map.get old_info f in
          let info2 = Relative_path.Map.get env.files_info f in
          match info1, info2 with
          | Some x, Some y ->
            (match x.FileInfo.hash, y.FileInfo.hash with
            | Some x, Some y ->
              OpaqueDigest.equal x y
            | _ ->
              false)
          | _ ->
            false
        ) dirty_files in

      let similar_master_files, dirty_master_files =
        partition_similar dirty_master_files in
      let similar_local_files, dirty_local_files =
        partition_similar dirty_local_files in

      let similar_files =
        Relative_path.Set.union similar_master_files similar_local_files in

      let env = { env with
        files_info=Relative_path.Map.union env.files_info old_info;
        (* The only reason old_parsing_error_files are added to disk_needs_parsing
          here is because of an issue that seems to be already tracked in T30786759 *)
        disk_needs_parsing = old_parsing_error_files;
        needs_recheck = Relative_path.Set.union env.needs_recheck decl_and_typing_error_files;
      } in
      (* Update the fileinfo object's dependencies now that we have full fast *)
      let t = update_files genv env.files_info t in

      let t = update_search genv old_saved t in

      let result = type_check_dirty genv env old_fast fast
        dirty_master_files dirty_local_files similar_files t, state in
      result
    | Error err ->
      (* Fall back to type-checking everything *)
      fallback_init genv env err, state
end


let ai_check
    (genv: ServerEnv.genv)
    (files_info: FileInfo.t Relative_path.Map.t)
    (env: ServerEnv.env)
    (t: float)
  : ServerEnv.env * float =
  match ServerArgs.ai_mode genv.options with
  | Some ai_opt ->
    let failures =
      List.map ~f:(fun k -> (k, Errors.get_failed_files env.errorl k))
          [ Errors.Parsing; Errors.Decl; Errors.Naming; Errors.Typing ]
    in
    let all_passed = List.for_all failures
        ~f:(fun (k, m) ->
          if Relative_path.Set.is_empty m then true
          else begin
            Hh_logger.log "Cannot run AI because of errors in source in phase %s"
              (Errors.phase_to_string k);
            false
          end)
    in
    if not all_passed then env, t
    else
      let check_mode = ServerArgs.check_mode genv.options in
      let errorl = Ai.go
          Typing_check_utils.type_file genv.workers files_info
          env.tcopt ai_opt check_mode in
      let env = { env with
                  errorl  (* Just Zonk errors. *)
                } in
      env, (Hh_logger.log_duration "Ai" t)
  | None -> env, t

let run_search (genv: ServerEnv.genv) (t: float) : unit =
  if SearchServiceRunner.should_run_completely genv
  then begin
    (* The duration is already logged by SearchServiceRunner *)
    SearchServiceRunner.run_completely genv;
    HackEventLogger.update_search_end t
  end
  else ()

let save_state (genv: ServerEnv.genv) (env: ServerEnv.env) (fn: string) : unit =
  let ignore_errors =
    ServerArgs.gen_saved_ignore_type_errors genv.ServerEnv.options in
  let has_errors = not (Errors.is_empty env.errorl) in
  let do_save_state =
    if ignore_errors then begin
      if has_errors then
        Printf.eprintf
          "WARNING: BROKEN SAVED STATE! Generating saved state. Ignoring type errors.\n%!"
      else
        Printf.eprintf "Generating saved state and ignoring type errors, but there were none.\n%!";
      true
    end else begin
      if has_errors then begin
        Printf.eprintf "Refusing to generate saved state. There are type errors\n%!";
        Printf.eprintf "and --gen-saved-ignore-type-errors was not provided.\n%!";
        false
      end else
        true
    end in

  if do_save_state then
  let file_info_on_disk = ServerArgs.file_info_on_disk genv.ServerEnv.options in
  let _ : int = SaveStateService.save_state
    ~file_info_on_disk env.ServerEnv.files_info env.errorl fn in
  ()

let get_lazy_level (genv: ServerEnv.genv) : lazy_level =
  let lazy_decl = Option.is_none (ServerArgs.ai_mode genv.options) in
  let lazy_parse = genv.local_config.SLC.lazy_parse in
  let lazy_initialize = genv.local_config.SLC.lazy_init in
  match lazy_decl, lazy_parse, lazy_initialize with
  | true, false, false -> Decl
  | true, true, false -> Parse
  | true, true, true -> Init
  | _ -> Off

(* entry point *)
let init
    ?(load_mini_approach: load_mini_approach option)
    (genv: ServerEnv.genv)
  : ServerEnv.env * init_result =
  let lazy_lev = get_lazy_level genv in
  let load_mini_approach = Core_result.of_option load_mini_approach ~error:No_loader in
  let env = ServerEnvBuild.make_env genv.config in
  let init_errors, () = Errors.do_with_context ServerConfig.filename Errors.Init begin fun() ->
    let fcl = ServerConfig.forward_compatibility_level genv.config in
    let older_than = ForwardCompatibilityLevel.greater_than fcl in
    if older_than ForwardCompatibilityLevel.current then
      let pos = Pos.make_from ServerConfig.filename in
      if older_than ForwardCompatibilityLevel.minimum
      then Errors.forward_compatibility_below_minimum pos fcl
      else Errors.forward_compatibility_not_current pos fcl
  end in
  let env = { env with
    errorl = init_errors
  } in
  let root = ServerArgs.root genv.options in
  let (env, t), state =
    match lazy_lev with
    | Init ->
      ServerLazyInit.init ~load_mini_approach genv lazy_lev env root
    | _ ->
      ServerEagerInit.init ~load_mini_approach genv lazy_lev env root
  in
  let env, t = ai_check genv env.files_info env t in
  run_search genv t;
  SharedMem.init_done ();
  ServerUtils.print_hash_stats ();
  let result = match state with
    | Ok ({state_distance; _}, _) ->
      Mini_load state_distance
    | Error err ->
      let err_str = error_to_verbose_string err in
      Mini_load_failed err_str
  in
  env, result
