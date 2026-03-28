{
  description = "Orim – dual-origin ICENODE e2e test harness";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    passveil.url = "github:doma-engineering/passveil";
  };

  outputs =
    {
      self,
      nixpkgs,
      passveil,
    }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          gcloud = pkgs.google-cloud-sdk.withExtraComponents (
            with pkgs.google-cloud-sdk.components;
            [
              alpha
              beta
            ]
          );
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.caddy
              pkgs.curl
              pkgs.jq
              pkgs.openssl
              pkgs.dig
              gcloud
            ]
            ++ pkgs.lib.optionals (passveil.packages ? ${system}) [
              passveil.packages.${system}.passveil
            ];
          };
        }
      );
    };
}
