#!/usr/bin/env bash
# Catalyst stake authorization and live/offline funding workflows.

cntools_action_main() {
  cntools_catalyst_action_registration
}

cntools_action_cleanup() { cntools_catalyst_cleanup; }
