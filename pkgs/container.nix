{
  dockerTools,
  writeShellScript,
  runCommand,
  lib,
  addonPackages ? [ ],
  baseConfigFile,
}:

let
  odooImage = dockerTools.pullImage {
    imageName = "odoo";
    imageDigest = "sha256:fb0bc12e909f1657ff4c54cb192695b95b72a7892948ec8972b508e6e97b7989";
    finalImageTag = "19";
    os = "linux";
    arch = "amd64";
    hash = "sha256-HJhPVem17OFYqYKMcLbhlID+XKK4ySmJOPiAV4scbLo=";
  };

  entrypointScript = writeShellScript "entrypoint-wrapper.sh" ''
        set -e

        echo "[pgmsp] Starting Odoo entrypoint..." >&2
        CONF=/tmp/odoo.conf

        echo "[pgmsp] Copying base config from Nix store..." >&2
        cp ${baseConfigFile} "$CONF"
        chmod 640 "$CONF"

        echo "[pgmsp] Appending runtime overrides from environment..." >&2
        cat >> "$CONF" <<EOF

    # Runtime dynamic overrides
    db_host = ''${DB_HOST:-}
    db_port = ''${DB_PORT:-5432}
    db_user = ''${DB_USER:-}
    db_password = ''${DB_PASSWORD:-}
    db_name = ''${DB_NAME:-False}
    dbfilter = ''${DB_FILTER:-.*}
    admin_passwd = ''${ADMIN_PASSWORD:-admin}
    workers = ''${ODOO_WORKERS:-2}
    max_cron_threads = ''${ODOO_MAX_CRON_THREADS:-2}
    proxy_mode = ''${ODOO_PROXY_MODE:-True}
    limit_memory_soft = ''${ODOO_MEMORY_LIMIT:-1073741824}
    limit_memory_hard = ''${ODOO_MEMORY_LIMIT_HARD:-1610612736}
    EOF

        # Wait for DB
        if [ -f /usr/local/bin/wait-for-psql.py ]; then
          echo "[pgmsp] Waiting for database..." >&2
          /usr/local/bin/wait-for-psql.py --timeout=60 || {
            rc=$?
            echo "[pgmsp] WARNING: wait-for-psql.py exited $rc - proceeding anyway" >&2
          }
        else
          echo "[pgmsp] wait-for-psql.py not found, skipping DB readiness check" >&2
        fi

        # Build extra args
        # We prioritize flags passed via command line ($@), then environment variables.
        EXTRA_ARGS=""
        if [[ "$*" != *"-u "* ]] && [[ "$*" != *"--update"* ]] && [ -n "$UPGRADE_MODULES" ]; then
          EXTRA_ARGS="$EXTRA_ARGS -u $UPGRADE_MODULES"
        fi
        if [[ "$*" != *"-i "* ]] && [[ "$*" != *"--init"* ]] && [ -n "$INSTALL_MODULES" ]; then
          EXTRA_ARGS="$EXTRA_ARGS -i $INSTALL_MODULES"
        fi
        if [[ "$*" != *"-d "* ]] && [[ "$*" != *"--database"* ]] && [ -n "$DB_NAME" ] && [ "$DB_NAME" != "False" ]; then
          EXTRA_ARGS="$EXTRA_ARGS -d $DB_NAME"
        fi

        echo "[pgmsp] Starting Odoo with config $CONF and args $EXTRA_ARGS $@" >&2
        exec odoo --config "$CONF" $EXTRA_ARGS "$@"
  '';

  rootLayer = runCommand "odoo-root-layer" { } ''
    mkdir -p $out/mnt/extra-addons
    ${lib.concatStringsSep "\n" (map (pkg: "cp -r ${pkg}/* $out/mnt/extra-addons/") addonPackages)}
    cp ${entrypointScript} $out/entrypoint-wrapper.sh
    chmod +x $out/entrypoint-wrapper.sh
  '';

in
dockerTools.buildImage {
  name = "pgmsp-odoo";
  tag = "latest";
  fromImage = odooImage;
  copyToRoot = [ rootLayer ];
  config = {
    Entrypoint = [ "/entrypoint-wrapper.sh" ];
    ExposedPorts = {
      "8069/tcp" = { };
    };
  };
}
