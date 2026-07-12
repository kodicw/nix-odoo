{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.odoo;
  format = pkgs.formats.ini { };
  odooLib = import ./default.nix { inherit pkgs lib; };

  # Schema for page options
  pageOpts = types.submodule {
    options = {
      id = mkOption {
        type = types.str;
        description = "Unique database XML ID of the page.";
      };
      name = mkOption {
        type = types.str;
        description = "Display name of the website page.";
      };
      template = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Inline HTML/QWeb markup string.";
      };
      templateFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to an XML file containing the page QWeb layout.";
      };
      groups = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Odoo XML Group IDs allowed to access the page.";
      };
    };
  };

  websiteOpts = types.submodule {
    options = {
      pages = mkOption {
        type = types.attrsOf pageOpts;
        default = { };
        description = "Declarative pages registry under the website domain.";
      };
    };
  };

in
{
  options.services.odoo = {
    enable = mkEnableOption "odoo stack configuration";

    addons = mkOption {
      type = with types; listOf package;
      default = [ ];
      description = "Core Odoo modules and python packages to include.";
    };

    # Declarative website configurations
    website = mkOption {
      type = types.attrsOf websiteOpts;
      default = { };
      description = "Declarative website configurations to compile into custom addons.";
    };

    # Freeform configuration settings (generates odoo.cfg via pkgs.formats.ini)
    settings = mkOption {
      type = types.submodule {
        options = {
          options = {
            workers = mkOption {
              type = types.ints.unsigned;
              default = 0;
              description = "Number of multiprocessing workers.";
            };
            proxy_mode = mkOption {
              type = types.bool;
              default = true;
              description = "Enables proxy mode support.";
            };
          };
        };
        freeformType = format.type;
      };
      default = { };
      description = "Odoo configuration settings (generates odoo.cfg via pkgs.formats.ini).";
    };

    # Outputs
    configFile = mkOption {
      type = types.package;
      readOnly = true;
      description = "The generated odoo.cfg file package.";
    };

    addonPackages = mkOption {
      type = types.listOf types.package;
      readOnly = true;
      description = "All addon packages, including nix-compiled website pages.";
    };

    # The resulting container package (compiled output)
    container = mkOption {
      type = types.package;
      readOnly = true;
      description = "Fully compiled Odoo container image package.";
    };
  };

  config = mkIf cfg.enable (
    let
      websiteAddons = mapAttrsToList
        (name: webConfig:
          odooLib.mkOdooAddon {
            name = "pgmsp_website_${name}";
            pages = webConfig.pages;
          }
        )
        cfg.website;

      allAddons = cfg.addons ++ websiteAddons;
      cfgFile = format.generate "odoo.cfg" cfg.settings;
    in
    {
      services.odoo.configFile = cfgFile;
      services.odoo.addonPackages = allAddons;

      services.odoo.container = pkgs.callPackage ./container.nix {
        addonPackages = allAddons;
        baseConfigFile = cfgFile;
      };
    }
  );
}
