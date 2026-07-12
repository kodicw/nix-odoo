{
  description = "Declarative Nix options and package builder for Odoo ERP";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs =
    { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs supportedSystems (
          system:
          f (
            import nixpkgs {
              inherit system;
              config.permittedInsecurePackages = [
                "python3.12-pypdf2-3.0.1"
              ];
            }
          )
        );

      testPages = {
        home = {
          id = "homepage";
          name = "Home Page";
          template = "<div>Welcome to PGMSP!</div>";
        };
      };

      testPythonFiles = {
        "controllers/main.py" = ''
          from odoo import http
          class Main(http.Controller):
              @http.route('/', auth='public')
              def index(self, **kw):
                  return "Hello World"
        '';
      };
    in
    {
      # System-agnostic library functions.
      # To instantiate the library, call: nix-odoo.lib { inherit pkgs; }
      lib =
        {
          pkgs,
          lib ? pkgs.lib,
        }:
        import ./lib/default.nix { inherit pkgs lib; };

      # Export Odoo declarative module
      nixosModules.odoo = import ./modules/odoo.nix;
      nixosModules.default = self.nixosModules.odoo;

      # System-dependent outputs
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.nixfmt-rfc-style
            pkgs.statix
          ];
        };
      });

      packages = forAllSystems (pkgs: {
        default = self.packages.${pkgs.system}.example-container;
        example-container =
          let
            odooLib = self.lib { inherit pkgs; };
          in
          odooLib.odooSystem {
            modules = [
              {
                services.odoo = {
                  enable = true;
                  settings.options = {
                    workers = 4;
                    proxy_mode = true;
                  };
                  website.main = {
                    pages = testPages;
                    pythonFiles = testPythonFiles;
                  };
                };
              }
            ];
            inherit pkgs;
          };
        example-addon =
          let
            odooLib = self.lib { inherit pkgs; };
          in
          odooLib.mkOdooAddon {
            name = "pgmsp_website_example";
            pages = testPages;
            pythonFiles = testPythonFiles;
          };
        example-local-addon =
          let
            odooLib = self.lib { inherit pkgs; };
            dummySrc = pkgs.runCommand "dummy-addon-src" { } ''
              mkdir -p $out
              echo '{"name": "Dummy Local Addon", "version": "1.0.0", "depends": ["base"], "installable": True}' > $out/__manifest__.py
              echo "print('imported')" > $out/__init__.py
              mkdir -p $out/views
              echo '<?xml version="1.0" encoding="utf-8"?><odoo><data></data></odoo>' > $out/views/templates.xml
            '';
          in
          odooLib.mkOdooModule {
            name = "pgmsp_local_addon";
            src = dummySrc;
          };
        example-local-addon-db =
          let
            odooLib = self.lib { inherit pkgs; };
            dummySrc = pkgs.runCommand "dummy-addon-src" { } ''
              mkdir -p $out
              echo '{"name": "Dummy Local Addon", "version": "1.0.0", "depends": ["base"], "installable": True}' > $out/__manifest__.py
              echo "print('imported')" > $out/__init__.py
              mkdir -p $out/views
              echo '<?xml version="1.0" encoding="utf-8"?><odoo><data></data></odoo>' > $out/views/templates.xml
            '';
          in
          odooLib.mkOdooModule {
            name = "pgmsp_local_addon";
            src = dummySrc;
            checkSchema = true;
            odoo = pkgs.odoo;
            postgresql = pkgs.postgresql;
          };
      });

      checks = forAllSystems (pkgs: {
        eval-test = self.packages.${pkgs.system}.example-container;
        local-addon-test = self.packages.${pkgs.system}.example-local-addon;
        local-addon-db-test = self.packages.${pkgs.system}.example-local-addon-db;
      });
    };
}
