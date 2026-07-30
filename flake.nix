{
  description = "db-harbor - generic database-operation plans and NixOS systemd wiring";

  inputs = {
    rs-harbor.url = "git+https://codeberg.org/caniko/rs-harbor.git?ref=trunk&rev=c26b735eede8078f795651c4a9cbf0be8733b221";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    crane.url = "github:ipetkov/crane";
  };

  outputs = {
    self,
    rs-harbor,
    nixpkgs,
    crane,
  }: let
    systems = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    forAllSystems = f:
      nixpkgs.lib.genAttrs systems (system:
        let
          pkgs = import nixpkgs {inherit system;};
          toolchain = rs-harbor.lib.mkToolchain { inherit pkgs; toolchainProfile = "stable"; };
        in
        f {
          inherit system pkgs toolchain;
          craneLib = (crane.mkLib pkgs).overrideToolchain toolchain;
        });
  in {
    nixosModules.db-harbor = import ./nix/module.nix;
    nixosModules.pg-backup = import ./nix/pg-backup.nix;
    nixosModules.default = self.nixosModules.db-harbor;

    packages = forAllSystems ({
      pkgs,
      craneLib,
      ...
    }: let
      commonArgs = {
        src = craneLib.cleanCargoSource ./.;
        pname = "db-harbor";
        version = "0.1.0";
        strictDeps = true;
        cargoExtraArgs = "--locked";
        meta = {
          description = "Generic database-operation plans and deployment orchestration for services";
          homepage = "https://codeberg.org/caniko/migrationix";
          license = pkgs.lib.licenses.asl20;
          mainProgram = "db-harbor";
        };
      };
      cargoArtifacts = craneLib.buildDepsOnly commonArgs;
      buildCache = rs-harbor.lib.mkBuildCachePolicy {
        inherit pkgs;
        sccachePackage = rs-harbor.packages.${pkgs.stdenv.hostPlatform.system}.sccache;
        cacheRoot = null;
        namespaceScope = "canix-rust";
        namespaceGeneration = 5;
      };
      db-harbor = buildCache.withRustCache {
        package = craneLib.buildPackage (commonArgs // {inherit cargoArtifacts;});
      };
    in {
      inherit db-harbor;
      default = db-harbor;
    });

    checks = forAllSystems ({
      pkgs,
      craneLib,
      ...
    }: let
      src = craneLib.cleanCargoSource ./.;
      commonArgs = {
        inherit src;
        pname = "db-harbor";
        version = "0.1.0";
        strictDeps = true;
        cargoExtraArgs = "--locked";
      };
      cargoArtifacts = craneLib.buildDepsOnly commonArgs;
    in {
      module-smoke = pkgs.callPackage ./nix/test-module.nix {
        module = self.nixosModules.default;
        dbHarborPackage = self.packages.${pkgs.stdenv.hostPlatform.system}.db-harbor;
      };
      pg-backup-eval = pkgs.callPackage ./nix/pg-backup-eval.nix {};
      db-harbor = self.packages.${pkgs.stdenv.hostPlatform.system}.db-harbor;
      cargo-fmt = craneLib.cargoFmt {
        inherit src;
        pname = "db-harbor";
      };
      cargo-test = craneLib.cargoTest (commonArgs
        // {
          inherit cargoArtifacts;
          cargoExtraArgs = "--all-targets --all-features --locked";
        });
      cargo-clippy = craneLib.cargoClippy (commonArgs
        // {
          inherit cargoArtifacts;
          cargoExtraArgs = "--all-targets --all-features --locked";
          cargoClippyExtraArgs = "-- -D warnings";
        });
    });

    formatter = forAllSystems ({pkgs, ...}: pkgs.alejandra);

    devShells = forAllSystems ({pkgs, ...}: let
      packages = [
        pkgs.alejandra
        pkgs.cargo
        pkgs.cargo-nextest
        pkgs.clippy
        pkgs.gcc
        pkgs.nixd
        pkgs.rustc
        pkgs.rustfmt
      ];
    in {
      default = pkgs.mkShell {inherit packages;};
      docs = pkgs.mkShell {inherit packages;};
    });
  };
}
