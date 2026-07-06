# migrationix

`migrationix` provides generic NixOS systemd wiring for project-owned,
idempotent migrations.

The flake does not know about a migration framework, database, or application.
Consumers provide full commands and dependency ordering:

```nix
{
  imports = [inputs.migrationix.nixosModules.default];

  services.migrationix.migrations.my-app = {
    enable = true;
    command = "${pkgs.my-app}/bin/my-app migrate";
    checkCommand = "${pkgs.my-app}/bin/my-app migrate --check";
    after = ["postgresql-setup.service"];
    requires = ["postgresql-setup.service"];
    beforeUnits = ["my-app.service"];
    requiredByUnits = ["my-app.service"];
    serviceConfig.ReadWritePaths = ["/var/lib/my-app"];
  };
}
```

This generates `migrationix-my-app.service`, a `Type=oneshot` unit without
`RemainAfterExit`, so starting a dependent application unit can re-run the
idempotent migration command when needed.
