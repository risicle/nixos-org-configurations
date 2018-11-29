self: super:
let
  upgrade = package: overrides:
    let
      upgraded = package.overrideAttrs overrides;
      upgradedVersion = (builtins.parseDrvName upgraded.name).version;
      originalVersion =(builtins.parseDrvName package.name).version;

      isDowngrade = (builtins.compareVersions upgradedVersion originalVersion) == -1;

      warn = builtins.trace
        "Warning: ${package.name} downgraded by overlay with ${upgraded.name}.";
      pass = x: x;
    in (if isDowngrade then warn else pass) upgraded;
in {
  nixUnstable = upgrade super.nixUnstable (oldAttrs: {
    name = "nix-2.2pre6526_9f99d624";
    src = self.fetchFromGitHub {
      owner = "NixOS";
      repo = "nix";
      rev = "9f99d62480cf7c58c0a110b180f2096b7d25adab";
      sha256 = "0fkmx7gmgg0yij9kw52fkyvib88hj1jsj90vbpy13ccfwknh1044";
    };
  });
}
