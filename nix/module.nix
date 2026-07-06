{
  config,
  lib,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkMerge mkOption optionalAttrs types;

  cfg = config.services.migrationix;

  migrationType = types.submodule ({name, ...}: {
    options = {
      enable = mkEnableOption "migrationix migration ${name}";

      description = mkOption {
        type = types.str;
        default = "${name} migration";
        description = "Human-readable description for the migration unit.";
      };

      command = mkOption {
        type = types.str;
        description = "Full command that applies this migration idempotently.";
      };

      checkCommand = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Optional read-only command that reports pending or incompatible migrations.";
      };

      user = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "User to run the migration command as.";
      };

      group = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Group to run the migration command as.";
      };

      environment = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Environment variables for migration units.";
      };

      path = mkOption {
        type = types.listOf types.package;
        default = [];
        description = "Packages added to PATH for migration units.";
      };

      loadCredentials = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "systemd LoadCredential entries for migration units.";
      };

      after = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Units this migration unit should start after.";
      };

      requires = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Units required by this migration unit.";
      };

      wants = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Units wanted by this migration unit.";
      };

      beforeUnits = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Application units ordered after this migration unit.";
      };

      requiredByUnits = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Application units that require this migration unit.";
      };

      serviceConfig = mkOption {
        type = types.attrs;
        default = {};
        description = "Additional or overriding systemd serviceConfig for migration units.";
      };
    };
  });

  enabledMigrations = lib.filterAttrs (_: migration: migration.enable) cfg.migrations;

  serviceConfigFor = migration:
    {
      Type = "oneshot";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
    }
    // optionalAttrs (migration.user != null) {
      User = migration.user;
    }
    // optionalAttrs (migration.group != null) {
      Group = migration.group;
    }
    // optionalAttrs (migration.loadCredentials != []) {
      LoadCredential = migration.loadCredentials;
    }
    // migration.serviceConfig;

  migrationService = name: migration: {
    description = migration.description;
    inherit (migration) environment path;
    after = migration.after;
    requires = migration.requires;
    wants = migration.wants;
    before = migration.beforeUnits;
    requiredBy = migration.requiredByUnits;
    serviceConfig =
      serviceConfigFor migration
      // {
        ExecStart = migration.command;
      };
  };

  checkService = name: migration:
    mkIf (migration.checkCommand != null) {
      description = "${migration.description} readiness check";
      inherit (migration) environment path;
      after = migration.after;
      requires = migration.requires;
      wants = migration.wants;
      serviceConfig =
        serviceConfigFor migration
        // {
          ExecStart = migration.checkCommand;
        };
    };
in {
  options.services.migrationix = {
    migrations = mkOption {
      type = types.attrsOf migrationType;
      default = {};
      description = "Named idempotent migration commands managed as systemd oneshot units.";
    };
  };

  config = mkIf (enabledMigrations != {}) {
    assertions =
      lib.mapAttrsToList (name: _migration: {
        assertion = builtins.match "[A-Za-z0-9_.@-]+" name != null;
        message = "services.migrationix.migrations.${name}: migration names must be valid systemd unit-name fragments";
      })
      enabledMigrations;

    systemd.services =
      mkMerge
      [
        (lib.mapAttrs' (name: migration:
          lib.nameValuePair "migrationix-${name}" (migrationService name migration))
        enabledMigrations)
        (lib.mapAttrs' (name: migration:
          lib.nameValuePair "migrationix-${name}-check" (checkService name migration))
        enabledMigrations)
      ];
  };
}
