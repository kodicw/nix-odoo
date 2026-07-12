{ pkgs, lib }:

rec {
  # Build a declarative Odoo module from Nix attributes
  mkOdooAddon =
    { name
    , version ? "1.0.0"
    , depends ? [ "website" ]
    , pages ? { } # url -> { id, name, template ? "", templateFile ? null, groups ? [] }
    , pythonFiles ? { } # filepath -> python code string
    }:
    let
      # Evaluation-time assertions
      validatePage = url: p:
        assert lib.assertMsg (p ? id) "Odoo Page URL '${url}' must specify a string 'id'";
        assert lib.assertMsg (p ? name) "Odoo Page '${p.id}' must specify a 'name'";
        assert lib.assertMsg (p.template != null || p.templateFile != null) "Odoo Page '${p.id}' must specify 'template' or 'templateFile'";
        assert lib.assertMsg (!(p.template != null && p.templateFile != null)) "Odoo Page '${p.id}' cannot specify both 'template' and 'templateFile'";
        p;

      validatedPages = lib.mapAttrs (url: p: validatePage url p) pages;

      getPageTemplate = p:
        if p.templateFile != null then builtins.readFile p.templateFile else p.template;

      pagesXml = ''
        <?xml version="1.0" encoding="utf-8"?>
        <odoo>
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (url: p: ''
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
              ${lib.optionalString (p ? groups) ''
                <field name="visibility">restricted_group</field>
                <field name="groups_id" eval="[${lib.concatStringsSep ", " (map (g: "(4, ref('${g}'))") p.groups)}]"/>
              ''}
            </record>
          '') validatedPages)}
        </odoo>
      '';

      manifest = {
        name = name;
        version = version;
        depends = depends;
        data = [ "views/pages.xml" ];
        installable = true;
        auto_install = false;
        application = false;
      };
      manifestStr = builtins.toJSON manifest;
    in
    pkgs.stdenvNoCC.mkDerivation {
      pname = name;
      inherit version;
      dontUnpack = true;
      nativeBuildInputs = [ pkgs.libxml2 ];

      buildPhase = ''
        mkdir -p $out/${name}/views
        echo '${manifestStr}' > $out/${name}/__manifest__.py
        touch $out/${name}/__init__.py
        
        cat <<'EOF' > $out/${name}/views/pages.xml
        ${pagesXml}
        EOF

        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (path: code: ''
          mkdir -p "$(dirname "$out/${name}/${path}")"
          cat <<'EOF' > "$out/${name}/${path}"
          ${code}
          EOF
        '') pythonFiles)}

        echo "Validating XML layout for ${name}..."
        xmllint --noout $out/${name}/views/pages.xml
      '';

      installPhase = "true";
    };

  # Helper to evaluate Odoo configurations
  evalOdoo = { modules, pkgs, lib ? pkgs.lib, specialArgs ? { } }:
    let
      eval = lib.evalModules {
        modules = [
          ./module.nix
        ] ++ modules;
        specialArgs = { inherit pkgs; } // specialArgs;
      };
    in
    eval.config.services.odoo;

  # A builder function that evaluates Odoo stack configurations in the Odoo Nix module system
  odooSystem = { modules, pkgs, lib ? pkgs.lib, specialArgs ? { } }:
    let
      eval = lib.evalModules {
        modules = [
          ./module.nix
        ] ++ modules;
        specialArgs = { inherit pkgs; } // specialArgs;
      };
    in
    eval.config.services.odoo.container;
}
