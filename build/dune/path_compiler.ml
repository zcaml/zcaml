(* [dune pkg lock] with a zcaml toolchain on PATH: its compiler, not one built
   from source.

   Upstream locks [ocaml-system] (the compiler on PATH) only when the lock
   directory's [solver_env] sets [sys-ocaml-version] and its [constraints] ask
   for [ocaml-system], as scripts/cross-env.sh's do; otherwise the newest
   compiler, built from source. With a zcaml toolchain's [ocamlc] first on PATH,
   [prefer] solves as if both were given for its version, on each of the
   platforms. It keeps that solution unless it solves fewer platforms than
   upstream's solve, which it then returns: a project that needs another
   compiler ([(ocaml (= 5.5.2))], [ocaml-option-*], ...) locks as upstream. Not
   per platform: a lock directory's platforms have the same compiler package.

   Nothing changes with another [ocamlc] on PATH or none, with
   [ZCAML_NO_PATH_COMPILER] set (to anything), or for a lock directory that
   sets or unsets [sys-ocaml-version], or whose constraints or pins name a
   compiler package. *)

open Import
open Fiber.O
module Solver_env = Dune_pkg.Solver_env
module Var = Dune_lang.Package_variable_name

let ocaml_system = Package_name.of_string "ocaml-system"

(* The version of the [ocamlc] on PATH, if it's a zcaml toolchain's: its
   [c_compiler] is a [zcaml-cc-<target>] wrapper. *)
let zcaml_ocamlc_version () =
  match Bin.which ~path:(Env_path.path Env.initial) "ocamlc" with
  | None -> Fiber.return None
  | Some ocamlc ->
    let+ lines, status =
      Dune_engine.Process.run_capture_lines ~display:Quiet Return ocamlc [ "-config" ]
    in
    let field name =
      List.find_map lines ~f:(fun line ->
        match String.lsplit2 line ~on:':' with
        | Some (key, value) when String.equal key name -> Some (String.trim value)
        | _ -> None)
    in
    (match status, field "c_compiler", field "version" with
     | 0, Some cc, Some version when String.starts_with ~prefix:"zcaml-cc-" cc ->
       Some version
     | _ -> None)
;;

(* The PATH compiler's version, unless the lock directory picks the compiler or
   the user opts out. *)
let compiler (lock_dir : Workspace.Lock_dir.t option) ~pins ~constraints =
  let names_compiler name =
    Package_name.equal name ocaml_system || Dune_pkg.Dev_tool.is_compiler_package name
  in
  let sets_sys_ocaml_version (lock_dir : Workspace.Lock_dir.t) =
    (match lock_dir.solver_env with
     | Some env -> Option.is_some (Solver_env.get env Var.sys_ocaml_version)
     | None -> false)
    ||
    match lock_dir.unset_solver_vars with
    | Some vars -> Var.Set.mem vars Var.sys_ocaml_version
    | None -> false
  in
  if
    Option.is_some (Env.get Env.initial "ZCAML_NO_PATH_COMPILER")
    || (match lock_dir with
      | Some lock_dir -> sets_sys_ocaml_version lock_dir
      | None -> false)
    || List.exists constraints ~f:(fun (c : Dune_lang.Package_dependency.t) ->
      names_compiler c.name)
    || Package_name.Map.existsi pins ~f:(fun name _ -> names_compiler name)
  then Fiber.return None
  else zcaml_ocamlc_version ()
;;

(* Whether the solve's result [preferred] solves every platform [stock] does. *)
let solves_as_many preferred ~as_:stock =
  let unsolved = function
    | `All_ok _ -> Some []
    | `Partial (_, errors) -> Some (List.concat_map errors ~f:snd)
    | `All_error _ -> None
  in
  let platform env = Solver_env.unset_multi env (Var.Set.singleton Var.sys_ocaml_version) in
  match unsolved preferred, unsolved stock with
  | None, _ -> false
  | Some _, None -> true
  | Some preferred, Some stock ->
    let stock = List.map stock ~f:platform in
    List.for_all preferred ~f:(fun env ->
      List.mem stock (platform env) ~equal:Solver_env.equal)
;;

(* [solve ~constraints ~solve_for_platforms], upstream's solve of a lock
   directory, preferring the PATH compiler. *)
let prefer lock_dir ~pins ~constraints ~solve_for_platforms solve =
  compiler lock_dir ~pins ~constraints
  >>= function
  | None -> solve ~constraints ~solve_for_platforms
  | Some version ->
    let ocaml_system : Dune_lang.Package_dependency.t =
      { name = ocaml_system; constraint_ = Some (Uop (Eq, String_literal version)) }
    in
    let* preferred =
      solve
        ~constraints:(ocaml_system :: constraints)
        ~solve_for_platforms:
          (List.map solve_for_platforms ~f:(fun env ->
             Solver_env.set env Var.sys_ocaml_version (Dune_pkg.Variable_value.string version)))
    in
    (match preferred with
     | `All_ok _ -> Fiber.return preferred
     | `Partial _ | `All_error _ ->
       let+ stock = solve ~constraints ~solve_for_platforms in
       if solves_as_many preferred ~as_:stock then preferred else stock)
;;
