{
  description = "Repository-local ZigCSS source build";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/5dfba6236110080a54247d6460bc2ff5dda939cc";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      mkPackage =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          inherit (pkgs) lib;
          zig = pkgs.zig_0_15;
          version = lib.removeSuffix "\n" (builtins.readFile ./VERSION);
          source = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./build.zig
              ./build.zig.zon
              ./build_helpers.zig
              ./src
              ./VERSION
              ./README.md
              ./LICENSE
            ];
          };
        in
        assert zig.version == "0.15.2";
        pkgs.stdenv.mkDerivation {
          pname = "zigcss";
          inherit version;
          src = source;

          strictDeps = true;
          nativeBuildInputs = [
            zig
            pkgs.coreutils
          ];

          dontConfigure = true;
          dontBuild = true;
          dontUseZigConfigure = true;
          dontUseZigBuild = true;
          dontUseZigCheck = true;
          dontUseZigInstall = true;
          dontSetZigDefaultFlags = true;

          installPhase = ''
            runHook preInstall

            zig build \
              --cache-dir "$TMPDIR/zig-cache" \
              --global-cache-dir "$TMPDIR/zig-global-cache" \
              -Dcpu=baseline \
              -Doptimize=ReleaseFast \
              --prefix "$out"

            test -x "$out/bin/zigcss"
            runHook postInstall
          '';

          doInstallCheck = true;
          installCheckPhase = ''
            runHook preInstallCheck

            check_dir="$TMPDIR/zigcss-install-check"
            mkdir -p "$check_dir"

            version_output="$(timeout --kill-after=2s 20s "$out/bin/zigcss" --version)"
            test "$version_output" = "zigcss ${version}"

            printf '%s\n' '.card { color: red; }' > "$check_dir/input.css"
            test "$(wc -c < "$check_dir/input.css")" -le 128
            timeout --kill-after=2s 20s \
              "$out/bin/zigcss" --syntax css "$check_dir/input.css" \
              --output "$check_dir/output.css" --minify
            test -f "$check_dir/output.css"
            test "$(wc -c < "$check_dir/output.css")" -le 128
            test "$(tr -d '\r\n' < "$check_dir/output.css")" = '.card{color:red}'

            printf '%s\n' '$color: red;' > "$check_dir/_tokens.scss"
            printf '%s\n' '@use "tokens"; .card { color: tokens.$color; }' > "$check_dir/input.scss"
            test "$(wc -c < "$check_dir/_tokens.scss")" -le 128
            test "$(wc -c < "$check_dir/input.scss")" -le 128
            timeout --kill-after=2s 20s \
              "$out/bin/zigcss" --syntax scss "$check_dir/input.scss" \
              --output "$check_dir/output-scss.css" --minify
            test -f "$check_dir/output-scss.css"
            test "$(wc -c < "$check_dir/output-scss.css")" -le 128
            test "$(tr -d '\r\n' < "$check_dir/output-scss.css")" = '.card{color:red}'

            runHook postInstallCheck
          '';

          meta = {
            description = "Self-contained native stylesheet compiler";
            homepage = "https://github.com/vyakymenko/zigcss";
            license = lib.licenses.mit;
            mainProgram = "zigcss";
            platforms = systems;
          };
        };
    in
    {
      packages = forAllSystems (system: {
        default = mkPackage system;
      });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/zigcss";
          meta.description = "Run the repository-local ZigCSS source build";
        };
      });

      checks = forAllSystems (system: {
        package = self.packages.${system}.default;
      });
    };
}
