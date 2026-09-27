{
  description = "Just Enough Shell (JES) — WM-agnostic rolling release desktop shell";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable }:
    let
      lib = nixpkgs.lib;
      forAllSystems = lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

      mkJesGoTools = pkgsU:
        let
          tools = pkgsU.buildGoModule {
            pname = "jes-go-tools";
            version = "1.0.0";
            src = ./for-quickshell/go;
            vendorHash = null;
            buildPhase = ''
              runHook preBuild
              go build -o cal ./cmd/cal
              go build -o Cava-internal ./cmd/cava-internal
              go build -o launch ./cmd/launch
              go build -o screenpicker ./cmd/screenpicker
              go build -o music ./cmd/music
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin
              install -Dm755 cal Cava-internal launch screenpicker music -t $out/bin
              runHook postInstall
            '';
          };
          wallpaper-picker = pkgsU.buildGoModule {
            pname = "wallpaper-picker";
            version = "1.0.0";
            src = ./for-quickshell/go/wallpaper;
            vendorHash = null;
          };
        in
        { inherit tools wallpaper-picker; };

      mkJes = pkgsU:
        let
          go = mkJesGoTools pkgsU;
          quickshell = pkgsU.quickshell;
          storeShell = "$out/JES/quickshell";
        in
        pkgsU.stdenvNoCC.mkDerivation {
          pname = "jes";
          version = "0.1.0";
          src = ./.;

          dontConfigure = true;
          dontBuild = true;

          installPhase = ''
            runHook preInstall

            mkdir -p $out/bin \
                     $out/share/jes/quickshell \
                     $out/share/jes/config \
                     $out/share/jes/matugen \
                     $out/share/fonts/truetype \
                     $out/lib/systemd/user \
                     $out/share/bash-completion/completions

            cp -r .local/JES/quickshell/* $out/share/jes/quickshell/
            chmod 755 $out/share/jes/quickshell/scripts/* || true

            for b in cal Cava-internal music; do
              install -Dm755 ${go.tools}/bin/$b \
                $out/share/jes/quickshell/scripts/$b
              ln -s $out/share/jes/quickshell/scripts/$b $out/bin/jes-$b
            done
            install -Dm755 ${go.tools}/bin/launch \
              $out/share/jes/quickshell/launcher/launch
            install -Dm755 ${go.tools}/bin/screenpicker \
              $out/share/jes/quickshell/screenpicker/screenpicker
            for b in wallpaper-picker; do
              install -Dm755 ${go.wallpaper-picker}/bin/$b \
                $out/share/jes/quickshell/wallpaper/$b
              install -Dm755 ${go.wallpaper-picker}/bin/$b \
                $out/share/jes/quickshell/scripts/$b
              ln -s $out/share/jes/quickshell/wallpaper/$b $out/bin/jes-$b
            done

            install -Dm755 .local/bin/jes-cli $out/bin/jes-cli

            ln -sfn share/jes $out/JES

            mkdir -p $out/libexec
            cat > $out/libexec/jes-seed <<EOF
#!/usr/bin/env bash
# первый запуск: конфиг из шаблона + кэш-директории + symlink для QML,
# у которого пока хардкод на ~/.local/JES
if [ ! -d "\$HOME/.config/JES" ]; then
  mkdir -p "\$HOME/.config/JES"
  cp -r "$out/share/jes/config/"* "\$HOME/.config/JES/"
fi
mkdir -p "\$HOME/.cache/JES/walls" "\$HOME/.cache/JES/wall_prevs" \
         "\$HOME/.cache/JES/jes_music_art" "\$HOME/.local/state"
ln -sfn "$out/share/jes" "\$HOME/.local/JES"
EOF
            chmod +x $out/libexec/jes-seed

            cp -r .config/JES/* $out/share/jes/config/
            cp -r .local/JES/matugen/* $out/share/jes/matugen/
            cp .local/share/fonts/ttf/FauxHanamin.ttf \
               $out/share/fonts/truetype/

            cat > $out/lib/systemd/user/jes.service <<EOF
            [Unit]
            Description=Just Enough Shell
            PartOf=graphical-session.target
            After=graphical-session.target
            Requisite=graphical-session.target

            [Service]
            ExecStartPre=$out/libexec/jes-seed
            ExecStart=${quickshell}/bin/qs -c ${storeShell}
            Restart=on-failure
            RestartSec=2

            [Install]
            WantedBy=graphical-session.target
            EOF

            # 7) Динамические автокомплиты: bash + zsh + fish из ./completions/
            #    (диспетчер __complete живёт в самом jes-cli, см. README там же)
            mkdir -p $out/share/zsh/site-functions $out/share/fish/vendor_completions.d
            if [ -d ./completions ]; then
              install -Dm644 completions/jes-cli.bash $out/share/bash-completion/completions/jes-cli
              install -Dm644 completions/_jes-cli   $out/share/zsh/site-functions/_jes-cli
              install -Dm644 completions/jes-cli.fish $out/share/fish/vendor_completions.d/jes-cli.fish
            else
              # фолбэк: статический bash-комплит
              cat << 'EOF' > $out/share/bash-completion/completions/jes-cli
              _jes_cli_completion() {
                  local cur opts
                  COMPREPLY=()
                  cur="''${COMP_WORDS[COMP_CWORD]}"
                  opts="start-daemon reload-daemon stop-daemon wallShader toggleWallPicker wallType togglePlayer toggleCal togglePower toggleLaunch toggleMap toggleJwindow screenpicker getPlugin getLog editConf brightness-up brightness-down brightness-set brightness-get play-pause next prev next-player prev-player initPlugin makePlugin debuildPlugin pluginBuild pluginCache pluginClearCache blacklistAdd blacklistRemove blacklistList blacklistClear --help -h"
                  if [[ ''${COMP_CWORD} -eq 1 ]]; then
                      COMPREPLY=( $(compgen -W "''${opts}" -- "''${cur}") )
                      return 0
                  fi
              }
              complete -F _jes_cli_completion jes-cli
              EOF
            fi

            runHook postInstall
          '';

          meta.mainProgram = "jes-cli";
        };
    in
    {
      packages = forAllSystems (system:
        let
          pkgsU = import nixpkgs-unstable {
            inherit system;
            config.allowUnfree = true;
          };
        in
        rec {
          jes = mkJes pkgsU;
          default = jes;
        });

      nixosModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.programs.jes;
          pkgsU = import nixpkgs-unstable {
            system = pkgs.system;
            config.allowUnfree = true;
          };
          jes = mkJes pkgsU;
        in
        {
          options.programs.jes = {
            enable = lib.mkEnableOption "Just Enough Shell";
            package = lib.mkOption {
              type = lib.types.package;
              default = jes;
            };
            autoStart = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
          };

          config = lib.mkIf cfg.enable {
            hardware.i2c.enable = true;

            services.udev.extraRules = ''
              SUBSYSTEM=="i2c", KERNEL=="i2c-[0-9]*", TAG+="uaccess"
            '';

            fonts.packages = with pkgs; [
              nerd-fonts.mononoki
              cfg.package
            ];

            environment.systemPackages = [ cfg.package ] ++ (with pkgs; [
              jq playerctl ddcutil brightnessctl pamixer i2c-tools
              cava libnotify inotify-tools dbus pciutils ffmpeg
              cliphist wl-clipboard slurp grim taplo python314 zip unzip
              foot lxqt.pavucontrol-qt blueman kdePackages.kdeconnect-kde
              tela-icon-theme micro
            ]) ++ (with pkgsU; [ matugen ]);

            systemd.user.services.jes = lib.mkIf cfg.autoStart {
              description = "Just Enough Shell";
              wantedBy = [ "graphical-session.target" ];
              partOf = [ "graphical-session.target" ];
              after = [ "graphical-session.target" ];
              serviceConfig = {
                ExecStartPre = "${cfg.package}/libexec/jes-seed";
                ExecStart = "${pkgsU.quickshell}/bin/qs -c ${cfg.package}/JES/quickshell";
                Restart = "on-failure";
                RestartSec = 2;
              };
            };

          };
        };
    };
}
