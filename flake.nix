{
  description = "A script to try to methodically test and rollback on each input upgrade";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    flake-utils.url = "github:numtide/flake-utils/v1.0.0";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ...
    }:
    # TODO: check if this works outside of defaults
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        apps = {
          default = self.apps.${system}.parse-and-update-flake;

          parse-and-update-flake = flake-utils.lib.mkApp {
            drv = self.packages.${system}.parse-and-update-flake;
          };
        };

        checks = self.packages.${system};

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [ shellcheck dash bash jq ];
        };

        packages =
          let
            inherit (nixpkgs) lib;

            writeJq =
              with pkgs.writers;
              let
                interpreter = "${pkgs.jq}/bin/jq -jf";
              in
              name: argsOrScript:
              if builtins.isAttrs argsOrScript && !lib.isDerivation argsOrScript then
                makeScriptWriter (argsOrScript // { inherit interpreter; }) name
              else
                makeScriptWriter { inherit interpreter; } name argsOrScript;

            writeJqBin = name: writeJq "/bin/${name}";
          in
          {
            default = self.packages.${system}.parse-and-update-flake;

            parse-and-update-flake =
              pkgs.writers.writeDashBin "parse-and-update-flake"
                {
                  check = "${lib.getExe pkgs.shellcheck} --shell=sh";
                  makeWrapperArgs = [
                    "--prefix"
                    "PATH"
                    ":"
                    (lib.makeBinPath [
                      pkgs.coreutils
                      self.packages.${system}.parse-flake-inputs
                      self.packages.${system}.update-flake
                    ])
                  ];
                }
                ''
                  # For some reason, Lix refuses to not do string interpolation in lines
                  FLAKE_DIR="${"\${1:-.}"}"
                  FLAKE_FILE="$FLAKE_DIR/flake.lock"
                  TEMP_FILE=$(mktemp)

                  echo "Parsing $FLAKE_FILE to CSV"
                  parse-flake-inputs "$FLAKE_FILE" > "$TEMP_FILE"

                  echo "Attempting upgrades"
                  update-flake "$FLAKE_DIR" "$TEMP_FILE"

                  rm "$TEMP_FILE"
                ''
              // {
                meta = {
                  description = "Script to update a flake given a path to a flake.";
                  homepage = "https://git.sr.ht/~cyntheticfox/update-flake";
                  license = lib.licenses.bsd3;
                  maintainers = with lib.maintainers; [ cyntheticfox ];
                  mainProgram = "parse-and-update-flake";
                };
              };

            parse-flake-inputs =
              writeJqBin "parse-flake-inputs" (builtins.readFile ./parse-flake-inputs.jq)
              // {
                meta = {
                  description = "Script to parse `flake.nix` into a CSV of update information.";
                  homepage = "https://git.sr.ht/~cyntheticfox/update-flake";
                  license = lib.licenses.bsd3;
                  maintainers = with lib.maintainers; [ cyntheticfox ];
                  mainProgram = "parse-flake-inputs";
                };
              };

            update-flake =
              pkgs.writers.writeBashBin "update-flake" {
                check = "${lib.getExe pkgs.shellcheck} --shell=bash";

                makeWrapperArgs = [
                  "--prefix"
                  "PATH"
                  ":"
                  (lib.makeBinPath (
                    with pkgs;
                    [
                      coreutils
                      curl
                      nix
                    ]
                  ))
                ];
              } (builtins.readFile ./update-flake.sh)
              // {
                meta = {
                  description = "Script to update a flake given a CSV of update information.";
                  homepage = "https://git.sr.ht/~cyntheticfox/update-flake";
                  license = lib.licenses.bsd3;
                  maintainers = with lib.maintainers; [ cyntheticfox ];
                  mainProgram = "update-flake";
                };
              };
          };
      }
    );
}
