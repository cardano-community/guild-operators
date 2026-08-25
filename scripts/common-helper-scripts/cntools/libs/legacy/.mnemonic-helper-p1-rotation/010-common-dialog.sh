# Command     : logln [log level] [message]
# Description : write message to log file with log level specified
logln() {
  local log_level=$1
  shift
  [[ -z $1 ]] && return
  echo -e "$@" | while read -r log_line; do
    log_line=$(sed -E 's/\x1b(\[[0-9;]*[a-zA-Z]|[0-9])//g' <<< ${log_line##*( )})
    [[ -z ${log_line} ]] && continue
    printf '%s %-8s %s\n' "$(date "+%F %T %Z")" "[${log_level}]" "${log_line}" >> "${CNTOOLS_LOG}"
  done
}

# Command     : println [log level] [newline] [message]
# Description : print and log(if enabled) message
# Parameters  : log level  >  log level (default: INFO)
#                             OFF    : logging disabled, output only to tty
#                             LOG    : logged as DEBUG but not printed to tty
#                             DEBUG  : verbose output, logged and printed to tty
#                             INFO   : normal output printed to tty and logged
#                             ACTION : e.g cardano-cli executions etc, logged but not printed to tty
#                             ERROR  : stderr output and error messages
#             : newline    >  Add a newline at the end for tty output (default true)
#             : message    >  The message to print/log
println() {
  local log_level=$1
  shift
  local newline="\n"
  if [[ $1 = false && $# -gt 2 ]]; then unset newline; shift; elif [[ $1 = true && $# -gt 2 ]]; then shift; fi
  local msg_list=()
  for msg in "$@"; do
    [[ -z ${msg} ]] && continue
    msg_list+=( "${msg}" )
  done
  case $log_level in
    OFF) printf "%b${newline}" "${msg_list[@]}" ;;
    LOG) logln "DEBUG" "${msg_list[@]}" ;;
    DEBUG) printf "%b${newline}" "${msg_list[@]}"; logln "DEBUG" "${msg_list[@]}" ;;
    INFO) printf "%b${newline}" "${msg_list[@]}"; logln "INFO" "${msg_list[@]}" ;;
    ACTION) logln "ACTION" "${msg_list[@]}" ;;
    ERROR) printf "%b${newline}" "${msg_list[@]}"; logln "ERROR" "${msg_list[@]}" ;;
    *) println INFO "${log_level}" "${msg_list[@]}" ;;
  esac
}

# Command     : getAnswerAnyCust [variable name] [log] [question]
# Description : wrapper function for getAnswerAny() in env to read input from stdin
#               and save response into provided variable name while also logging response
# Parameters  : variable name  >  the name of the variable to save users response into
#             : log            >  [true|false] log question (default: true)
#             : question       >  what to ask user to input
getAnswerAnyCust() {
  var_name=$1
  shift
  local log_question=true
  if [[ $1 =~ true|false ]]; then
    [[ $1 = false ]] && log_question=false
    shift
  fi
  getAnswerAny "${var_name}" "$*"
  [[ ${log_question} = true ]] && println LOG "$*: ${!var_name}"
}

# Command     : archiveLog
# Description : archive old log file and clean archive folder keeping last 10 log files
archiveLog() {
  [[ -z ${CNTOOLS_LOG} ]] && return
  log_archive="$(dirname "${CNTOOLS_LOG}")/archive"
  log_file="$(basename "${CNTOOLS_LOG}")"
  mkdir -p "${log_archive}"
  [[ -f ${CNTOOLS_LOG} ]] && mv -f "${CNTOOLS_LOG}" "${log_archive}/${log_file}_$(date +%s)"
  find "${log_archive}" -maxdepth 1 -type f -name "${log_file}*" -printf '%Ts\t%p\n' | sort -n | head -n -10 | cut -f 2- | xargs rm -rf
}

# Command     : protectionPreRequisites
# Description : Check if needed protection prerequisites is available, else print error
protectionPreRequisites() {
  ! cmdAvailable "gpg" && return 1

  if ! cmdAvailable "chattr" &>/dev/null; then
    [[ ${ENABLE_CHATTR} = true ]] && echo -e "chattr command not available but enabled in config, please install or disable in cntools.sh and re-run CNTools" && return 1
  elif [[ ${ENABLE_CHATTR} = true ]]; then # chattr available and enabled, make sure sudo access to chattr is enabled
    touch "${TMP_DIR}"/test
    echo -e "Testing chattr access permission, enter user password if requested..."
    if ! sudo chattr -i "${TMP_DIR}"/test; then
      rm -f "${TMP_DIR}"/test
      echo -e "\n${FG_YELLOW}WARN${NC}: Elevated privileges needed for chattr command used to write protect wallet and pool keys"
      echo -e "Add required sudo permissions or run the following command to add passwordless sudo access to chattr command for '$(whoami)' user"
      echo -e "echo \"$(whoami) ALL=NOPASSWD: $(command -v chattr)\" | sudo tee /etc/sudoers.d/cntools"
      return 1
    fi
    rm -f "${TMP_DIR}"/test
  fi
  return 0
}

# Command     : download_catalyst_toolbox
# Description : Downloads Catalyst Toolbox
download_catalyst_toolbox() {
  local ARCH; ARCH=$(uname -a)
  local manifest="${NODE_HOME:-${CNODE_HOME:-}}/files/cnode-release.json"
  local release_data version filename url expected_sha actual_sha
  local temporary_dir staged_binary catalyst_toolbox_version installed_binary
  if [[ ${ARCH,,} != *x86_64*linux* ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: Only x86_64 architecture on Linux supported, please manually build for your system from:\nhttps://github.com/cardano-foundation/catalyst-core"
    waitToProceed
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1 ||
     ! command -v sha256sum >/dev/null 2>&1 ||
     [[ ! -f "${manifest}" || -L "${manifest}" || ! -s "${manifest}" ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: Valid cnode release metadata and checksum tools are required to install Catalyst Toolbox."
    waitToProceed
    return 1
  fi
  release_data="$(
    jq -er '
      select(
        .schemaVersion == 1 and
        .implementation == "cnode" and
        (.tools["catalyst-toolbox"].version |
          type == "string" and length > 0) and
        (.tools["catalyst-toolbox"].artifacts["linux-x86_64"].url |
          type == "string" and startswith("https://")) and
        (.tools["catalyst-toolbox"].artifacts["linux-x86_64"].sha256 |
          type == "string" and test("^[0-9a-f]{64}$"))
      ) |
      [
        .tools["catalyst-toolbox"].version,
        .tools["catalyst-toolbox"].artifacts["linux-x86_64"].url,
        .tools["catalyst-toolbox"].artifacts["linux-x86_64"].sha256
      ] | @tsv
    ' "${manifest}"
  )" || {
    println ERROR "\n${FG_RED}ERROR${NC}: Invalid Catalyst Toolbox release metadata in ${manifest}."
    waitToProceed
    return 1
  }
  IFS=$'\t' read -r version url expected_sha <<< "${release_data}"
  filename="catalyst-toolbox"
  installed_binary="$(command -v catalyst-toolbox 2>/dev/null || true)"
  if [[ -n "${installed_binary}" &&
     -f "${installed_binary}" &&
     ! -L "${installed_binary}" ]]; then
    actual_sha="$(sha256sum "${installed_binary}" 2>/dev/null | awk '{print $1}')"
    catalyst_toolbox_version="$(
      "${installed_binary}" --full-version 2>/dev/null || true
    )"
    if [[ "${actual_sha,,}" == "${expected_sha}" &&
       "${catalyst_toolbox_version}" == "catalyst-toolbox ${version} "* ]]; then
      return 0
    fi
    println DEBUG "Replacing Catalyst Toolbox that does not match the pinned cnode release policy."
  fi
  println DEBUG "Downloading prerequisite tool: catalyst-toolbox"
  temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/catalyst-toolbox.XXXXXX")" || return 1
  staged_binary="${temporary_dir}/${filename}"
  if ! curl -sSfL -m "${CURL_TIMEOUT}" -o "${staged_binary}" "${url}"; then
    rm -rf -- "${temporary_dir}"
    println ERROR "\n${FG_RED}ERROR${NC}: Download of Catalyst Toolbox ${version} failed! Please retry or build it manually from:\nhttps://github.com/cardano-foundation/catalyst-core"
    waitToProceed
    return 1
  fi
  actual_sha="$(sha256sum "${staged_binary}" | awk '{print $1}')" || {
    rm -rf -- "${temporary_dir}"
    return 1
  }
  if [[ "${actual_sha,,}" != "${expected_sha}" ]]; then
    rm -rf -- "${temporary_dir}"
    println ERROR "\n${FG_RED}ERROR${NC}: Catalyst Toolbox ${version} failed SHA-256 verification."
    waitToProceed
    return 1
  fi
  chmod 0755 "${staged_binary}" || {
    rm -rf -- "${temporary_dir}"
    return 1
  }
  catalyst_toolbox_version="$("${staged_binary}" --full-version 2>/dev/null)" || {
    rm -rf -- "${temporary_dir}"
    println ERROR "\n${FG_RED}ERROR${NC}: Verified Catalyst Toolbox could not report its version."
    waitToProceed
    return 1
  }
  if [[ "${catalyst_toolbox_version}" != "catalyst-toolbox ${version} "* ]]; then
    rm -rf -- "${temporary_dir}"
    println ERROR "\n${FG_RED}ERROR${NC}: Catalyst Toolbox binary version does not match pinned release ${version}."
    waitToProceed
    return 1
  fi
  mkdir -p "${HOME}/.local/bin" || {
    rm -rf -- "${temporary_dir}"
    return 1
  }
  if ! install -m 0755 "${staged_binary}" "${HOME}/.local/bin/catalyst-toolbox"; then
    rm -rf -- "${temporary_dir}"
    return 1
  fi
  rm -rf -- "${temporary_dir}"
  println DEBUG "  ${catalyst_toolbox_version%% - *} ${FG_GREEN}installed!${NC}"
  return 0
}

# Command     : generateCatalystBech32 [wallet name]
# Description : create and store Catalyst signing key in bech32 format (ed25519extended)
# Parameters  : wallet name  >  the name of the wallet
generateCatalystBech32() {
  catalyst_sk_file="${WALLET_FOLDER}/${1}/${WALLET_CATALYST_SK_FILENAME}"
  catalyst_sk_file_bech32="${catalyst_sk_file}-bech32"
  [[ -f "${catalyst_sk_file_bech32}" ]] && return 0
  println ACTION "jq -r .cborHex ${catalyst_sk_file} | cut -c 5-132 | bech32 ed25519e_sk"
  if ! stdout=$(jq -r .cborHex "${catalyst_sk_file}" | cut -c 5-132 | bech32 "ed25519e_sk" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during catalyst signing key bech32 conversion!\n${stdout}"; waitToProceed && return 1
  fi
  echo ${stdout} > "${catalyst_sk_file_bech32}"
}

# Command     : safeDel [path]
# Description : unlock and delete file|dir
# Parameters  : command  >  The command to check
safeDel() {
  path=$1
  [[ ${ENABLE_CHATTR} = true && -f "${path}" && $(lsattr -R "${path}") =~ -i- ]] && sudo chattr -i "${path}"
  if rm -rf "${path}"; then
    println "Deleted: ${path}"
  else
    println ERROR "${FG_RED}ERROR${NC}: delete failed for ${path}"
    return 1
  fi
  return 0
}

updateProtocolParams() {
  _epoch_=$(getEpoch)
  [[ -n ${current_epoch} && ${current_epoch} -eq ${_epoch_} ]] && return
  current_epoch=${_epoch_}
  getProtocolParams
  case $? in
    1) myExit 1 "${FG_YELLOW}WARN${NC}: node socket path wrongly configured or node not running, please verify that socket set in env file match what is used to run the node\n\n${launch_modes_info}" ;;
    2) myExit 1 "${FG_YELLOW}WARN${NC}: failed to query protocol parameters, ensure your node is running with correct genesis (the node needs to be in sync to 1 epoch after the hardfork)\n\nError message: ${PROT_PARAMS}\n\n${launch_modes_info}" ;;
    3) myExit 1 "${FG_YELLOW}WARN${NC}: Unable to query Koios for current epoch parameters\n\n${launch_modes_info}" ;;
  esac
  echo "${PROT_PARAMS}" > "${TMP_DIR}"/protparams.json
}

# Command     : dialogSetup
# Description : set config parameters for dialog formatting
dialogSetup() {
  export DIALOGRC="${TMP_DIR}"/.dialogrc
  [[ ! -f ${DIALOGRC} ]] && cat <<-EOF > "${TMP_DIR}"/.dialogrc
		# Types of values:
		#
		# Number     -  <number>
		# String     -  "string"
		# Boolean    -  <ON|OFF>
		# Attribute  -  (foreground,background,highlight?)
		# Set aspect-ration.
		aspect = 0
		# Set separator (for multiple widgets output).
		separate_widget = ""
		# Set tab-length (for textbox tab-conversion).
		tab_len = 0
		# Make tab-traversal for checklist, etc., include the list.
		visit_items = OFF
		# Shadow dialog boxes? This also turns on color.
		use_shadow = OFF
		# Turn color support ON or OFF
		use_colors = OFF
		# Screen color
		screen_color = (BLACK,BLACK,OFF)
		# Shadow color
		shadow_color = (BLACK,BLACK,ON)
		# Dialog box color
		dialog_color = (BLACK,BLACK,OFF)
		# Dialog box title color
		title_color = (RED,BLACK,ON)
		# Dialog box border color
		border_color = (BLACK,BLACK,OFF)
		# Active button color
		button_active_color = (WHITE,BLACK,ON)
		# Inactive button color
		button_inactive_color = (BLACK,WHITE,OFF)
		# Active button key color
		button_key_active_color = button_active_color
		# Inactive button key color
		button_key_inactive_color = (RED,BLACK,OFF)
		# Active button label color
		button_label_active_color = (YELLOW,BLACK,OFF)
		# Inactive button label color
		button_label_inactive_color = (BLACK,WHITE,ON)
		# Input box color
		inputbox_color = button_inactive_color
		# Input box border color
		inputbox_border_color = button_inactive_color
		# Item color
		item_color = button_inactive_color
		# Selected item color
		item_selected_color = button_active_color
		# Dialog box border2 color
		border2_color = button_inactive_color
		# Input box border2 color
		inputbox_border2_color = button_inactive_color
		EOF
}

# Command     : fileDialog [title] [optional: start path]
# Description : open a file dialog
# Parameters  : show help  >  [0=no|1=yes] print dialog help text
#             : title      >  The dialog title text
#             : verbosity  >  [optional] Start path when dialog is opened, either dir or file (default: ${TMP_DIR}/)
fileDialog() {
  if [[ ${ENABLE_DIALOG} = "false" ]]; then
    getAnswerAnyCust file "$1" && return
  else
    println DEBUG "${1}: "
    waitToProceed "Press any key to open the file explorer [cancel to skip!]"
  fi
  dialogSetup
  [[ -n $2 ]] && start_path="$2" || start_path="${TMP_DIR}/"
  dialog --clear --keep-tite --title "$1" --fselect "${start_path}" $(($(tput lines)-14)) $(($(tput cols)-10)) 2>"${TMP_DIR}/dialog.out"
  file=$([[ -f "${TMP_DIR}/dialog.out" ]] && cat "${TMP_DIR}/dialog.out" || echo "")
  tput cup $(( ${ROW#*[} -1 )) $(( COL -1 ))
  println DEBUG "${FG_LGRAY}${file}${NC}"
}
# Command     : dirDialog [title] [optional: start dir]
# Description : open a directory dialog
# Parameters  : show help  >  [0=no|1=yes] print dialog help text
#             : title      >  The dialog title text
#             : verbosity  >  [optional] Start path when dialog is opened, either dir or file (default: ${TMP_DIR}/)
dirDialog() {
  if [[ ${ENABLE_DIALOG} = "false" ]]; then
    getAnswerAnyCust dir "$1" && return
  else
    println DEBUG "${1}: "
    waitToProceed "Press any key to open the file explorer [cancel to skip!]"
  fi
  dialogSetup
  [[ -n $2 ]] && start_path="$2" || start_path="${TMP_DIR}/"
  dialog --clear --keep-tite --title "$1" --dselect "${start_path}" $(($(tput lines)-14)) $(($(tput cols)-10)) 2>"${TMP_DIR}/dialog.out"
  dir=$([[ -f "${TMP_DIR}/dialog.out" ]] && cat "${TMP_DIR}/dialog.out" || echo "")
  tput cup $(( ${ROW#*[} -1 )) $(( COL -1 ))
  println DEBUG "${FG_LGRAY}${dir}${NC}"
}


