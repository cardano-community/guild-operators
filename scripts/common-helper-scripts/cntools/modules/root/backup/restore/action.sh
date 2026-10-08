#!/usr/bin/env bash
# Guided no-overwrite backup restore.

cntools_action_main() {
  cntools_backup_action_restore
}

cntools_action_cleanup() {
  cntools_backup_cleanup
}
