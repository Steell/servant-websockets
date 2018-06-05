let
  pkgs = import <nixpkgs> {};
in
{
  callCabal2nix
    ? pkgs.haskellPackages.callCabal2nix
}:

callCabal2nix "servant-websockets" ./. { }
