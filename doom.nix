{
  /* DOOMDIR / Doom private directory / module. */
  doomDir ? "/var/empty",
  /* Doom source tree. */
  doomSource,
  /* Emacs package to build against. */
  emacs,
  /* Whether to enable all default dependencies. Primarily useful for CI /
     testing. */
  full ? false,
  /* Name of doom profile to use. */
  profileName ? "nix",
  /* Name to give to the main binary (to facilitate parallel installs with Emacs). */
  binaryName ? "emacs",

  callPackages,
  git,
  emacsPackagesFor,
  lib,
  linkFarm,
  runCommand,
  runtimeShell,
  writeText,
  makeBinaryWrapper,
}:
let
  inherit (lib) optional optionalAttrs optionalString;

  doomInitFile = "${doomDir}/init.el";
  doomPrivateModule = "${doomDir}/packages.el";

  # Step 1: determine which Emacs packages to pull in.
  #
  # Inputs: unpatched Doom, a DOOMDIR with the provided init.el and packages.el.
  # Outputs:
  # - Packages Doom normally loads using Straight (as json)
  # - modified packages.el that claims all packages are system-installed
  #
  # Uses Doom's CLI framework, which does not require anything else is installed
  # (not even straight).
  stage1DoomDir = linkFarm "doom-dir-stage1" (
    [{ name = "cli.el"; path = ./cli1.el; }]
    ++ optional (lib.pathExists doomInitFile) { name = "init.el"; path = doomInitFile; }
    ++ optional (lib.pathExists doomPrivateModule) { name = "packages.el"; path = doomPrivateModule; }
  );

  # XXX this may need to be runCommandLocal just in case conditionals an init.el
  # / packages.el evaluate differently on build systems.
  doomIntermediates = runCommand "doom-intermediates"
    {
      env = {
        EMACS = lib.getExe emacs;
        DOOMDIR = stage1DoomDir;
        # Enable this to troubleshoot failures at this step.
        #DEBUG = "1";
      };
      # We set DOOMLOCALDIR somewhere harmless below to stop Doom from trying to
      # create it somewhere read-only.
    } ''
    mkdir $out
    export DOOMLOCALDIR=$(mktemp -d)
    ${runtimeShell} ${doomSource}/bin/doom dump-for-nix-build \
      ${optionalString full "--full"} -o $out
  '';

  doomPackageSet = lib.importJSON "${doomIntermediates}/packages.json";

  # URLs for a few packages used by Doom that have straight recipes but are not
  # in nixpkgs.
  extraUrls = {
    # Straight recipe from el-get
    font-lock-ext = "https://github.com/sensorflo/font-lock-ext.git";
    sln-mode = "https://github.com/sensorflo/sln-mode.git";
    # Straight recipe from emacsmirror-mirror
    nose = "https://github.com/emacsattic/nose.git";
    # In nixpkgs, but uses codeberg, for which nixpkgs uses fetchzip.
    # TODO: consider parsing origEPkg.src.url instead.
    tree-sitter-indent = "https://codeberg.org/FelipeLema/tree-sitter-indent.el.git";
    undo-fu = "https://codeberg.org/ideasman42/emacs-undo-fu.git";
    undo-fu-session = "https://codeberg.org/ideasman42/emacs-undo-fu-session.git";
  };

  # Step 2: override Emacs packages to respect Doom's pins.
  doomEmacsPackages = (emacsPackagesFor emacs).overrideScope (
    eself: esuper:
      let
        customPackages = callPackages ./elisp-packages.nix { inherit emacs esuper eself; };
        # We want to override `version` along with `src` to avoid spurious
        # rebuilds on version bumps in emacs-overlay of packages Doom has
        # pinned.
        #
        # The elisp manual says we need a version `version-to-list` can parse,
        # which means it must start with a number and cannot contain the actual
        # commit ID. We start with a large integer in case package.el starts
        # version-checking dependencies (it currently does not but a comment in
        # the code says it should). Additionally, `(package-version-join
        # (version-to-list v))` must roundtrip to avoid elpa2nix failing with
        # "Package does not untar cleanly".
        snapshotVersion = "9999snapshot";

        makePackage = name: p:
          assert lib.asserts.assertEachOneOf
            "keys for ${name}"
            (lib.attrNames p)
            [ "modules" "recipe" "pin" "type" ];
          assert (p ? type) -> lib.asserts.assertOneOf
            "type of ${name}"
            p.type
            [ "core" ];
          let
            origEPkg = esuper.${name} or null;
            # We have to specialcase ELPA packages pinned by Doom: Straight mirrors /
            # repackages them. Doom's pins assume that mirror is used (so we have to
            # use it), and replacing the source in nixpkgs's derivation will not work
            # (it assumes it gets a tarball as input).

            # TODO: check notmuch works correctly without notmuch-version.el

            isElpa = origEPkg != null && (origEPkg == esuper.elpaPackages.${name} or null || origEPkg == esuper.nongnuPackages.${name} or null);
            epkg =
              customPackages.${name}
                or (if origEPkg == null || (p ? pin && isElpa)
              then
                assert lib.assertMsg
                  (isElpa || (p ? recipe && p ? pin) || extraUrls ? ${name})
                  "${name}: not in epkgs, not elpa, no recipe or not pinned";
                # Assume we can safely ignore (pre-)build unless we're actually
                # building our own package.
                assert lib.assertMsg (!(p ? recipe.pre-build)) "${name}: pre-build not supported";
                assert lib.assertMsg (!(p ? recipe.build)) "${name}: build not supported";
                # TODO: lift "pin" requirement, if that turns out to be
                # necessary or at least desirable. Requires figuring out why
                # melpa2nix requires `commit`. Not a priority because if it's
                # not in epkgs we'd need a recipe passed in, and it's uncommon
                # for Doom to pass in a recipe without pinning.
                #
                # Doom does currently have unpinned packages with an explicit
                # recipe, but they're in epkgs (popon and flymake-popon) so it
                # should be ok. Users might do this to pull in a custom package
                # they don't care about pinning, though: we may want to support
                # that.
                assert lib.assertMsg (p ? pin)
                  "${name}: not in epkgs and not pinned. This is not yet supported.";
                # epkgs.*Build helpers take an attrset, they do not support
                # mkDerivation's fixed-point evaluation (`finalAttrs`).
                # If they did, the buildInputs stuff should use finalAttrs.src.

                # This uses melpaBuild instead of trivialBuild to end up with
                # something package.el understands as satisfying dependencies.
                # This is necessary if we're replacing a pinned ELPA dependency
                # of an unpinned ELPA package.
                esuper.melpaBuild {
                  pname = name;
                  # melpaBuild requires we set `version` and `commit` here
                  # (leaving `version` unset until overrideAttrs below does not
                  # work).
                  version = snapshotVersion;
                  commit = p.pin;
                  meta = {
                    description = "trivial build for doom-emacs";
                  };
                  # Just enough to make melpa2nix work.
                  recipe = writeText "generated-recipe" ''
                    (${name} :fetcher github :repo "marienz/made-up"
                     ${optionalString (p ? recipe.files) ":files ${lib.debug.traceValSeq p.recipe.files}"})'';
                  buildInputs = (map (name: eself.${name}) reqlist);
                }
                else origEPkg);
            url =
              if (p.recipe.host or "") == "github" && p ? recipe.repo
              then "https://github.com/${p.recipe.repo}"
              else epkg.src.gitRepoUrl
                or (if isElpa then "https://github.com/emacs-straight/${name}"
              else extraUrls.${name}
                or (throw "${name}: cannot derive url from recipe ${p.recipe or "<missing>"}"));
            # Use builtins.fetchGit instead of nixpkgs's fetchFromGitHub because
            # fetchGit allows fetching a specific git commit without a hash.
            # TODO: port to fetchTree once (mostly) stable
            # (in particular the github fetcher may be noticably more efficient)
            src = builtins.fetchGit (
              {
                inherit url;
                rev = p.pin;
                submodules = !(p.recipe.nonrecursive or false);
                # TODO: might need to pull ref from derivation.src if we're not pulling it from p.recipe?
                # Note Doom does have packages with pin + branch (or nonrecursive) set,
                # expecting to inherit the rest of the recipe from Straight.
              } // optionalAttrs (p ? recipe.branch) { ref = p.recipe.branch; }
              // optionalAttrs (p ? recipe.depth) { shallow = p.recipe.depth == 1; }
            );
            # Ignore dependency extraction errors because it fails for repos not
            # containing a "proper" package (no -pkg.el, no file with the right magic
            # header). These seem common enough to be not worth allowlisting.
            reqfile = runCommand "${name}-deps" { } ''
              ${lib.getExe emacs} -Q --batch --eval \
                "(progn
                   (require 'package)
                   (with-temp-buffer
                     (setq default-directory \"${src}\")
                     (dired-mode)
                     (let ((reqs (with-demoted-errors \"Extracting dependencies: %s\" (package-desc-reqs (package-dir-info)))))
                       (princ (json-encode (mapcar #'car (seq-remove (lambda (p) (apply #'package-built-in-p p)) reqs)))))))" \
                > $out
            '';
            reqjson = lib.importJSON reqfile;
            # json-encode encodes the empty list as null (nil), not [].
            reqlist = if reqjson == null then [ ] else reqjson;
          in
          if p ? pin
          then epkg.overrideAttrs {
            inherit src;
            version = snapshotVersion;
          }
          else epkg;
      in
      lib.mapAttrs makePackage doomPackageSet
  );

  # Step 3: Build an emacsWithPackages, pulling all packages from step 1 from
  # the set from step 2.
  emacsWithPackages = doomEmacsPackages.emacsWithPackages (epkgs: (map (p: epkgs.${p}) (builtins.attrNames doomPackageSet)));

  # Step 4: build a final DOOMDIR with packages.el from step 1.
  finalDoomDir = runCommand "doom-dir" {} ''
    mkdir $out
    if [[ -e ${doomDir} ]]; then
      ln -s ${doomDir}/* $out/
    fi
    ln -sf ${doomIntermediates}/packages.el $out/
    ln -sf ${./cli2.el} $out/cli.el
  '';

  # Step 5: build a Doom profile and profile loader using Emacs from step 3 and
  # DOOMDIR from step 4.
  #
  # Create both in the same derivation: we want the path to the generated
  # profile in the loader (so building the loader depends on the profile), but
  # I'm currently using the loader to set up Doom to write the profile to the
  # right place (so building the profile depends on the loader).

  # XXX runCommandLocal? (See doomIntermediates.)
  doomProfile = runCommand "doom-profile"
    {
      env = {
        EMACS = lib.getExe emacsWithPackages;
        DOOMDIR = finalDoomDir;
        # Enable this to troubleshoot failures at this step.
        #DEBUG = "1";
      };
      # Required to avoid Doom erroring out at startup.
      nativeBuildInputs = [ git ];
    } ''
    mkdir $out $out/loader $out/profile
    export DOOMPROFILELOADFILE=$out/loader/init.el
    export DOOMLOCALDIR=$(mktemp -d)
    # Prevent error on Emacs shutdown writing empty build cache.
    mkdir $DOOMLOCALDIR/straight

    ${runtimeShell} ${doomSource}/bin/doom build-profile-loader-for-nix-build \
      -n "${profileName}" -p "$out/profile" -d "${finalDoomDir}"

    # With DOOMPROFILE set, doom-state-dir and friends are HOME-relative.
    export HOME=$(mktemp -d)
    export DOOMPROFILE='${profileName}';
    ${runtimeShell} ${doomSource}/bin/doom build-profile-for-nix-build

    # Similar to audit-tmpdir.sh in nixpkgs.
    if grep -q -F "$TMPDIR/" -r $out; then
      echo "Doom profile contains a forbidden reference to $TMPDIR/"
      exit 1
    fi
  '';

  # Step 6: write wrappers to start the whole thing.
  pkg = runCommand "doom" {
    nativeBuildInputs = [ makeBinaryWrapper ];
  }
  ''
  makeWrapper ${emacsWithPackages}/bin/emacs $out/bin/${binaryName} \
    --set DOOMPROFILELOADFILE ${doomProfile}/loader/init.el \
    --add-flags "--init-directory=${doomSource} --profile ${profileName}"
'';

in
pkg