{
  description = "Elixir Project Devenv";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    devenv.url = "github:cachix/devenv";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = {
    flake-utils,
    nixpkgs,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      # lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};
      in {
      devShell = pkgs.mkShell {
          buildInputs = with pkgs; [
            erlang
            elixir
            hex
            mix2nix
          ];
          LD_LIBRARY_PATH = "${pkgs.sqlite.out}/lib";
          shellHook = ''
            mix local.hex --force
            mix local.rebar --force
            mix deps.get
          '';
        };
    });
}
