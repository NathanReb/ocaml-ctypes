(* Copyright (C) 2015 Jeremy Yallop
 * Copyright (C) 2012 Anil Madhavapeddy
 * Copyright (C) 2010 Jérémie Dimino
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation, with linking exceptions;
 * either version 2.1 of the License, or (at your option) any later
 * version. See COPYING file for details.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA
 * 02111-1307, USA.
 *)

(* Discover available features *)

open Printf

(* +-----------------------------------------------------------------+
   | Search path                                                     |
   +-----------------------------------------------------------------+ *)

(* List of search paths for header files, mostly for MacOS
   users. libffi is installed by port systems into non-standard
   locations by default on MacOS.

   We use a hardcorded list of path + the ones from C_INCLUDE_PATH and
   LIBRARY_PATH.
*)

let default_search_paths =
  List.map (fun dir -> (dir ^ "/include", dir ^ "/lib")) [
    "/usr";
    "/usr/local";
    "/opt";
    "/opt/local";
    "/sw";
    "/mingw";
  ]

let is_win = Sys.os_type = "Win32"

let path_sep = if is_win then ";" else ":"

let split_path = Str.(split (regexp (path_sep ^ "+")))

let ( // ) = Filename.concat

let advice = "
The following required C libraries are missing: libffi.
Please install them and retry. If they are installed in a non-standard location
or need special flags, set the environment variables <LIB>_CFLAGS and <LIB>_LIBS
accordingly and retry.

For example, if libffi is installed in /opt/local, you can type:

export LIBFFI_CFLAGS=-I/opt/local/include
export LIBFFI_LIBS=-L/opt/local/lib

"

let search_paths =
  let get var f =
    try
      List.map f (split_path (Sys.getenv var))
    with Not_found ->
      []
  in
  List.flatten [
    get "C_INCLUDE_PATH" (fun dir -> (dir, dir // ".." // "lib"));
    get "LIBRARY_PATH" (fun dir -> (dir // ".." // "include", dir));
    default_search_paths;
  ]

(* +-----------------------------------------------------------------+
   | Test codes                                                      |
   +-----------------------------------------------------------------+ *)

let caml_code = "
external test : unit -> unit = \"ffi_test\"
let () = test ()
"

let libffi_code = "
#include <caml/mlvalues.h>
#include <ffi.h>

CAMLprim value ffi_test()
{
  ffi_prep_closure(NULL, NULL, NULL, NULL);
  return Val_unit;
}
"

(* +-----------------------------------------------------------------+
   | Compilation                                                     |
   +-----------------------------------------------------------------+ *)

let ocamlc = ref "ocamlc"
let ext_obj = ref ".o"
let exec_name = ref "a.out"
let os_type = ref "Unix"
let ccomp_type = ref "cc"
let ffi_dir = ref ""
let is_homebrew = ref false
let homebrew_prefix = ref "/usr/local"

let log_file = ref ""
let caml_file = ref ""

(* Search for a header file in standard directories. *)
let search_header header =
  let rec loop = function
    | [] ->
        None
    | (dir_include, dir_lib) :: dirs ->
        if Sys.file_exists (dir_include // header) then
          Some (dir_include, dir_lib)
        else
          loop dirs
  in
  loop search_paths

let silent_remove filename =
  try Sys.remove filename
  with exn -> ()

let test_code (opt, lib) stub_code =
  let open Commands in
  let filename = Filename.temp_file "ctypes_libffi" ".c" in
  with_open_output_file ~filename begin fun oc ->
    let cleanup () = 
      silent_remove (Filename.(chop_extension (basename filename)) ^ !ext_obj)
    in
    unwind_protect ~cleanup (fun () ->
         output_string oc stub_code;
         Commands.command_succeeds
           "%s -custom %s %s %s %s > %s 2>&1"
           !ocamlc
           (String.concat " " (List.map (sprintf "-ccopt %s") opt))
           (Filename.quote filename)
           (Filename.quote !caml_file)
           (String.concat " " (List.map (sprintf "-cclib %s") lib))
           (Filename.quote !log_file)) ()
  end

let test_feature name test =
  begin
    fprintf stderr "testing for %s:%!" name;
    if test () then begin
      fprintf stderr " %s available\n%!" (String.make (34 - String.length name) '.');
      true
    end else begin
      fprintf stderr " %s unavailable\n%!" (String.make (34 - String.length name) '.');
      false
    end
  end

(* +-----------------------------------------------------------------+
   | pkg-config                                                      |
   +-----------------------------------------------------------------+ *)

let split = Str.(split (regexp " +"))

let brew_libffi_version flags =
  match Commands.command "brew ls libffi --versions | awk '{print $NF}' > %s 2>&1" !log_file with
    { Commands.status } when status <> 0 ->
    raise Exit
  | { Commands.stdout = "" } ->
    failwith "You need to 'brew install libffi' to get a suitably up-to-date version"
  | { Commands.stdout } ->
    String.trim stdout

let pkg_config flags =
  let output =
    if !is_homebrew then
      Commands.command
        "env PKG_CONFIG_PATH=%s/Cellar/libffi/%s/lib/pkgconfig %s/bin/pkg-config %s > %s 2>&1"
        !homebrew_prefix (brew_libffi_version ()) !homebrew_prefix flags !log_file
    else
      Commands.command "pkg-config %s > %s 2>&1" flags !log_file
  in
  match output with
    { Commands.status } when status <> 0 -> None
  | { Commands.stdout } -> Some (split (String.trim stdout))

let pkg_config_flags name =
  match (ksprintf pkg_config "--cflags %s" name,
         ksprintf pkg_config "--libs %s" name) with
    Some opt, Some lib -> Some (opt, lib)
  | _ -> None

let get_homebrew_prefix log_file =
  match Commands.command "brew --prefix > %s" log_file with
    { Commands.status } when status <> 0 -> raise Exit
  | { Commands.stdout } -> String.trim stdout

let search_libffi_header () =
  match search_header "ffi.h" with
  | Some (dir_i, dir_l) ->
    (["-I" ^ dir_i], ["-L" ^ dir_l; "-lffi"])
  | None ->
    ([], ["-lffi"])

let test_libffi setup_data have_pkg_config =
  let get var = try Some (split (Sys.getenv var)) with Not_found -> None in
  let opt, lib =
    match get "LIBFFI_CFLAGS", get "LBIFFI_LIBS" with
    | Some opt, Some lib -> (opt, lib)
    | envopt, envlib ->
      let opt, lib =
        if not have_pkg_config then
          search_libffi_header ()
        else match pkg_config_flags "libffi" with
          | Some (pkgopt, pkglib) -> (pkgopt, pkglib)
          | None -> search_libffi_header ()
      in
      match envopt, envlib, opt, lib with
      | Some opt, Some lib, _  , _
      | Some opt, None    , _  , lib
      | None    , Some lib, opt, _
      | None    , None    , opt, lib -> opt, lib
  in
  setup_data := ("libffi_opt", opt) :: ("libffi_lib", lib) :: !setup_data;
  test_code (opt, lib) libffi_code

(* Test for pkg-config. If we are on MacOS X, we need the latest pkg-config
 * from Homebrew *)
let have_pkg_config is_homebrew homebrew_prefix log_file =
  if is_homebrew then begin
    (* Look in `brew for the right pkg-config *)
    homebrew_prefix := get_homebrew_prefix log_file;
    test_feature "pkg-config"
      (fun () ->
         Commands.command_succeeds "%s/bin/pkg-config --version > %s 2>&1" !homebrew_prefix log_file)
  end
  else
    test_feature "pkg-config"
      (fun () ->
         Commands.command_succeeds "pkg-config --version > %s 2>&1" log_file)

let args = [
  "-ocamlc", Arg.Set_string ocamlc, "<path> ocamlc";
  "-ext-obj", Arg.Set_string ext_obj, "<ext> C object files extension";
  "-exec-name", Arg.Set_string exec_name, "<name> name of the executable produced by ocamlc";
  "-ccomp-type", Arg.Set_string ccomp_type, "<ccomp-type> C compiler type";
]

(* +-----------------------------------------------------------------+
   | Entry point                                                     |
   +-----------------------------------------------------------------+ *)

let () =
  Arg.parse args ignore "check for external C libraries and available features\noptions are:";

  (* Put the caml code into a temporary file. *)
  let file, oc = Filename.open_temp_file "ffi_caml" ".ml" in
  caml_file := file;
  output_string oc caml_code;
  close_out oc;

  log_file := Filename.temp_file "ffi_output" ".log";

  (* Cleanup things on exit. *)
  at_exit (fun () ->
             silent_remove !log_file;
             silent_remove !exec_name;
             silent_remove !caml_file;
             silent_remove (Filename.chop_extension !caml_file ^ ".cmi");
             silent_remove (Filename.chop_extension !caml_file ^ ".cmo"));

  (* Test for MacOS X Homebrew. *)
  is_homebrew :=
    test_feature "brew"
      (fun () ->
         Commands.command_succeeds "brew info libffi > %s 2>&1" !log_file);

  let have_pkg_config = have_pkg_config !is_homebrew homebrew_prefix !log_file in

  let setup_data = ref [] in
  let have_libffi = test_feature "libffi"
      (fun () -> test_libffi setup_data have_pkg_config) in

  if not have_pkg_config then
    fprintf stderr "Warning: the 'pkg-config' command is not available.";

  if not have_libffi then
    (prerr_endline advice; exit 1);

  ListLabels.iter !setup_data
    ~f:(fun (name, args) ->
        Printf.printf "%s=%s\n" name (String.concat " " args))
