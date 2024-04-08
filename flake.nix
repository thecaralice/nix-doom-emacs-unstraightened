{
  inputs = {
    nixpkgs.url = "nixpkgs";
    doomemacs = {
      url = "github:doomemacs/doomemacs";
      flake = false;
    };
    emacs-overlay = {
      url = "github:nix-community/emacs-overlay";
      inputs = {
        nixpkgs-stable.follows = "nixpkgs";
      };
    };
  };

  outputs = { doomemacs, nixpkgs, emacs-overlay, ... }: let
    systems = [ "x86_64-linux" ];
    perSystemPackages = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in {
      packages = perSystemPackages (pkgs:
        let
          common = { doomSource = doomemacs; emacs = pkgs.emacs29-pgtk; };
          commonDemos = common // { doomLocalDir = "~/.local/share/nix-doom-unstraightened"; };
          pkgsWithEmacsOverlay = pkgs.extend emacs-overlay.overlays.package;
        in {
          # Current Doom + NixOS 23.11 requires emacs-overlay: Doom pins
          # emacs-fish-completion, which moved from gitlab to github recently
          # enough stable nixpkgs pulls it from the wrong source.
          doom-minimal = pkgsWithEmacsOverlay.callPackage ./doom.nix (commonDemos // { doomDir = pkgs.emptyDirectory; });
          doom-full = pkgsWithEmacsOverlay.callPackage ./doom.nix (commonDemos // { full = true; doomDir = pkgs.emptyDirectory; });
          doom-example = pkgsWithEmacsOverlay.callPackage ./doom.nix (commonDemos // { doomDir = ./example; });
          doomEmacs = args: pkgsWithEmacsOverlay.callPackage ./doom.nix (common // args);
        });
    };
}
