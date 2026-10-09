#!/usr/bin/env bash
# Backup wizard choices, cancellation and passphrase policy, without a node.
# shellcheck disable=SC1090,SC2034,SC2317,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${REPO_ROOT}/files/tests/fixtures/cntools-shared-libraries.sh"
. "${REPO_ROOT}/scripts/common-helper-scripts/cntools/lib/backup-ui.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "$1 != $2"; }
cntools_log() { :; }
cntools_ui_action_begin() { :; }
cntools_ui_render_status() { :; }
cntools_ui_wait() { :; }
cntools_backup_directory_safe() { return 0; }
cntools_backup_recovery_coverage() { CNTOOLS_BACKUP_COVERAGE_LABELS=(); CNTOOLS_BACKUP_COVERAGE_VALUES=(); }
cntools_ui_spin_function() { shift; "$@"; }
cntools_table_pair() { printf '%s %s\n' "$1" "$2"; }
cntools_table_render() { while IFS= read -r row; do : "${row}"; done; }
cntools_backup_result() { eq "$1" "${expected_operation}"; eq "$2" 0; }
CNTOOLS_NODE_HOME=/nonexistent-deployment CNTOOLS_NETWORK=preview

(
  words=(short 'enough characters' mismatch 'enough characters' 'enough characters') position=0
  cntools_ui_password() { printf -v "$1" '%s' "${words[position]}"; position=$((position+1)); }
  secret=''
  cntools_backup_password_into secret encrypt
  eq "${secret}" 'enough characters'; eq "${position}" 5
)
(
  cntools_ui_password() { printf -v "$1" '%s' old; }
  secret=''
  cntools_backup_password_into secret decrypt; eq "${secret}" old
)
(
  cntools_ui_password() { return 1; }
  status=0; cntools_backup_password_into secret encrypt || status=$?
  eq "${status}" 1
)

for scenario in encrypted public plain cancel-contents cancel-protection decline-plain cancel-path decline-confirm cancel-password; do
  (
    expected_operation=Create; choices=0 confirms=0 creates=0
    cntools_ui_choose() {
      choices=$((choices+1))
      if (( choices == 1 )); then
        case "${scenario}" in public) printf -v "$1" '%s' 'Public artifacts only' ;; cancel-contents) printf -v "$1" '%s' Cancel ;; *) printf -v "$1" '%s' 'Full backup (includes private keys)' ;; esac
      else
        case "${scenario}" in plain|decline-plain) printf -v "$1" '%s' 'Unencrypted archive' ;; cancel-protection) printf -v "$1" '%s' Cancel ;; *) printf -v "$1" '%s' 'Encrypt with GPG (recommended)' ;; esac
      fi
    }
    cntools_ui_input() { [[ "${scenario}" != cancel-path ]] || return 1; printf -v "$1" '%s' /existing-private-directory; }
    cntools_ui_confirm() {
      eq "$2" false
      confirms=$((confirms+1))
      [[ "${scenario}" != decline-confirm && "${scenario}" != decline-plain ]]
    }
    cntools_backup_password_into() { [[ "${scenario}" != cancel-password ]] || return 1; printf -v "$1" '%s' 'enough characters'; }
    cntools_backup_create() {
      eq "$1" /existing-private-directory
      creates=$((creates+1))
      case "${scenario}" in
        public) eq "$2" public; eq "$3" encrypted ;;
        plain) eq "$2" full; eq "$3" plain; eq "$4" '' ;;
        encrypted) eq "$2" full; eq "$3" encrypted; eq "$4" 'enough characters' ;;
        *) fail 'creation after cancellation' ;;
      esac
    }
    status=0; cntools_backup_action_create || status=$?
    case "${scenario}" in encrypted|public|plain) eq "${creates}" 1; eq "${status}" 0 ;; *) eq "${creates}" 0; eq "${status}" 0 ;; esac
    [[ "${scenario}" != plain ]] || eq "${confirms}" 2
  )
done
for scenario in plain encrypted declined cancel-file cancel-password; do
  (
    expected_operation=Restore; prepares=0 imports=0
    CNTOOLS_BACKUP_KIND=full CNTOOLS_BACKUP_NETWORK=preview
    cntools_ui_input() {
      [[ "${scenario}" != cancel-file ]] || return 1
      if [[ "${scenario}" == encrypted || "${scenario}" == cancel-password ]]; then printf -v "$1" '%s' /backup.tar.gz.gpg; else printf -v "$1" '%s' /backup.tar.gz; fi
    }
    cntools_backup_password_into() { [[ "${scenario}" != cancel-password ]] || return 1; printf -v "$1" '%s' old; }
    cntools_backup_restore_prepare() { prepares=$((prepares+1)); [[ "${scenario}" != encrypted ]] || eq "$2" old; }
    cntools_backup_restore_preview() { eq "${prepares}" 1; }
    cntools_ui_confirm() { eq "$2" false; [[ "${scenario}" != declined ]]; }
    cntools_backup_restore_apply() { imports=$((imports+1)); }
    status=0; cntools_backup_action_restore || status=$?
    case "${scenario}" in plain|encrypted) eq "${imports}" 1; eq "${status}" 0 ;; declined) eq "${prepares}" 1; eq "${imports}" 0; eq "${status}" 0 ;; *) eq "${prepares}" 0; eq "${imports}" 0; eq "${status}" 0 ;; esac
  )
done
printf 'CNTools backup wizard tests passed\n'
