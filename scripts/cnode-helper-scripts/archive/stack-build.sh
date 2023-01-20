#!/usr/bin/env bash

# Install stack if not installed on system
if ! command -v stack >/dev/null; then
  curl -sSL https://get.haskellstack.org/ | sh
fi

# executes stack build and copies binaries to ~/.local/bin folder.
stack build --test --no-run-tests --copy-bins --local-bin-path ~/.local/bin  2>&1 | tee /tmp/build.log
