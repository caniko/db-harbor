{
  lib,
  migrationixPackage,
  module,
  pkgs,
}:
pkgs.testers.nixosTest {
  name = "migrationix-module-smoke";

  nodes.machine = {pkgs, ...}: let
    multiMigrator = pkgs.writeShellScriptBin "multi-migrator" ''
      set -eu
      case "$1" in
        apply-schema)
          mkdir -p /var/lib/migrationix-demo
          touch /var/lib/migrationix-demo/structured-schema
          echo structured-schema >> /var/lib/migrationix-demo/structured-events
          ;;
        check-schema)
          test -f /var/lib/migrationix-demo/structured-schema
          ;;
        apply-manual)
          mkdir -p /var/lib/migrationix-demo
          touch /var/lib/migrationix-demo/structured-manual
          echo structured-manual >> /var/lib/migrationix-demo/structured-events
          ;;
        check-manual)
          true
          ;;
        *)
          echo "unknown command: $1" >&2
          exit 64
          ;;
      esac
    '';
  in {
    imports = [module];

    systemd.tmpfiles.rules = ["d /var/lib/migrationix-demo 0775 postgres postgres -"];

    services.postgresql = {
      enable = true;
      ensureDatabases = ["migrationix_project"];
      ensureUsers = [
        {name = "project_app";}
      ];
    };

    systemd.services.postgresql-setup.script = lib.mkAfter ''
      psql -d migrationix_project -tAc "CREATE TABLE IF NOT EXISTS project_item (id bigserial primary key);"
    '';

    users.users.project_app = {
      isSystemUser = true;
      group = "project_app";
    };
    users.groups.project_app = {};

    systemd.services.project-app = {
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.writeShellScript "project-app" ''
          test -f /var/lib/migrationix-demo/project-stamp
          echo project-app-started >> /var/lib/migrationix-demo/project-events
        ''}";
      };
    };

    systemd.services.demo-app = {
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.writeShellScript "demo-app" ''
          test -f /var/lib/migrationix-demo/stamp
          echo app-started >> /var/lib/migrationix-demo/events
        ''}";
      };
    };

    systemd.services.multi-app = {
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.writeShellScript "multi-app" ''
          test -f /var/lib/migrationix-demo/structured-schema
          test ! -e /var/lib/migrationix-demo/structured-manual
          echo structured-app-started >> /var/lib/migrationix-demo/structured-events
        ''}";
      };
    };

    services.migrationix.migrations.demo = {
      enable = true;
      description = "Demo migration";
      command = "${pkgs.writeShellScript "demo-migration" ''
        mkdir -p /var/lib/migrationix-demo
        touch /var/lib/migrationix-demo/stamp
        echo migrated >> /var/lib/migrationix-demo/events
      ''}";
      checkCommand = "${pkgs.writeShellScript "demo-migration-check" ''
        test -f /var/lib/migrationix-demo/stamp
      ''}";
      beforeUnits = ["demo-app.service"];
      requiredByUnits = ["demo-app.service"];
      serviceConfig.ReadWritePaths = ["/var/lib/migrationix-demo"];
    };

    services.migrationix.projects.project = {
      enable = true;
      description = "Project migration";
      runner = {
        package = pkgs.writeShellScriptBin "project-migrator" ''
          set -eu
          case "$1" in
            apply)
              touch "$2/project-stamp"
              echo project-migrated >> "$2/project-events"
              ;;
            check)
              test -f "$2/project-stamp"
              ;;
            *)
              echo "unknown command: $1" >&2
              exit 64
              ;;
          esac
        '';
        executable = "bin/project-migrator";
        args = ["apply" "/var/lib/migrationix-demo"];
        checkArgs = ["check" "/var/lib/migrationix-demo"];
      };
      user = "postgres";
      group = "postgres";
      runtimeUnits = ["project-app.service"];
      postgres = {
        enable = true;
        databaseUrl = "postgres:///migrationix_project?host=/run/postgresql";
        setupUnits = ["postgresql-setup.service"];
        grants = {
          enable = true;
          runtimeRole = "project_app";
        };
      };
      serviceConfig.ReadWritePaths = ["/var/lib/migrationix-demo"];
    };

    services.migrationix.projects.structured = {
      enable = true;
      description = "Structured migration plan";
      operations = {
        schema = {
          enable = true;
          backend = "postgres";
          phase = "schema";
          runner = {
            package = multiMigrator;
            executable = "bin/multi-migrator";
            args = ["apply-schema"];
            checkArgs = ["check-schema"];
          };
        };
        manual = {
          enable = true;
          backend = "clickhouse";
          phase = "operational";
          safety = "operator_confirmed";
          runner = {
            package = multiMigrator;
            executable = "bin/multi-migrator";
            args = ["apply-manual"];
            checkArgs = ["check-manual"];
          };
          dependsOn = ["schema"];
        };
      };
      runtimeUnits = ["multi-app.service"];
      serviceConfig.ReadWritePaths = ["/var/lib/migrationix-demo"];
    };
  };

  testScript = ''
    machine.wait_until_succeeds("systemctl show migrationix-demo.service -p Result --value | grep -Fx success")
    machine.wait_until_succeeds("systemctl show demo-app.service -p Result --value | grep -Fx success")
    machine.wait_for_unit("postgresql-setup.service")
    machine.succeed("systemctl start project-app.service")
    machine.wait_until_succeeds("systemctl show migrationix-project.service -p Result --value | grep -Fx success")
    machine.wait_until_succeeds("systemctl show project-app.service -p Result --value | grep -Fx success")
    machine.succeed("systemctl start multi-app.service")
    machine.wait_until_succeeds("systemctl show migrationix-structured.service -p Result --value | grep -Fx success")
    machine.wait_until_succeeds("systemctl show multi-app.service -p Result --value | grep -Fx success")
    machine.succeed("test -f /var/lib/migrationix-demo/structured-schema")
    machine.succeed("test ! -e /var/lib/migrationix-demo/structured-manual")
    machine.succeed("systemctl start migrationix-structured-check.service")
    machine.succeed("test -f /var/lib/migrationix-demo/stamp")
    machine.succeed("test -f /var/lib/migrationix-demo/project-stamp")
    machine.succeed("grep -n migrated /var/lib/migrationix-demo/events")
    machine.succeed("grep -n project-migrated /var/lib/migrationix-demo/project-events")
    machine.succeed("grep -n app-started /var/lib/migrationix-demo/events")
    machine.succeed("grep -n project-app-started /var/lib/migrationix-demo/project-events")
    machine.succeed("systemctl start migrationix-demo.service")
    machine.succeed("systemctl start migrationix-demo-check.service")
    machine.succeed("systemctl start migrationix-project.service")
    machine.succeed("systemctl start migrationix-project-check.service")
    machine.succeed("test $(grep -c migrated /var/lib/migrationix-demo/events) -ge 2")
    machine.succeed("sudo -u project_app psql -d migrationix_project -tAc 'INSERT INTO project_item DEFAULT VALUES RETURNING id;' | grep -Fx 1")
  '';
}
