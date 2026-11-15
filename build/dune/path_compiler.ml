(* Solving a project's packages with a zcaml toolchain on PATH: with its
   compiler, not one built from source. For [dune pkg lock] and dev tools'
   locks (bin/pkg/lock.ml), and the lock directories [dune build] makes
   (Lock_rules).

   Upstream locks [ocaml-system] (the compiler on PATH) only when the lock
   directory's [solver_env] sets [sys-ocaml-version] and its [constraints] ask
   for [ocaml-system], as scripts/cross-env.sh's do; otherwise the newest
   compiler, built from source. With a zcaml toolchain's [ocamlc] first on PATH
   ([find]), [solve] solves the platforms as if both were given for its
   version. It keeps that solution unless it solves a platform fewer than
   upstream's solve, which it then returns: a project that needs another
   compiler ([(ocaml (= 5.5.2))], [ocaml-option-*], ...) locks as upstream. Not
   per platform: a lock directory's platforms have the same compiler package.

   Nothing changes with another [ocamlc] on PATH or none, with [opt_out] set
   (to anything), or for a lock directory that sets or unsets
   [sys-ocaml-version], or whose constraints or pins name a compiler package. *)

open Import
open Fiber.O
module Var = Package_variable_name

let opt_out = "ZCAML_NO_PATH_COMPILER"
let ocaml_system = Package_name.of_string "ocaml-system"

(* [env]'s [opt_out], for an action's environment: its dependency on it is on
   its own. *)
let opt_out_env env =
  match Env.get env opt_out with
  | None -> Env.empty
  | Some value -> Env.add Env.empty ~var:opt_out ~value

(* The version of the [ocamlc] on [env]'s PATH, if it's a zcaml toolchain's:
   its [c_compiler] is a [zcaml-cc-<target>] wrapper. *)
let zcaml_ocamlc_version env =
  match Bin.which ~path:(Env_path.path env) "ocamlc" with
  | None -> Fiber.return None
  | Some ocamlc ->
    let+ lines, status =
      Process.run_capture_lines ~display:Quiet ~env Return ocamlc [ "-config" ]
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

(* The PATH compiler's version, for a lock directory of [solver_env],
   [unset_solver_vars], [constraints] and [pins], unless it picks the compiler,
   or [env] opts out. *)
let find ~env ~solver_env ~unset_solver_vars ~constraints ~pins =
  let names_compiler name =
    Package_name.equal name ocaml_system || Dev_tool.is_compiler_package name
  in
  if
    Option.is_some (Env.get env opt_out)
    || Option.is_some (Solver_env.get solver_env Var.sys_ocaml_version)
    || Var.Set.mem unset_solver_vars Var.sys_ocaml_version
    || List.exists constraints ~f:(fun (c : Dune_lang.Package_dependency.t) ->
      names_compiler c.name)
    || Package_name.Map.existsi pins ~f:(fun name _ -> names_compiler name)
  then Fiber.return None
  else zcaml_ocamlc_version env
;;

(* [f ~constraints platform] for each of [platforms], upstream's solve for one,
   with the PATH compiler of version [compiler] if it can. *)
let solve compiler platforms ~constraints ~f =
  let all ~constraints platforms = Fiber.parallel_map platforms ~f:(f ~constraints) in
  match compiler with
  | None -> all ~constraints platforms
  | Some version ->
    let ocaml_system : Dune_lang.Package_dependency.t =
      { name = ocaml_system; constraint_ = Some (Uop (Eq, String_literal version)) }
    in
    let* preferred =
      all
        ~constraints:(ocaml_system :: constraints)
        (List.map platforms ~f:(fun env ->
           Solver_env.set env Var.sys_ocaml_version (Variable_value.string version)))
    in
    if List.for_all preferred ~f:Result.is_ok
    then Fiber.return preferred
    else
      let+ stock = all ~constraints platforms in
      if
        List.exists preferred ~f:Result.is_ok
        && List.for_all2 preferred stock ~f:(fun preferred stock ->
          Result.is_ok preferred || Result.is_error stock)
           = Ok true
      then preferred
      else stock
;;
