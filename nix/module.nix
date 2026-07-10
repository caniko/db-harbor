{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkMerge mkOption optionalAttrs types;

  cfg = config.services.migrationix;

  migrationixPackage = pkgs.rustPlatform.buildRustPackage {
    pname = "migrationix";
    version = "0.1.0";
    src = ../.;
    cargoLock.lockFile = ../Cargo.lock;
  };

  sqlIdentifier = value: "\"" + builtins.replaceStrings ["\""] ["\"\""] value + "\"";

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

  runnerType = types.submodule {
    options = {
      package = mkOption {
        type = types.nullOr types.package;
        default = null;
        description = "Optional package containing the migration executable.";
      };

      executable = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "bin/my-app";
        description = "Executable path, relative to package when package is set or absolute otherwise.";
      };

      args = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Arguments passed to the migration executable.";
      };

      checkArgs = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = "Arguments passed to the migration executable for read-only readiness checks.";
      };

      command = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Full migration command. Overrides package/executable/args when set.";
      };

      checkCommand = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Full read-only readiness check command. Overrides package/executable/checkArgs when set.";
      };
    };
  };

  operationType = types.submodule ({name, ...}: {
    options = {
      enable = mkEnableOption "migrationix operation ${name}";

      backend = mkOption {
        type = types.enum ["generic" "postgres" "clickhouse"];
        default = "generic";
        description = "Database family owned by this operation.";
      };

      phase = mkOption {
        type = types.enum ["schema" "backfill" "operational"];
        default = "schema";
        description = "Lifecycle phase used for reporting and deployment policy.";
      };

      safety = mkOption {
        type = types.enum ["automatic" "operator_confirmed"];
        default = "automatic";
        description = "Whether apply runs this operation during normal activation.";
      };

      runner = mkOption {
        type = runnerType;
        default = {};
        description = "Structured apply/check command for this operation.";
      };

      dependsOn = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Operation identifiers that must run first.";
      };
    };
  });

  grantType = types.submodule {
    options = {
      enable = mkEnableOption "post-migration PostgreSQL grants";

      runtimeRole = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "PostgreSQL role used by runtime services after migrations have run.";
      };

      schema = mkOption {
        type = types.str;
        default = "public";
        description = "PostgreSQL schema to grant runtime privileges on.";
      };

      tablePrivileges = mkOption {
        type = types.listOf types.str;
        default = ["SELECT" "INSERT" "UPDATE" "DELETE"];
        description = "Table privileges granted to runtimeRole on all current tables in schema.";
      };

      sequencePrivileges = mkOption {
        type = types.listOf types.str;
        default = ["USAGE" "SELECT" "UPDATE"];
        description = "Sequence privileges granted to runtimeRole on all current sequences in schema.";
      };
    };
  };

  postgresType = types.submodule {
    options = {
      enable = mkEnableOption "PostgreSQL migration helpers";

      databaseUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "PostgreSQL connection URL used by generated grant commands.";
      };

      setupUnits = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["postgresql-setup.service"];
        description = "PostgreSQL setup units the migration must run after and require.";
      };

      package = mkOption {
        type = types.package;
        default =
          if config.services.postgresql.enable or false
          then config.services.postgresql.package
          else pkgs.postgresql;
        defaultText = "config.services.postgresql.package or pkgs.postgresql";
        description = "PostgreSQL package providing psql for generated helper commands.";
      };

      grants = mkOption {
        type = grantType;
        default = {};
        description = "Optional grants applied after the migration command succeeds.";
      };
    };
  };

  projectType = types.submodule ({name, ...}: {
    options = {
      enable = mkEnableOption "migrationix project ${name}";

      description = mkOption {
        type = types.str;
        default = "${name} database migrations";
        description = "Human-readable description for the generated migration unit.";
      };

      runner = mkOption {
        type = runnerType;
        default = {};
        description = "Command runner used to apply and optionally check migrations.";
      };

      operations = mkOption {
        type = types.attrsOf operationType;
        default = {};
        description = "Structured migration operations. The runner shorthand becomes the default operation.";
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
        description = "Environment variables for generated migration units.";
      };

      path = mkOption {
        type = types.listOf types.package;
        default = [];
        description = "Packages added to PATH for generated migration units.";
      };

      loadCredentials = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "systemd LoadCredential entries for generated migration units.";
      };

      after = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Additional units the generated migration unit should start after.";
      };

      requires = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Additional units required by the generated migration unit.";
      };

      wants = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Units wanted by the generated migration unit.";
      };

      runtimeUnits = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Runtime units ordered after and requiring the generated migration unit.";
      };

      serviceConfig = mkOption {
        type = types.attrs;
        default = {};
        description = "Additional or overriding systemd serviceConfig for generated migration units.";
      };

      postgres = mkOption {
        type = postgresType;
        default = {};
        description = "PostgreSQL-specific ordering and post-migration helpers.";
      };
    };
  });

  enabledMigrations = lib.filterAttrs (_: migration: migration.enable) cfg.migrations;
  enabledProjects = lib.filterAttrs (_: project: project.enable) cfg.projects;

  runnerConfigured = runner: runner.command != null || runner.executable != null;

  projectOperations = project:
    (lib.optionalAttrs (runnerConfigured project.runner) {
      default = {
        enable = true;
        backend =
          if project.postgres.enable
          then "postgres"
          else "generic";
        phase = "schema";
        safety = "automatic";
        runner = project.runner;
        dependsOn = [];
      };
    })
    // project.operations;

  enabledOperations = project:
    lib.filterAttrs (_: operation: operation.enable) (projectOperations project);

  projectHasChecks = project:
    lib.any
    (operation: operation.runner.checkCommand != null || operation.runner.checkArgs != null)
    (lib.attrValues (enabledOperations project));

  sqlLiteral = value: "'" + builtins.replaceStrings ["'"] ["''"] value + "'";

  fullCommandSpec = name: suffix: command: let
    script = pkgs.writeShellScript "migrationix-${name}-${suffix}" ''
      set -eu
      ${command}
    '';
  in {
    program = "${script}";
    args = [];
    environment = {};
  };

  runnerCommandSpec = name: suffix: runner: args:
    if runner.command != null
    then fullCommandSpec name suffix runner.command
    else {
      program =
        if runner.package != null
        then "${runner.package}/${runner.executable}"
        else runner.executable;
      inherit args;
      environment = {};
    };

  runnerCheckSpec = name: runner:
    if runner.checkCommand != null
    then fullCommandSpec name "check" runner.checkCommand
    else if runner.checkArgs != null
    then runnerCommandSpec name "check" (runner // {command = null;}) runner.checkArgs
    else null;

  grantApplySpec = name: project: {
    program = "${project.postgres.package}/bin/psql";
    args = [
      project.postgres.databaseUrl
      "-v"
      "ON_ERROR_STOP=1"
      "-c"
      "GRANT USAGE ON SCHEMA ${sqlIdentifier project.postgres.grants.schema} TO ${sqlIdentifier project.postgres.grants.runtimeRole};"
      "-c"
      "GRANT ${lib.concatStringsSep ", " project.postgres.grants.tablePrivileges} ON ALL TABLES IN SCHEMA ${sqlIdentifier project.postgres.grants.schema} TO ${sqlIdentifier project.postgres.grants.runtimeRole};"
      "-c"
      "GRANT ${lib.concatStringsSep ", " project.postgres.grants.sequencePrivileges} ON ALL SEQUENCES IN SCHEMA ${sqlIdentifier project.postgres.grants.schema} TO ${sqlIdentifier project.postgres.grants.runtimeRole};"
    ];
    environment = {};
  };

  grantCheckSpec = project: let
    grants = project.postgres.grants;
    tableChecks = map (privilege: "COALESCE((SELECT bool_and(has_table_privilege(${sqlLiteral grants.runtimeRole}, format('%I.%I', schemaname, tablename), ${sqlLiteral privilege})) FROM pg_tables WHERE schemaname = ${sqlLiteral grants.schema}), true)") grants.tablePrivileges;
    sequenceChecks = map (privilege: "COALESCE((SELECT bool_and(has_sequence_privilege(${sqlLiteral grants.runtimeRole}, format('%I.%I', sequence_schema, sequence_name), ${sqlLiteral privilege})) FROM information_schema.sequences WHERE sequence_schema = ${sqlLiteral grants.schema}), true)") grants.sequencePrivileges;
    checks =
      [
        "has_schema_privilege(${sqlLiteral grants.runtimeRole}, ${sqlLiteral grants.schema}, 'USAGE')"
      ]
      ++ tableChecks
      ++ sequenceChecks;
  in {
    program = "${project.postgres.package}/bin/psql";
    args = [
      project.postgres.databaseUrl
      "-v"
      "ON_ERROR_STOP=1"
      "-tAc"
      "SELECT ${lib.concatStringsSep " AND " checks};"
    ];
    environment = {};
  };

  operationToPlan = name: operation: {
    id = name;
    backend = operation.backend;
    phase = operation.phase;
    safety = operation.safety;
    apply = runnerCommandSpec name "apply" operation.runner operation.runner.args;
    check = runnerCheckSpec name operation.runner;
    depends_on = operation.dependsOn;
  };

  projectPlan = name: project: let
    operations = enabledOperations project;
    baseOperations = lib.mapAttrsToList operationToPlan operations;
    grantOperation = lib.optional (project.postgres.enable && project.postgres.grants.enable) {
      id = "postgres-grants";
      backend = "postgres";
      phase = "schema";
      safety = "automatic";
      apply = grantApplySpec name project;
      check = grantCheckSpec project;
      depends_on = ["default"];
    };
  in
    pkgs.writeText "migrationix-${name}-plan.json" (builtins.toJSON {
      version = 1;
      inherit name;
      operations = baseOperations ++ grantOperation;
    });

  projectApplyCommand = name: project:
    assert migrationixPackage != null;
      lib.escapeShellArgs [
        "${migrationixPackage}/bin/migrationix"
        "apply"
        "--manifest"
        (projectPlan name project)
      ];

  projectCheckCommand = name: project:
    assert migrationixPackage != null;
      lib.escapeShellArgs [
        "${migrationixPackage}/bin/migrationix"
        "check"
        "--manifest"
        (projectPlan name project)
      ];

  projectToMigration = name: project: {
    enable = true;
    inherit (project) description user group environment path loadCredentials wants serviceConfig;
    command = projectApplyCommand name project;
    checkCommand =
      if projectHasChecks project
      then projectCheckCommand name project
      else null;
    after = project.postgres.setupUnits ++ project.after;
    requires = project.postgres.setupUnits ++ project.requires;
    beforeUnits = project.runtimeUnits;
    requiredByUnits = project.runtimeUnits;
  };

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

    projects = mkOption {
      type = types.attrsOf projectType;
      default = {};
      description = "Higher-level project migration definitions lowered into migrationix.migrations.";
    };
  };

  config = mkMerge [
    (mkIf (enabledProjects != {}) {
      assertions = lib.flatten (lib.mapAttrsToList (name: project: let
        operations = enabledOperations project;
        operationAssertions = lib.flatten (lib.mapAttrsToList (operationName: operation: [
            {
              assertion = operation.runner.command != null || operation.runner.executable != null;
              message = "services.migrationix.projects.${name}.operations.${operationName}: set runner.command or runner.executable";
            }
            {
              assertion = operation.runner.command != null || operation.runner.package == null || operation.runner.executable != null;
              message = "services.migrationix.projects.${name}.operations.${operationName}: runner.package requires runner.executable when runner.command is unset";
            }
            {
              assertion = lib.all (dependency: builtins.hasAttr dependency operations) operation.dependsOn;
              message = "services.migrationix.projects.${name}.operations.${operationName}: dependsOn references an unknown operation";
            }
          ])
          operations);
      in
        [
          {
            assertion = operations != {};
            message = "services.migrationix.projects.${name}: configure runner or at least one enabled operation";
          }
          {
            assertion = !project.postgres.grants.enable || project.postgres.enable;
            message = "services.migrationix.projects.${name}: postgres.grants.enable requires postgres.enable";
          }
          {
            assertion = !project.postgres.grants.enable || project.postgres.databaseUrl != null;
            message = "services.migrationix.projects.${name}: postgres.databaseUrl is required when postgres.grants.enable is set";
          }
          {
            assertion = !project.postgres.grants.enable || project.postgres.grants.runtimeRole != null;
            message = "services.migrationix.projects.${name}: postgres.grants.runtimeRole is required when postgres.grants.enable is set";
          }
          {
            assertion = !project.postgres.grants.enable || builtins.hasAttr "default" operations;
            message = "services.migrationix.projects.${name}: postgres grants require the default migration operation";
          }
          {
            assertion = !project.postgres.grants.enable || project.postgres.grants.tablePrivileges != [];
            message = "services.migrationix.projects.${name}: postgres.grants.tablePrivileges must not be empty";
          }
          {
            assertion = !project.postgres.grants.enable || project.postgres.grants.sequencePrivileges != [];
            message = "services.migrationix.projects.${name}: postgres.grants.sequencePrivileges must not be empty";
          }
          {
            assertion =
              !(projectHasChecks project)
              || lib.all
              (operation: operation.runner.checkCommand != null || operation.runner.checkArgs != null)
              (lib.attrValues operations);
            message = "services.migrationix.projects.${name}: every enabled operation needs a read-only check when project checks are configured";
          }
        ]
        ++ operationAssertions)
      enabledProjects);

      services.migrationix.migrations = lib.mapAttrs projectToMigration enabledProjects;
    })

    (mkIf (enabledMigrations != {}) {
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
    })
  ];
}
