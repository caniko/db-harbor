{
  module,
  pkgs,
}:
pkgs.testers.nixosTest {
  name = "migrationix-module-smoke";

  nodes.machine = {pkgs, ...}: {
    imports = [module];

    systemd.tmpfiles.rules = ["d /var/lib/migrationix-demo 0755 root root -"];

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
  };

  testScript = ''
    machine.wait_until_succeeds("systemctl show migrationix-demo.service -p Result --value | grep -Fx success")
    machine.wait_until_succeeds("systemctl show demo-app.service -p Result --value | grep -Fx success")
    machine.succeed("test -f /var/lib/migrationix-demo/stamp")
    machine.succeed("grep -n migrated /var/lib/migrationix-demo/events")
    machine.succeed("grep -n app-started /var/lib/migrationix-demo/events")
    machine.succeed("systemctl start migrationix-demo.service")
    machine.succeed("systemctl start migrationix-demo-check.service")
    machine.succeed("test $(grep -c migrated /var/lib/migrationix-demo/events) -ge 2")
  '';
}
