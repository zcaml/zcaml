open Cmdliner

let run name = Printf.printf "hello, %s (%s)\n" name Sys.os_type
let name = Arg.(value & pos 0 string "world" & info [] ~docv:"NAME")
let cmd = Cmd.v (Cmd.info "hello" ~version:"0.1.0") Term.(const run $ name)
let () = exit (Cmd.eval cmd)
