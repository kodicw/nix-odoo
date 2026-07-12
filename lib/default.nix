{ pkgs, lib }:

let
  addon = import ./addon.nix { inherit pkgs lib; };
  system = import ./system.nix { inherit pkgs lib; };
in
{
  inherit (addon) mkOdooAddon mkOdooModule;
  inherit (system) evalOdoo odooSystem;
}
