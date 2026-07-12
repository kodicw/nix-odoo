{ pkgs, lib }:

rec {
  # Build a declarative Odoo module from Nix attributes
  mkOdooAddon =
    { name
    , version ? "1.0.0"
    , depends ? [ "website" ]
    , pages ? { }
    , # url -> { id, name, template ? "", templateFile ? null, groups ? [] }
      pythonFiles ? { }
    , # filepath -> python code string
    }:
    let
      # Evaluation-time assertions
      validatePage =
        url: p:
        let
          template = if p ? template then p.template else null;
          templateFile = if p ? templateFile then p.templateFile else null;
        in
        assert lib.assertMsg (p ? id) "Odoo Page URL '${url}' must specify a string 'id'";
        assert lib.assertMsg (p ? name) "Odoo Page '${p.id}' must specify a 'name'";
        assert lib.assertMsg
          (
            template != null || templateFile != null
          ) "Odoo Page '${p.id}' must specify 'template' or 'templateFile'";
        assert lib.assertMsg
          (
            !(template != null && templateFile != null)
          ) "Odoo Page '${p.id}' cannot specify both 'template' and 'templateFile'";
        p;

      validatedPages = lib.mapAttrs (url: p: validatePage url p) pages;

      getPageTemplate =
        p:
        let
          template = if p ? template then p.template else null;
          templateFile = if p ? templateFile then p.templateFile else null;
        in
        if templateFile != null then builtins.readFile templateFile else template;

      pagesXml = ''
        <?xml version="1.0" encoding="utf-8"?>
        <odoo>
          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (url: p: ''
              <record id="view_${p.id}" model="ir.ui.view">
                <field name="name">${p.name} View</field>
                <field name="type">qweb</field>
                <field name="key">${name}.${p.id}_view</field>
                <field name="arch" type="xml">
                  <t name="${p.name}" t-name="${name}.${p.id}_view">
                    ${getPageTemplate p}
                  </t>
                </field>
              </record>

              <record id="page_${p.id}" model="website.page">
                <field name="name">${p.name}</field>
                <field name="url">${url}</field>
                <field name="website_published">True</field>
                <field name="view_id" ref="view_${p.id}"/>
                ${lib.optionalString (p ? groups && p.groups != [ ]) ''
                  <field name="visibility">restricted_group</field>
                  <field name="groups_id" eval="[${
                    lib.concatStringsSep ", " (map (g: "(4, ref('${g}'))") p.groups)
                  }]"/>
                ''}
              </record>
            '') validatedPages
          )}
        </odoo>
      '';

      toPython =
        val:
        if builtins.isAttrs val then
          "{\n"
          + (lib.concatStringsSep ",\n" (
            lib.mapAttrsToList (k: v: "  ${builtins.toJSON k}: ${toPython v}") val
          ))
          + "\n}"
        else if builtins.isList val then
          "[ " + (lib.concatStringsSep ", " (map toPython val)) + " ]"
        else if builtins.isBool val then
          (if val then "True" else "False")
        else if val == null then
          "None"
        else
          builtins.toJSON val;

      manifest = {
        name = name;
        version = version;
        depends = depends;
        data = [ "views/pages.xml" ];
        installable = true;
        auto_install = false;
        application = false;
      };
      manifestStr = toPython manifest;
    in
    pkgs.stdenvNoCC.mkDerivation {
      pname = name;
      inherit version;
      dontUnpack = true;
      nativeBuildInputs = [ pkgs.libxml2 ];

      buildPhase = ''
        mkdir -p $out/${name}/views
        echo '${manifestStr}' > $out/${name}/__manifest__.py

        cat <<'EOF' > $out/${name}/views/pages.xml
        ${pagesXml}
        EOF

        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (path: code: ''
            mkdir -p "$(dirname "$out/${name}/${path}")"
            cat <<'EOF' > "$out/${name}/${path}"
            ${code}
            EOF
          '') pythonFiles
        )}

        # Automatically generate __init__.py files recursively
        echo "Generating __init__.py files..."
        find "$out/${name}" -type d | sort -r | while read -r dir; do
          if [ "$(basename "$dir")" = "views" ]; then
            continue
          fi
          
          init_file="$dir/__init__.py"
          if [ -f "$init_file" ] && [ -s "$init_file" ]; then
            echo "Preserving user-defined $init_file"
            continue
          fi
          
          > "$init_file"
          
          # Add .py file imports (except __init__.py and __manifest__.py)
          find "$dir" -maxdepth 1 -name "*.py" ! -name "__init__.py" ! -name "__manifest__.py" | while read -r pyfile; do
            mod_name=$(basename "$pyfile" .py)
            echo "from . import $mod_name" >> "$init_file"
          done
          
          # Add subdirectory imports if they contain __init__.py
          find "$dir" -maxdepth 1 -mindepth 1 -type d | while read -r subdir; do
            if [ -f "$subdir/__init__.py" ]; then
              sub_name=$(basename "$subdir")
              echo "from . import $sub_name" >> "$init_file"
            fi
          done
        done

        echo "Validating XML layout for ${name}..."
        xmllint --noout $out/${name}/views/pages.xml
      '';

      installPhase = "true";
    };

  # Helper to evaluate Odoo configurations
  evalOdoo =
    { modules
    , pkgs
    , lib ? pkgs.lib
    , specialArgs ? { }
    ,
    }:
    let
      eval = lib.evalModules {
        modules = [
          ./module.nix
        ]
        ++ modules;
        specialArgs = {
          inherit pkgs;
        }
        // specialArgs;
      };
    in
    eval.config.services.odoo;

  # A builder function that evaluates Odoo stack configurations in the Odoo Nix module system
  odooSystem =
    { modules
    , pkgs
    , lib ? pkgs.lib
    , specialArgs ? { }
    ,
    }:
    let
      eval = lib.evalModules {
        modules = [
          ./module.nix
        ]
        ++ modules;
        specialArgs = {
          inherit pkgs;
        }
        // specialArgs;
      };
    in
    eval.config.services.odoo.container;

  # A generic builder for standard directory-based Odoo addons
  buildOdooAddon =
    { pname
    , src
    , version ? "1.0.0"
    , meta ? { }
    }:
    pkgs.stdenvNoCC.mkDerivation {
      inherit pname version src;

      nativeBuildInputs = [ pkgs.libxml2 pkgs.python3 ];

      buildPhase = ''
        echo "Validating Odoo manifest..."
        if [ ! -f __manifest__.py ]; then
          echo "Error: __manifest__.py not found in source!" >&2
          exit 1
        fi
        python3 -c "import ast; ast.parse(open('__manifest__.py').read())" || {
          echo "Error: __manifest__.py contains invalid Python syntax!" >&2
          exit 1
        }

        echo "Validating XML views..."
        find . -name "*.xml" -exec xmllint --noout {} +

        # Create output directory structure
        mkdir -p $out/${pname}
        cp -r * $out/${pname}/
      '';

      installPhase = "true";

      inherit meta;
    };
}
