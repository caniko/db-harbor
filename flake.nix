{
  description = "migrationix - generic NixOS systemd wiring for idempotent project migrations";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    systems = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    forAllSystems = f:
      nixpkgs.lib.genAttrs systems (system:
        f {
          inherit system;
          pkgs = import nixpkgs {inherit system;};
        });
  in {
    nixosModules.migrationix = import ./nix/module.nix;
    nixosModules.default = self.nixosModules.migrationix;

    checks = forAllSystems ({pkgs, ...}: {
      module-smoke = pkgs.callPackage ./nix/test-module.nix {
        module = self.nixosModules.default;
      };
    });

    formatter = forAllSystems ({pkgs, ...}: pkgs.alejandra);

    devShells = forAllSystems ({pkgs, ...}: {
      default = pkgs.mkShell {
        packages = [
          pkgs.alejandra
          pkgs.nixd
        ];
      };
    });
  };
}
