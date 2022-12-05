{
  description = "my personal zmk config";

  inputs = {
    nixpkgs.url = "nixpkgs/nixpkgs-unstable";
    utils.url = "github:numtide/flake-utils";
  };

  outputs = { nixpkgs, utils, ... }: utils.lib.eachDefaultSystem (system:
    with import nixpkgs
      {
        overlays = [
          (final: prev: {
            zephyr-sdk = final.stdenv.mkDerivation rec {
              pname = "zephyr-sdk";
              version = "0.13.2";
              nativeBuildInputs = [
                final.python38
                final.autoPatchelfHook
                final.which
              ];
              src = builtins.fetchurl {
                url = "https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v${version}/zephyr-sdk-${version}-linux-x86_64-setup.run";
                sha256 = "M03Tv7PKaWWbOBriASohiKQUpsht7HXj7sOwsz4RrB4=";
              };
              dontUnpack = true;
              installPhase = ''
                # extract outer self-extracting archive
                cp $src $TEMP/installer.run
                chmod +x $TEMP/installer.run
                $TEMP/installer.run --noexec --target $TEMP/outer

                # run the setup tool
                cd $TEMP/outer
                bash ./setup.sh -d $out -y -norc -nocmake
              '';
            };
          })
        ];
        inherit system;
      };
    rec {
      packages.default = stdenv.mkDerivation {
        name = "zmk configuration";
        src = ./.;
        nativeBuildInputs = [
          cmake
          git
          ninja
          zephyr-sdk
        ] ++ (with python3Packages; [
          west
          pyelftools
        ]);
        dontConfigure = false;
        CCACHE_DISABLE = 1;
        configurePhase =
          let
            moduleCopyCmds = builtins.map
              (module:
                let
                  source = fetchFromGitHub {
                    owner = module.owner or "zephyrproject-rtos";
                    inherit (module) repo rev sha256;
                  };
                in
                "mkdir -p $(dirname ${module.path}) && cp --no-preserve=mode -r ${source} ${module.path}"
                + nixpkgs.lib.optionalString (module.createDotGit or false) ''

                  # west requires a .git dir for some modules
                  git -C ${module.path} init
                  git -C ${module.path} config user.email "nix-builder@example.com"
                  git -C ${module.path} config user.name "Nix Builder"
                  git -C ${module.path} add -A
                  git -C ${module.path} commit -m "nix-build"
                  git -C ${module.path} checkout -b manifest-rev
                  git -C ${module.path} checkout --detach manifest-rev
                ''
              )
              (import ./nix/west-modules.nix);
          in
            ''
            mkdir -p .west
            cat >.west/config <<EOF
            [manifest]
            path = config
            file = west.yml

            [zephyr]
            base = zephyr
            EOF

            ${builtins.concatStringsSep "\n" moduleCopyCmds}
            '';
        buildPhase =
          let
            keyboards = builtins.map
              (keyboard:
                ''
                west build -s zmk/app -b ${keyboard.board} -p -- -DZMK_CONFIG="$PWD/config" -DSHIELD=${keyboard.shield}
                mv build/zephyr/zmk.uf2 out/${keyboard.shield}.uf2
                cat > out/bin/install-${keyboard.shield}<<EOF
                mount -U "${keyboard.diskUUID}" ${keyboard.mountPoint}
                cp $out/${keyboard.shield}.uf2 ${keyboard.mountPoint}
                EOF
                chmod +x out/bin/install-${keyboard.shield}
                ''
              )
              (import ./build.nix);
          in
          ''
            mkdir -p out/bin

            export Zephyr_DIR=$PWD/zephyr/share/zephyr-package/cmake

            ${builtins.concatStringsSep "\n" keyboards}
          '';
        installPhase = "cp -r out $out";
      };

      devShells.default = mkShell {
        inherit (packages.default) nativeBuildInputs;
      };
    });
}
