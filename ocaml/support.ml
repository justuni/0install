(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Generic support code (not 0install-specific) *)

module StringMap = Map.Make(String);;

type filepath = string;;
type varname = string;;

(** An error that should be reported to the user without a stack-trace (i.e. it
    does not indicate a bug).
    The list is an optional list of context strings, outermost first, saying what
    we were doing when the exception occurred. This list gets extended as the exception
    propagates.
 *)
exception Safe_exception of (string * string list ref);;

(** Convenient way to create a new [Safe_exception] with no initial context. *)
let raise_safe msg = raise (Safe_exception (msg, ref []));;

(** Add the additional explanation [context] to the exception and rethrow it.
    [ex] should be a [Safe_exception] (if not, [context] is written as a warning to [stderr]).
  *)
let reraise_with_context ex context =
  let () = match ex with
  | Safe_exception (_, old_contexts) -> old_contexts := context :: !old_contexts
  | _ -> Printf.eprintf "warning: Attempt to add note '%s' to non-Safe_exception!" context
  in raise ex
;;

(** [handle_exceptions main] runs [main ()]. If it throws an exception it reports it in a
    user-friendly way. A [Safe_exception] is displayed with its context.
    If stack-traces are enabled, one will be displayed. If not then, if the exception isn't
    a [Safe_exception], the user is told how to enable them.
    On error, it calls [exit 1]. On success, it returns.
 *)
let handle_exceptions main =
  try main ()
  with
  | Safe_exception (msg, context) ->
      Printf.eprintf "%s\n" msg;
      List.iter (Printf.eprintf "%s\n") (List.rev !context);
      Printexc.print_backtrace stderr;
      exit 1
  | ex ->
      output_string stderr (Printexc.to_string ex);
      output_string stderr "\n";
      if not (Printexc.backtrace_status ()) then
        output_string stderr "(hint: run with OCAMLRUNPARAM=b to get a stack-trace)\n"
      else
        Printexc.print_backtrace stderr;
      exit 1
;;

(** [with_open file fn] opens [file], calls [fn handle], and then closes it again. *)
let with_open file fn =
  let ch =
    try open_in file
    with Sys_error msg -> raise_safe msg
  in
  let result = try fn ch with ex -> close_in ch; raise ex in
  let () = close_in ch in
  result
;;

(** [default d opt] unwraps option [opt], returning [d] if it was [None]. *)
let default d = function
  | None -> d
  | Some x -> x;;

(** Return the first non-[None] result of [fn item] for items in the list. *)
let rec first_match fn = function
  | [] -> None
  | (x::xs) -> match fn x with
      | Some _ as result -> result
      | None -> first_match fn xs;;

(** The string used to separate paths (":" on Unix, ";" on Windows). *)
let path_sep = if Filename.dir_sep = "/" then ":" else ";";;

(** Handy infix version of [Filename.concat]. *)
let (+/) : filepath -> filepath -> filepath = Filename.concat;;

(** [makedirs path mode] ensures that [path] is a directory, creating it and any missing parents (using [mode]) if not. *)
let rec makedirs path mode =
  try (
    if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then ()
    else raise_safe ("Not a directory: " ^ path)
  ) with Unix.Unix_error _ -> (
    let parent = (Filename.dirname path) in
    assert (path <> parent);
    makedirs parent mode;
    Unix.mkdir path mode
  )
;;

let starts_with str prefix =
  let ls = String.length str in
  let lp = String.length prefix in
  if lp > ls then false else
    let rec loop i =
      if i = lp then true
      else if str.[i] <> prefix.[i] then false
      else loop (i + 1)
    in loop 0;;

let path_is_absolute path = starts_with path Filename.dir_sep;;

(** If the given path is relative, make it absolute by prepending the current directory to it. *)
let abspath path =
  if path_is_absolute path then path
  else if starts_with path (Filename.current_dir_name ^ Filename.dir_sep) then
    Sys.getcwd () +/ String.sub path 2 ((String.length path) - 2)
  else (Sys.getcwd ()) +/ path
;;
