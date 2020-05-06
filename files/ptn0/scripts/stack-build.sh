#!/bin/sh

# executes stack build and copies binaries to ~/.cabal/bin folder.

stack build --test --no-run-tests --copy-bins --local-bin-path ~/.cabal/bin  2>&1 | tee /tmp/build.log
