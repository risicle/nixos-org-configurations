self: super:
{
  nixUnstable = super.nixUnstable.overrideAttrs (oldatrs: {
    name = "nix-2.2pre6526_9f99d624";
    src = self.fetchFromGitHub {
      owner = "NixOS";
      repo = "nix";
      rev = "9f99d62480cf7c58c0a110b180f2096b7d25adab";
      sha256 = "0fkmx7gmgg0yij9kw52fkyvib88hj1jsj90vbpy13ccfwknh1044";
    };
  });
}
