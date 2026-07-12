{ pkgs, lib }:

let
  evalOdooConfig =
    {
      modules,
      pkgs,
      lib,
      specialArgs,
    }:
    lib.evalModules {
      modules = [ ../modules/odoo.nix ] ++ modules;
      specialArgs = {
        inherit pkgs;
      }
      // specialArgs;
    };
in
rec {
  # Helper to evaluate Odoo configurations
  evalOdoo =
    {
      modules,
      pkgs,
      lib ? pkgs.lib,
      specialArgs ? { },
    }:
    (evalOdooConfig {
      inherit
        modules
        pkgs
        lib
        specialArgs
        ;
    }).config.services.odoo;

  # A builder function that evaluates Odoo stack configurations in the Odoo Nix module system
  odooSystem =
    {
      modules,
      pkgs,
      lib ? pkgs.lib,
      specialArgs ? { },
    }:
    (evalOdooConfig {
      inherit
        modules
        pkgs
        lib
        specialArgs
        ;
    }).config.services.odoo.container;
}
