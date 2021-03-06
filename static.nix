{ system ? builtins.currentSystem }:

let
  rp = import (builtins.fetchTarball {
    url = "https://github.com/vaibhavsagar/reflex-platform/archive/ae542c3e7ed4fb1b4552f447b1205982e261cd68.tar.gz";
    sha256 = "0p14b4kdjkykkcql8xdp2x8qvw7cla8imikl940a8qcsc49vkwpf";
  }) { inherit system; };
  pact-src = builtins.filterSource
    (path: type: !(builtins.elem (baseNameOf path)
        ["result" "dist" "dist-ghcjs" ".git" ".stack-work"]))
    ./.;
in (rp.ghcMusl64.override {
  overrides = self: super:
    let guardGhcjs = p: if self.ghc.isGhcjs or false then null else p;
      in with rp.nixpkgs.haskell.lib; {
        clock = overrideCabal super.clock (drv: {
          postPatch = ''
            substituteInPlace System/Clock.hsc --replace '#let alignment t = "%lu", (unsigned long)offsetof(struct {char x__; t (y__); }, y__)' ""
          '';
        });
        generics-sop = dontHaddock super.generics-sop;
        math-functions = dontCheck (dontHaddock (self.callHackage "math-functions" "0.3.1.0" {}));
        optparse-applicative = dontHaddock super.optparse-applicative;
        scientific = dontCheck super.scientific;
        servant-client = dontCheck super.servant-client;
        wai-app-static = dontHaddock super.wai-app-static;
        cryptonite = dontCheck super.cryptonite;
        parsers = dontHaddock super.parsers;
        statistics = dontHaddock super.statistics;

          # tests for extra were failing due to an import clash (`isWindows`)
          extra = rp.nixpkgs.haskell.lib.dontCheck super.extra;
          # these want to use doctest, which doesn't work on ghcjs
          bytes = rp.nixpkgs.haskell.lib.dontCheck super.bytes;
          intervals = rp.nixpkgs.haskell.lib.dontCheck super.intervals;
          bound = rp.nixpkgs.haskell.lib.dontCheck super.bound;
          trifecta = dontHaddock (dontCheck (self.callCabal2nix "trifecta" (rp.nixpkgs.fetchFromGitHub {
            owner = "vaibhavsagar";
            repo = "trifecta";
            rev = "8b8630eb66740683a3502bf52a12cb6084b3979a";
            sha256 = "1kb0dnzs0q5ahn4xp2w1fb05v4jahr6rm5c1l4f3nbylsh0gf7ar";
          }) {}));
          lens-aeson = rp.nixpkgs.haskell.lib.dontCheck super.lens-aeson;
          # test suite for this is failing on ghcjs:
          hw-hspec-hedgehog = rp.nixpkgs.haskell.lib.dontCheck super.hw-hspec-hedgehog;

          algebraic-graphs = rp.nixpkgs.haskell.lib.dontCheck super.algebraic-graphs;

          # Needed to get around a requirement on `hspec-discover`.
          megaparsec = rp.nixpkgs.haskell.lib.dontCheck super.megaparsec;

          hedgehog = self.callCabal2nix "hedgehog" (rp.nixpkgs.fetchFromGitHub {
            owner = "hedgehogqa";
            repo = "haskell-hedgehog";
            rev = "38146de29c97c867cff52fb36367ff9a65306d76";
            sha256 = "1z8d3hqrgld1z1fvjd0czksga9lma83caa2fycw0a5gfbs8sh4zh";
          } + "/hedgehog") {};
          hlint = self.callHackage "hlint" "2.0.14" {};
          # hoogle = self.callHackage "hoogle" "5.0.15" {};

          # sbv 8.1
          sbv = dontHaddock (dontCheck (self.callCabal2nix "sbv" (rp.nixpkgs.fetchFromGitHub {
            owner = "LeventErkok";
            repo = "sbv";
            rev = "365b1a369a2550d6284608df3fbc17e2663c4d3c";
            sha256 = "134f148g28dg7b3c1rvkh85pfl9pdlvrvl6al4vlz72f3y5mb2xg";
          }) {}));

          # Our own custom fork
          thyme = dontHaddock (dontCheck (self.callCabal2nix "thyme" (rp.nixpkgs.fetchFromGitHub {
            owner = "kadena-io";
            repo = "thyme";
            rev = "6ee9fcb026ebdb49b810802a981d166680d867c9";
            sha256 = "09fcf896bs6i71qhj5w6qbwllkv3gywnn5wfsdrcm0w1y6h8i88f";
          }) {}));

          # aeson 1.4.2
          aeson = dontHaddock (self.callCabal2nix "aeson" (rp.nixpkgs.fetchFromGitHub {
            owner = "bos";
            repo = "aeson";
            rev = "c3d04181eb64393d449a68084ffea3a94c3d8064";
            sha256 = "1l8lks6plj0naj9ghasmkqglshxym3f29gyybvjvkrkm770p2gl4";
          }) {});
          pact = dontHaddock (dontCheck (self.callCabal2nix "pact" pact-src {}));
        };
}).pact
