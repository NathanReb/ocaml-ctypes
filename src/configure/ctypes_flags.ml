module C = Configurator.V1

let () =
  C.main ~name:"ctypes-flags" (fun c ->
    let f = "as_needed_test" in
    let ml = f ^ ".ml" in
    open_out ml |> close_out;
    let res = C.Process.run_ok c "ocamlopt" ["-shared"; "-cclib"; "-Wl,--no-as-needed"; ml; "-o"; f^".cmxs"] in
    let sxp = if res then ["-Wl,--no-as-needed"] else [] in
    C.Flags.write_sexp "ctypes-ldflags.sxp" sxp
  )
