{
  description = "Declarative Nix options and package builder for Odoo ERP";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs = { self, nixpkgs }: {
    # System-agnostic library functions.
    # To instantiate the library, call: nix-odoo.lib { inherit pkgs; }
    lib = { pkgs, lib ? pkgs.lib }: import ./default.nix { inherit pkgs lib; };

    # Export Odoo declarative module
    nixosModules.odoo = import ./module.nix;
    nixosModules.default = self.nixosModules.odoo;
  };
}
