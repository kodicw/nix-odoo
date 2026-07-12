{ pkgs, lib }:

let
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

  mkOdooAddon =
    # Build a declarative Odoo module from Nix attributes
    { name
    , version ? "1.0.0"
    , depends ? [ "website" ]
    , pages ? { }
    , # url -> { id, name, template ? "", templateFile ? null, groups ? [] }
      pythonFiles ? { }
    , # filepath -> python code string
    }:
    let
      getTemplate =
        p:
        let
          template = if p ? template then p.template else null;
          templateFile = if p ? templateFile then p.templateFile else null;
        in
        if templateFile != null then builtins.readFile templateFile else template;

      # Evaluation-time assertions
      validatePage =
        url: p:
        let
          template = getTemplate p;
          hasTemplate = p ? template && p.template != null;
          hasTemplateFile = p ? templateFile && p.templateFile != null;
        in
        assert lib.assertMsg (p ? id) "Odoo Page URL '${url}' must specify a string 'id'";
        assert lib.assertMsg (p ? name) "Odoo Page '${p.id}' must specify a 'name'";
        assert lib.assertMsg
          (
            template != null
          ) "Odoo Page '${p.id}' must specify 'template' or 'templateFile'";
        assert lib.assertMsg
          (
            !(hasTemplate && hasTemplateFile)
          ) "Odoo Page '${p.id}' cannot specify both 'template' and 'templateFile'";
        p;

      validatedPages = lib.mapAttrs (url: p: validatePage url p) pages;

      getPageTemplate = getTemplate;

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

  mkOdooModule =
    { name
    , src
    , version ? "1.0.0"
    , checkSchema ? false
    , odoo ? null
    , postgresql ? null
    ,
    }:
      assert lib.assertMsg
        (
          checkSchema -> odoo != null && postgresql != null
        ) "When checkSchema is enabled, both 'odoo' and 'postgresql' packages must be provided.";
      pkgs.stdenvNoCC.mkDerivation {
        pname = name;
        inherit version;
        src = src;

        nativeBuildInputs = [
          pkgs.libxml2
          pkgs.python3
        ]
        ++ lib.optionals checkSchema [
          odoo
          postgresql
        ];

        installPhase = ''
          runHook preInstall

          mkdir -p $out/${name}
          cp -r ./* $out/${name}/

          # Check that manifest exists
          if [ ! -f "$out/${name}/__manifest__.py" ]; then
            echo "ERROR: Odoo module manifest '__manifest__.py' not found in source!" >&2
            exit 1
          fi

          # Validate python compilation
          echo "Validating Python files compile successfully..."
          python3 -m compileall -q "$out/${name}"

          # Validate XML files
          echo "Validating XML files..."
          find "$out/${name}" -name "*.xml" | while read -r xmlfile; do
            echo "Checking $xmlfile..."
            xmllint --noout "$xmlfile"
          done

          # If schema checking is enabled, perform E2E database verification
          if [ "${toString checkSchema}" = "1" ]; then
            echo "Starting sandboxed PostgreSQL and Odoo schema validation..."
            export PGDATA=$TMPDIR/postgres
            export HOME=$TMPDIR
          
            # Initialize PostgreSQL database cluster
            initdb --no-locale --encoding=UTF8 -U odoo_user
          
            # Configure PostgreSQL settings in postgresql.conf
            # Using a unique subdirectory inside /tmp avoids socket file collisions
            SOCKET_DIR=$(mktemp -d /tmp/pg-socket-XXXXXX)
            echo "unix_socket_directories = '$SOCKET_DIR'" >> $PGDATA/postgresql.conf
            echo "listen_addresses = '''" >> $PGDATA/postgresql.conf
          
            # Start PostgreSQL server
            pg_ctl start
          
            # Create odoo database
            createdb -h "$SOCKET_DIR" -U odoo_user -E UTF8 odoo
          
            # Run Odoo to install this module
            odoo -d odoo \
                 --db_host="$SOCKET_DIR" \
                 --db_user=odoo_user \
                 --addons-path="$out" \
                 -i ${name} \
                 --stop-after-init
               
            # Cleanly stop PostgreSQL
            pg_ctl stop
            echo "SUCCESS: Sandboxed database schema validation passed."
          fi

          runHook postInstall
        '';
      };
  mkOdooTheme =
    { name
    , version ? "1.0.0"
    , depends ? [ "website" ]
    , scss ? null
    , js ? null
    , views ? null
    , logo ? null
    , favicon ? null
    , primaryVariables ? null
    , backend ? null
    ,
    }:
    let
      scssPath = "static/src/scss/theme.scss";
      jsPath = "static/src/js/theme.js";
      viewsPath = "views/templates.xml";
      primaryVariablesPath = "static/src/scss/primary_variables.scss";
      backendPath = "static/src/scss/backend_brand.scss";

      assets =
        lib.optionalAttrs (scss != null || js != null)
          {
            "web.assets_frontend" =
              (lib.optional (scss != null) "${name}/${scssPath}")
              ++ (lib.optional (js != null) "${name}/${jsPath}");
          }
        // lib.optionalAttrs (primaryVariables != null) {
          "web._assets_primary_variables" = [ "${name}/${primaryVariablesPath}" ];
        }
        // lib.optionalAttrs (backend != null) {
          "web.assets_backend" = [ "${name}/${backendPath}" ];
        };

      manifest = {
        name = name;
        version = version;
        depends = depends;
        data = lib.optional (views != null) viewsPath;
        assets = assets;
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
        mkdir -p $out/${name}
        echo '${manifestStr}' > $out/${name}/__manifest__.py
        touch $out/${name}/__init__.py

        ${lib.optionalString (scss != null) ''
          mkdir -p "$out/${name}/static/src/scss"
          cat <<'EOF' > "$out/${name}/${scssPath}"
          ${scss}
          EOF
        ''}

        ${lib.optionalString (js != null) ''
          mkdir -p "$out/${name}/static/src/js"
          cat <<'EOF' > "$out/${name}/${jsPath}"
          ${js}
          EOF
        ''}

        ${lib.optionalString (primaryVariables != null) ''
          mkdir -p "$out/${name}/static/src/scss"
          cat <<'EOF' > "$out/${name}/${primaryVariablesPath}"
          ${primaryVariables}
          EOF
        ''}

        ${lib.optionalString (backend != null) ''
          mkdir -p "$out/${name}/static/src/scss"
          cat <<'EOF' > "$out/${name}/${backendPath}"
          ${backend}
          EOF
        ''}

        ${lib.optionalString (logo != null) ''
          mkdir -p "$out/${name}/static/src/img"
          cp "${logo}" "$out/${name}/static/src/img/logo.svg"
        ''}

        ${lib.optionalString (favicon != null) ''
          mkdir -p "$out/${name}/static/src/img"
          cp "${favicon}" "$out/${name}/static/src/img/favicon.svg"
        ''}

        ${lib.optionalString (views != null) ''
          mkdir -p "$out/${name}/views"
          cat <<'EOF' > "$out/${name}/${viewsPath}"
          ${views}
          EOF
          echo "Validating theme XML templates..."
          xmllint --noout "$out/${name}/${viewsPath}"
        ''}
      '';

      installPhase = "true";
    };
in
{
  inherit mkOdooAddon mkOdooModule mkOdooTheme;
}
