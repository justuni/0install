(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Select a compatible set of components to run a program. 
 * This instantiates the [Solver_core] functor with the concrete 0install types. *)

open General
open Support.Common
module U = Support.Utils
module Qdom = Support.Qdom
module FeedAttr = Constants.FeedAttr
module AttrMap = Qdom.AttrMap

module CoreModel = struct
  (** See [Solver_types.MODEL] for documentation. *)

  module Role = struct
    (** A role is an interface and a flag indicating whether we want source or a binary.
     * This allows e.g. using an old version of a compiler to compile the source for the
     * new version (which requires selecting two different versions of the same interface). *)
    type t = (iface_uri * bool)
    let to_string = function
      | iface_uri, false -> iface_uri
      | iface_uri, true -> iface_uri ^ "#source"

    (* Sort the interfaces by URI so we have a stable output. *)
    let compare (ia, sa) (ib, sb) =
      match String.compare ia ib with
      | 0 -> compare sa sb
      | x -> x
  end
  type impl = Impl.generic_implementation
  type t = Impl_provider.impl_provider
  type command = Impl.command
  type restriction = Impl.restriction
  type command_name = string
  type rejection = Impl_provider.rejection
  type dependency = {
    dep_role : Role.t;
    dep_restrictions : restriction list;
    dep_importance : [ `essential | `recommended | `restricts ];
    dep_required_commands : command_name list;
  }
  type role_information = {
    replacement : Role.t option;
    impls : impl list;
  }
  type requirements =
    | ReqCommand of (command_name * Role.t)
    | ReqRole of Role.t

  let impl_to_string impl = (Versions.format_version impl.Impl.parsed_version) ^ " - " ^ Qdom.show_with_loc impl.Impl.qdom
  let id_of_impl impl = Impl.get_attr_ex FeedAttr.id impl
  let command_to_string command = Qdom.show_with_loc command.Impl.command_qdom
  let version impl = impl.Impl.parsed_version
  let describe_problem = Impl_provider.describe_problem

  let dummy_impl =
    let open Impl in {
      qdom = ZI.make "dummy";
      os = None;
      machine = None;
      stability = Testing;
      props = {
        attrs = AttrMap.empty;
        requires = [];
        commands = StringMap.empty;   (* (not used; we can provide any command) *)
        bindings = [];
      };
      parsed_version = Versions.dummy;
      impl_type = `local_impl "/dummy";
    }

  let dummy_command = { Impl.
    command_qdom = ZI.make "dummy-command";
    command_requires = [];
    command_bindings = [];
  }

  let get_command impl name = StringMap.find name impl.Impl.props.Impl.commands

  let make_deps impl_provider zi_deps self_bindings =
    let deps = zi_deps
      |> U.filter_map (fun zi_dep ->
        if impl_provider#is_dep_needed zi_dep then Some {
          (* note: currently, only dependencies on binaries are supported. *)
          dep_role = (zi_dep.Impl.dep_iface, false);
          dep_importance = zi_dep.Impl.dep_importance;
          dep_required_commands = zi_dep.Impl.dep_required_commands;
          dep_restrictions = zi_dep.Impl.dep_restrictions;
        } else None
      ) in
    let self_commands = self_bindings
      |> U.filter_map (fun binding ->
        Element.classify_binding binding |> Binding.parse_binding |> Binding.get_command
      ) in
    (deps, self_commands)

  let requires impl_provider impl = make_deps impl_provider Impl.(impl.props.requires) Impl.(impl.props.bindings)
  let command_requires impl_provider command = make_deps impl_provider Impl.(command.command_requires) Impl.(command.command_bindings)

  let to_selection impl_provider iface commands impl =
    let attrs = Impl.(impl.props.attrs)
      |> AttrMap.remove ("", FeedAttr.stability)

      (* Replaced by <command> *)
      |> AttrMap.remove ("", FeedAttr.main)
      |> AttrMap.remove ("", FeedAttr.self_test)

      |> AttrMap.add_no_ns "interface" iface in

    let attrs =
      if Some iface = AttrMap.get_no_ns FeedAttr.from_feed attrs then (
        (* Don't bother writing from-feed attr if it's the same as the interface *)
        AttrMap.remove ("", FeedAttr.from_feed) attrs
      ) else attrs in

    let child_nodes = ref [] in
    if impl != dummy_impl then (
      let commands = List.sort compare commands in

      let copy_qdom elem =
        (* Copy elem into parent (and strip out <version> elements). *)
        let open Qdom in
        let imported = {elem with
          child_nodes = List.filter (fun c -> ZI.tag c <> Some "version") elem.child_nodes;
        } in
        child_nodes := imported :: !child_nodes in

      commands |> List.iter (fun name ->
        let command = Impl.get_command_ex name impl in
        let command_elem = command.Impl.command_qdom in
        let want_command_child elem =
          (* We'll add in just the dependencies we need later *)
          match ZI.tag elem with
          | Some "requires" | Some "restricts" | Some "runner" -> false
          | _ -> true
        in
        let child_nodes = List.filter want_command_child command_elem.Qdom.child_nodes in
        let add_command_dep child_nodes dep =
          if dep.Impl.dep_importance <> `restricts && impl_provider#is_dep_needed dep then
            Element.as_xml dep.Impl.dep_qdom :: child_nodes
          else
            child_nodes in
        let child_nodes = List.fold_left add_command_dep child_nodes command.Impl.command_requires in
        let command_elem = {command_elem with Qdom.child_nodes = child_nodes} in
        copy_qdom command_elem
      );

      let copy_elem elem =
        copy_qdom (Element.as_xml elem) in

      Impl.(impl.props.bindings) |> List.iter copy_elem;
      Impl.(impl.props.requires) |> List.iter (fun dep ->
        if impl_provider#is_dep_needed dep && dep.Impl.dep_importance <> `restricts then
          copy_elem (dep.Impl.dep_qdom)
      );

      impl.Impl.qdom |> ZI.iter ~name:"manifest-digest" copy_qdom;
    );
    ZI.make
      ~attrs
      ~child_nodes:(List.rev !child_nodes)
      ~source_hint:impl.Impl.qdom "selection"

  let machine impl =
    match impl.Impl.machine with
    | None | Some "src" -> None
    | Some machine -> Some (Arch.get_machine_group machine)

  let format_machine impl =
    match impl.Impl.machine with
    | None -> "any"
    | Some machine -> machine

  let meets_restriction impl r = impl == dummy_impl || r#meets_restriction impl
  let string_of_restriction r = r#to_string

  let implementations impl_provider (iface_uri, source) =
    let {Impl_provider.replacement; impls; rejects = _} = impl_provider#get_implementations iface_uri ~source in
    let replacement = replacement |> pipe_some (fun replacement ->
      if replacement = iface_uri then (
        log_warning "Interface %s replaced-by itself!" iface_uri; None
      ) else Some (replacement, source)
    ) in
    {replacement; impls}

  let rejects impl_provider (iface_uri, source) =
    let candidates = impl_provider#get_implementations iface_uri ~source in
    candidates.Impl_provider.rejects

  let user_restrictions impl_provider (iface, _source) =
    StringMap.find iface impl_provider#extra_restrictions
end

module Core = Solver_core.Make(CoreModel)

module Model =
  struct
    include CoreModel

    module RoleMap = Core.RoleMap

    type result = {
      root_req : requirements;
      selections : Core.selection RoleMap.t;
      impl_provider : Impl_provider.impl_provider;
    }

    type version = Versions.parsed_version
    let format_version = Versions.format_version

    let get_selected result role =
      try
        let selection = RoleMap.find role result.selections in
        let impl = Core.(selection.impl) in
        if impl == dummy_impl then None
        else Some impl
      with Not_found -> None

    let requirements result = result.root_req

    let explain result role =
      try
        let sel = RoleMap.find role result.selections in
        Core.explain sel.Core.diagnostics
      with Not_found -> "Role not used!"

    let model result = result.impl_provider

    let raw_selections result =
      result.selections |> RoleMap.map (fun sel -> sel.Core.impl)
  end

let impl_provider = Model.model

let do_solve impl_provider root_req ~closest_match =
  Core.do_solve impl_provider root_req ~closest_match |> pipe_some (fun selections ->

    (* Build the results object *)
    Some { Model.
      root_req;
      selections;
      impl_provider;
    }
  )

let get_root_requirements config requirements =
  let { Requirements.command; interface_uri; source; extra_restrictions; os; cpu; message = _ } = requirements in

  (* This is for old feeds that have use='testing' instead of the newer
    'test' command for giving test-only dependencies. *)
  let use = if command = Some "test" then StringSet.singleton "testing" else StringSet.empty in

  let platform = config.system#platform in
  let os = default platform.Platform.os os in
  let machine = default platform.Platform.machine cpu in

  (* Disable multi-arch on Linux if the 32-bit linker is missing. *)
  let multiarch = os <> "Linux" || config.system#file_exists "/lib/ld-linux.so.2" in

  let scope_filter = Impl_provider.({
    extra_restrictions = StringMap.map Impl.make_version_restriction extra_restrictions;
    os_ranks = Arch.get_os_ranks os;
    machine_ranks = Arch.get_machine_ranks ~multiarch machine;
    languages = config.langs;
    allowed_uses = use;
  }) in

  let root_req = match command with
  | Some command -> Model.ReqCommand (command, (interface_uri, source))
  | None -> Model.ReqRole (interface_uri, source) in

  (scope_filter, root_req)

let solve_for config feed_provider requirements =
  try
    let scope_filter, root_req = get_root_requirements config requirements in

    let impl_provider = (new Impl_provider.default_impl_provider config feed_provider scope_filter :> Impl_provider.impl_provider) in
    match do_solve impl_provider root_req ~closest_match:false with
    | Some result -> (true, result)
    | None ->
        match do_solve impl_provider root_req ~closest_match:true with
        | Some result -> (false, result)
        | None -> failwith "No solution, even with closest_match!"
  with Safe_exception _ as ex -> reraise_with_context ex "... solving for interface %s" requirements.Requirements.interface_uri

let selections result =
  (** Create a <selections> document from the result of a solve.
   * The use of Maps ensures that the inputs will be sorted, so we will have a stable output.
   *)
  Selections.create (
    let open Model in
    let root_attrs =
      match result.root_req with
      | ReqCommand (command, (iface, _source)) ->
          AttrMap.singleton "interface" iface
          |> AttrMap.add_no_ns "command" command
      | ReqRole (iface, _source) ->
          AttrMap.singleton "interface" iface in
    let child_nodes = result.selections
      |> Core.RoleMap.bindings
      |> List.map (fun ((iface, _source), selection) ->
        (* TODO: update selections format to handle source here *)
        Model.to_selection result.impl_provider iface selection.Core.commands selection.Core.impl
      ) in
    ZI.make ~attrs:root_attrs ~child_nodes "selections"
  )

module Diagnostics = Diagnostics.Make (Model)

(** Return a message explaining why the solve failed. *)
let get_failure_reason config result =
  let msg = Diagnostics.get_failure_reason result in

  if config.network_use = Offline then
    msg ^ "\nNote: 0install is in off-line mode"
  else
    msg
