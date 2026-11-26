#!/usr/bin/env bash
# CNCLI summary entrypoint. Functions only.

cntools_action_main() {
  cntools_blocks_action Summary
}

cntools_action_cleanup() { cntools_blocklog_cleanup; }
