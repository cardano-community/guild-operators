#!/usr/bin/env bash
# CNCLI epoch entrypoint. Functions only.

cntools_action_main() {
  cntools_blocks_action Epoch
}

cntools_action_cleanup() { cntools_blocklog_cleanup; }
