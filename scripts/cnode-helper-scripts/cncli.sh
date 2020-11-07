#!/bin/bash
#shellcheck disable=SC2086
#shellcheck source=/dev/null

[[ -z "${CNODE_HOME}" ]] && CNODE_HOME="/opt/cardano/cnode"

. "${CNODE_HOME}"/scripts/env

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

POOL_ID=""                                # Required for leaderlog calculation, lower-case hex pool id
POOL_VRF_SKEY=""                          # Required for leaderlog calculation, path to pool's vrf.skey file
#CNCLI_DB="${CNODE_HOME}/db/cncli"        # path to sqlite db for cncli
#LIBSODIUM_FORK=/usr/local/lib            # path to IOG fork of libsodium
#SLEEP_RATE=20                            # time to wait until next check, used in leaderlog and validate (in seconds)
#CONFIRM_SLOT_CNT=300                     # require at least these many slots to have passed before validating
#CONFIRM_BLOCK_CNT=10                     # require at least these many blocks on top of minted before validating
#TIMEOUT_LEDGER_STATE=300                 # timeout in seconds for ledger-state query

######################################
# Do NOT modify code below           #
######################################

usage() {
  cat <<EOF >&2

Usage: $(basename "$0") [install] [sync] [leaderlog] [validate]
Script to deploy and run CNCLI

install     Installs RUST and CNCLI. If a previous install is found, an upgrade to latest version is performed
sync        Start CNCLI chainsync process that connects to cardano-node to sync blocks stored in SQLite DB
leaderlog   Loops through all slots in current epoch to calculate leader schedule
validate    Confirms that the block made actually was accepted and adopted by chain

sync, leaderlog & validate are all deployed as systemd services by '$(basename "$0") install'.
Use systemctl to launch the different services.

EOF
  exit 1
}

if [[ $# -eq 1 ]]; then subcommand=$1; else usage; fi

#################################
# helper functions

getNodeMetrics() {
  curl -s -m "${EKG_TIMEOUT}" -H 'Accept: application/json' "http://${EKG_HOST}:${EKG_PORT}/" 2>/dev/null
}

getEpoch() {
  jq -r '.cardano.node.ChainDB.metrics.epoch.int.val //0' <<< "${node_metrics}"
}

getBlockTip() {
  jq -r '.cardano.node.ChainDB.metrics.blockNum.int.val //0' <<< "${node_metrics}"
}

getSlotTip() {
  jq -r '.cardano.node.ChainDB.metrics.slotNum.int.val //0' <<< "${node_metrics}"
}

getSlotInEpoch() {
  jq -r '.cardano.node.ChainDB.metrics.slotInEpoch.int.val //0' <<< "${node_metrics}"
}

dumpLedgerState() {
  if ! timeout -k 5 "${TIMEOUT_LEDGER_STATE}" ${CCLI} shelley query ledger-state ${PROTOCOL_IDENTIFIER} ${NETWORK_IDENTIFIER} --out-file /tmp/ledger-state.json; then
    echo "ERROR: ledger dump failed/timed out, increase timeout value"
    [[ -f /tmp/ledger-state.json ]] && rm -f /tmp/ledger-state.json
    return 1
  fi
}

# Command    : getShelleyTransitionEpoch
# Description: Calculate shelley transition epoch
getShelleyTransitionEpoch() {
  calc_slot=0
  node_metrics=$(getNodeMetrics)
  slotnum=$(getSlotTip)
  slot_in_epoch=$(getSlotInEpoch)
  byron_epochs=$(getEpoch)
  shelley_epochs=0
  while [[ ${byron_epochs} -ge 0 ]]; do
    calc_slot=$(( (byron_epochs * BYRON_EPOCH_LENGTH) + (shelley_epochs * EPOCH_LENGTH) + slot_in_epoch ))
    [[ ${calc_slot} -eq ${slotnum} ]] && break
    ((byron_epochs--))
    ((shelley_epochs++))
  done
  if [[ "${NWMAGIC}" = "764824073" ]]; then
    shelley_transition_epoch=208
  elif [[ ${calc_slot} -ne ${slotnum} || ${shelley_epochs} -eq 0 ]]; then
    shelley_transition_epoch=-1
  else
    shelley_transition_epoch=${byron_epochs}
  fi
}

# Command    : getSlotTipRef
# Description: Get calculated slot number tip
getSlotTipRef() {
  current_time_sec=$(date -u +%s)
  if [[ "${PROTOCOL}" = "Cardano" ]]; then
    # Combinator network
    byron_slots=$(( shelley_transition_epoch * BYRON_EPOCH_LENGTH )) # since this point will only be reached once we're in Shelley phase
    byron_end_time=$(( BYRON_GENESIS_START_SEC + ( shelley_transition_epoch * BYRON_EPOCH_LENGTH * BYRON_SLOT_LENGTH ) ))
    if [[ "${current_time_sec}" -lt "${byron_end_time}" ]]; then
      # In Byron phase
      echo $(( ( current_time_sec - BYRON_GENESIS_START_SEC ) / BYRON_SLOT_LENGTH ))
    else
      # In Shelley phase
      echo $(( byron_slots + (( current_time_sec - byron_end_time ) / SLOT_LENGTH ) ))
    fi
  else
    # Shelley Mode only, no Byron slots
    echo $(( ( current_time_sec - SHELLEY_GENESIS_START_SEC ) / SLOT_LENGTH ))
  fi
}

#################################

cncliInit() {
  [[ -z "${CNCLI_DB}" ]] && CNCLI_DB="${CNODE_HOME}/db/cncli"
  [[ -z "${LIBSODIUM_FORK}" ]] && LIBSODIUM_FORK=/usr/local/lib
  export LD_LIBRARY_PATH="${LIBSODIUM_FORK}:${LD_LIBRARY_PATH}"
  [[ -z "${SLEEP_RATE}" ]] && SLEEP_RATE=20
  [[ -z "${CONFIRM_SLOT_CNT}" ]] && CONFIRM_SLOT_CNT=300
  [[ -z "${CONFIRM_BLOCK_CNT}" ]] && CONFIRM_BLOCK_CNT=10
  [[ -z "${TIMEOUT_LEDGER_STATE}" ]] && TIMEOUT_LEDGER_STATE=300

  PARENT="$(dirname "$0")"
  [[ -f "${PARENT}"/.env_branch ]] && BRANCH="$(cat "${PARENT}"/.env_branch)" || BRANCH="master"

  URL="https://raw.githubusercontent.com/cardano-community/guild-operators/${BRANCH}/scripts/cnode-helper-scripts"
  curl -s -m 10 -o "${PARENT}"/env.tmp ${URL}/env
  if [[ -f "${PARENT}"/env ]]; then
    if [[ $(grep "_HOME=" "${PARENT}"/env) =~ ^#?([^[:space:]]+)_HOME ]]; then
      vname=$(tr '[:upper:]' '[:lower:]' <<< "${BASH_REMATCH[1]}")
      sed -e "s@/opt/cardano/[c]node@/opt/cardano/${vname}@g" -e "s@[C]NODE_HOME@${BASH_REMATCH[1]}_HOME@g" -i "${PARENT}"/env.tmp
    else
      echo -e "Update failed! Please use prereqs.sh to force an update or manually download $(basename "$0") + env from GitHub"
      exit 1
    fi
    TEMPL_CMD=$(awk '/^# Do NOT modify/,0' "${PARENT}"/env)
    TEMPL2_CMD=$(awk '/^# Do NOT modify/,0' "${PARENT}"/env.tmp)
    if [[ "$(echo "${TEMPL_CMD}" | sha256sum)" != "$(echo "${TEMPL2_CMD}" | sha256sum)" ]]; then
      cp "${PARENT}"/env "${PARENT}/env_bkp$(date +%s)"
      STATIC_CMD=$(awk '/#!/{x=1}/^# Do NOT modify/{exit} x' "${PARENT}"/env)
      printf '%s\n%s\n' "$STATIC_CMD" "$TEMPL2_CMD" > "${PARENT}"/env.tmp
      mv "${PARENT}"/env.tmp "${PARENT}"/env
    fi
  else
    mv "${PARENT}"/env.tmp "${PARENT}"/env
  fi
  rm -f "${PARENT}"/env.tmp
  if ! . "${PARENT}"/env; then exit 1; fi
  [[ ! -f "${CNCLI}" ]] && echo -e "ERROR: failed to locate cncli executable, please run:\n $(basename "$0") install\n$(usage)" && exit 1
  return 0
}

#################################

cncliInstall() {
  dirs -c

  echo "~ Installing CNCLI with dependencies ~"
  # install rust if not available
  if ! command -v "rustup" &>/dev/null; then
    echo "installing RUST..."
    if ! output=$(curl https://sh.rustup.rs -sSf | sh -s -- -y 2>&1); then echo -e "${output}" && exit 1; fi
  else
    echo "updating rustup if needed..."
    rustup update &>/dev/null #ignore any errors, not crucial that update succeed
  fi

  [[ -d "${HOME}"/git ]] || mkdir -p "${HOME}"/git
  pushd "${HOME}"/git >/dev/null || exit 1

  if [[ -d ./cncli ]]; then
    echo "previous cncli installation found, updating and building latest..."
    pushd ./cncli >/dev/null || exit 1
    if ! output=$(git pull 2>&1); then echo -e "${output}" && exit 1; fi
  else
    echo "downloading and building cncli..."
    if ! output=$(git clone https://github.com/AndrewWestberg/cncli.git 2>&1); then echo -e "${output}" && exit 1; fi
    pushd ./cncli >/dev/null || exit 1
  fi
  if ! output=$(cargo install --path . --force 2>&1); then echo -e "${output}" && exit 1; fi

  . "${HOME}"/.profile # source profile to load ${HOME}/.cargo/bin into PATH

  pushd -0 >/dev/null && dirs -c

  PARENT="$(dirname "$0")"
  if [[ $(grep "_HOME=" "${PARENT}"/env) =~ ^#?([^[:space:]]+)_HOME ]]; then
    vname=$(tr '[:upper:]' '[:lower:]' <<< "${BASH_REMATCH[1]}")
  else
    echo "failed to get cnode instance name from env file, aborting!"
    exit 1
  fi

  service_file="${vname}-cncli-sync.service"
  if [[ -f "/etc/systemd/system/${service_file}" ]]; then
    echo "${service_file} already deployed, update? [y|n]"
    read -rsn1 yn
  else
    yn='Y'
  fi
  if [[ ${yn} = [Yy] ]]; then
    echo "deploying systemd ${service_file} file"
    sudo bash -c "cat << 'EOF' > /etc/systemd/system/${service_file}
[Unit]
Description=Cardano Node - CNCLI Sync
Requires=${vname}.service
After=${vname}.service

[Service]
Type=simple
Restart=on-failure
RestartSec=5
User=$USER
WorkingDirectory=${CNODE_HOME}/scripts
ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/cncli.sh sync\"
ExecStop=/bin/bash -l -c \"exec kill -2 \$(ps -ef | grep [c]ncli.sync.*.${CNODE_HOME}/ | tr -s ' ' | cut -d ' ' -f2)\"
KillSignal=SIGINT
SuccessExitStatus=143
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=${vname}-cncli-sync
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF"
  sudo systemctl daemon-reload
  sudo systemctl enable "${service_file}" &>/dev/null
  fi
  
  service_file="${vname}-cncli-leaderlog.service"
  if [[ -f "/etc/systemd/system/${service_file}" ]]; then
    echo "${service_file} already deployed, update? [y|n]"
    read -rsn1 yn
  else
    yn='Y'
  fi
  if [[ ${yn} = [Yy] ]]; then
    echo "deploying systemd ${service_file} file"
    sudo bash -c "cat << 'EOF' > /etc/systemd/system/${service_file}
[Unit]
Description=Cardano Node - CNCLI Leaderlog
Requires=${vname}-cncli-sync.service
After=${vname}-cncli-sync.service

[Service]
Type=simple
Restart=on-failure
RestartSec=5
User=$USER
WorkingDirectory=${CNODE_HOME}/scripts
ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/cncli.sh leaderlog\"
SuccessExitStatus=143
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=${vname}-cncli-leaderlog
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF"
  sudo systemctl daemon-reload
  sudo systemctl enable "${service_file}" &>/dev/null
  fi
  
  service_file="${vname}-cncli-validate.service"
  if [[ -f "/etc/systemd/system/${service_file}" ]]; then
    echo "${service_file} already deployed, update? [y|n]"
    read -rsn1 yn
  else
    yn='Y'
  fi
  if [[ ${yn} = [Yy] ]]; then
    echo "deploying systemd ${service_file} file"
    sudo bash -c "cat << 'EOF' > /etc/systemd/system/${service_file}
[Unit]
Description=Cardano Node - CNCLI Validate
Requires=${vname}-cncli-sync.service
After=${vname}-cncli-sync.service

[Service]
Type=simple
Restart=on-failure
RestartSec=5
User=$USER
WorkingDirectory=${CNODE_HOME}/scripts
ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/cncli.sh validate\"
SuccessExitStatus=143
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=${vname}-cncli-validate
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF"
  sudo systemctl daemon-reload
  sudo systemctl enable "${service_file}" &>/dev/null
  fi

  echo -e "\n$(cncli -V) installed!"
}

#################################

cncliSync() {
  ${CNCLI} sync --host 127.0.0.1 --network-magic "${NWMAGIC}" --port "${CNODE_PORT}" --db "${CNCLI_DB}"
}

#################################

cncliLeaderlog() {
  echo "~ CNCLI Leaderlog started ~"
  [[ -f /tmp/ledger-state.json ]] && rm -f /tmp/ledger-state.json
  [[ -z ${POOL_ID} || -z ${POOL_VRF_SKEY} ]] && echo "'POOL_ID' and/or 'POOL_VRF_SKEY' not set in $(basename "$0"), exiting!" && exit 1
  while true; do
    getShelleyTransitionEpoch
    if [[ ${shelley_transition_epoch} -lt 0 ]]; then
      echo "Failed to calculate shelley transition epoch, checking again in ${SLEEP_RATE}s"
    else
      node_metrics=$(getNodeMetrics)
      slot_tip=$(getSlotTip)
      tip_diff=$(( $(getSlotTipRef) - $(getSlotTip) ))
      [[ ${tip_diff} -lt 300 ]] && break # Node considered in sync if less than 300 slots from theoretical tip
      echo "Node still in sync, ${tip_diff} slots from theoretical tip, checking again in ${SLEEP_RATE}s"
    fi
    sleep ${SLEEP_RATE}
  done
  first_run="true"
  slot_in_epoch=$(getSlotInEpoch)
  # firstSlotOfNextEpoch - stabilityWindow(3 * k / f)
  slot_for_next_nonce=$(echo "(${slot_tip} - ${slot_in_epoch} + ${EPOCH_LENGTH}) - (3 * ${BYRON_K} / ${ACTIVE_SLOTS_COEFF})" | bc)
  while true; do
    sleep ${SLEEP_RATE}
    node_metrics=$(getNodeMetrics)
    curr_epoch=$(getEpoch)
    next_epoch=$((curr_epoch+1))
    slot_in_epoch=$(getSlotInEpoch)
    if [[ ${first_run} = "true" ]]; then # First startup, run leaderlogs for current epoch and merge with current data if it exist
      blocks_file="${BLOCK_DIR}/blocks_${curr_epoch}.json"
      if ! dumpLedgerState; then sleep 300; continue; fi
      cncli_leaderlog=$(${CNCLI} leaderlog --db "${CNCLI_DB}" --byron-genesis "${BYRON_GENESIS_JSON}" --shelley-genesis "${GENESIS_JSON}" --ledger-set current --ledger-state /tmp/ledger-state.json --pool-id "${POOL_ID}" --pool-vrf-skey "${POOL_VRF_SKEY}")
      [[ ! -f "${blocks_file}" ]] && echo "[]" > "${blocks_file}"
      if [[ $(jq -r .status <<< "${cncli_leaderlog}") != ok ]]; then
        echo "ERROR: failure in leaderlog while running:"
        echo "${CNCLI} leaderlog --db ${CNCLI_DB} --byron-genesis ${BYRON_GENESIS_JSON} --shelley-genesis ${GENESIS_JSON} --ledger-set current --ledger-state /tmp/ledger-state.json --pool-id ${POOL_ID} --pool-vrf-skey ${POOL_VRF_SKEY}"
        echo "Error message: $(jq -r '.errorMessage //empty' <<< "${cncli_leaderlog}")"
        continue
      fi
      jq -c '.assignedSlots[]' <<< "${cncli_leaderlog}" | while read -r assigned_slot; do
        slot=$(jq -r '.slot' <<< "${assigned_slot}")
        slot_search=$(jq --arg _slot "${slot}" '.[] | select(.slot == $_slot)' "${blocks_file}")
        if [[ -z ${slot_search} ]]; then
          at=$(jq -r '.at' <<< "${assigned_slot}")
          slotInEpoch=$(jq -r '.slotInEpoch' <<< "${assigned_slot}")
          jq --arg _at "${at}" \
             --arg _slot "${slot}" \
             --arg _slotInEpoch "${slotInEpoch}" \
             '. += [{"at": $_at,"slot": $_slot,"slotInEpoch": $_slotInEpoch,"status": "leader"}]' \
             "${blocks_file}" > "/tmp/blocks.json" && mv -f "/tmp/blocks.json" "${blocks_file}"
          echo "LEADER: slot[${slot}] slotInEpoch[${slotInEpoch}] at[${at}]"
        fi
      done
      first_run="false"
    fi
    blocks_file="${BLOCK_DIR}/blocks_${next_epoch}.json"
    if [[ ! -f "${blocks_file}" && ${slot_in_epoch} -gt ${slot_for_next_nonce} ]]; then # Run leaderlogs for next epoch
      [[ -f /tmp/ledger-state.json ]] || if ! dumpLedgerState; then sleep 300; continue; fi
      cncli_leaderlog=$(${CNCLI} leaderlog --db "${CNCLI_DB}" --byron-genesis "${BYRON_GENESIS_JSON}" --shelley-genesis "${GENESIS_JSON}" --ledger-set next --ledger-state /tmp/ledger-state.json --pool-id "${POOL_ID}" --pool-vrf-skey "${POOL_VRF_SKEY}")
      rm -f /tmp/ledger-state.json
      if [[ $(jq -r .status <<< "${cncli_leaderlog}") != ok ]]; then
        echo "ERROR: failure in leaderlog while running:"
        echo "${CNCLI} leaderlog --db ${CNCLI_DB} --byron-genesis ${BYRON_GENESIS_JSON} --shelley-genesis ${GENESIS_JSON} --ledger-set next --ledger-state /tmp/ledger-state.json --pool-id ${POOL_ID} --pool-vrf-skey ${POOL_VRF_SKEY}"
        echo "Error message: $(jq -r '.errorMessage //empty' <<< "${cncli_leaderlog}")"
        continue
      fi
      jq -r '.assignedSlots | .[] += {"status": "leader"}' <<< "${cncli_leaderlog}" > "${blocks_file}"
      echo "Leaderlogs for next epoch[${next_epoch}] calculated and saved to ${blocks_file}"
    fi
  done
}

#################################

cncliValidate() {
  echo "~ CNCLI Block Validation started ~"
  while true; do
    sleep ${SLEEP_RATE}
    node_metrics=$(getNodeMetrics)
    block_tip=$(getBlockTip)
    slot_tip=$(getSlotTip)
    curr_epoch=$(getEpoch)
    prev_epoch=$((curr_epoch-1))
    # Start with previous epoch to catch epoch boundary cases
    blocks_file="${BLOCK_DIR}/blocks_${prev_epoch}.json"
    if [[ -f "${blocks_file}" ]]; then
      jq -c '.[]' "${blocks_file}" | while read -r block; do
        validateBlock "${block}"
      done
    fi
    # continue with current epoch
    blocks_file="${BLOCK_DIR}/blocks_${curr_epoch}.json"
    if [[ -f "${blocks_file}" ]]; then
      jq -c '.[]' "${blocks_file}" | while read -r block; do
        validateBlock "${block}"
      done
    fi
  done
}

validateBlock() {
  block=$1
  block_status=$(jq -r '.status //empty' <<< "${block}")
  [[ ${block_status} = invalid ]] && return
  if [[ ${block_status} = leader ]]; then
    block_slot=$(jq -r '.slot' <<< "${block}")
    [[ ${block_slot} -ge ${slot_tip} ]] && return
    # assume lost for now, TODO: use cncli/sqlite to check if slot was made by another pool
    jq --arg _slot "${block_slot}" \
       '[.[] | select(.slot == $_slot) += {"status": "missed"}}]' \
       "${blocks_file}" > "/tmp/blocks.json" && mv -f "/tmp/blocks.json" "${blocks_file}"
    echo "MISSED: Leader for slot '${block_slot}' but not adopted. Verify that logMonitor companion script is running and working!"
  elif [[ ${block_status} = adopted ]]; then
    block_slot=$(jq -r '.slot' <<< "${block}")
    [[ $((slot_tip - block_slot)) -lt ${CONFIRM_SLOT_CNT} ]] && return # To make sure enough slots has passed before validating
    block_hash=$(jq -r '.hash //empty' <<< "${block}")
    if [[ -n ${block_hash} ]]; then # Can't validate without a hash
      cncli_block_data=$(${CNCLI} validate --hash "${block_hash}" --db "${CNCLI_DB}")
      if [[ $(jq -r .status <<< "${cncli_block_data}") = ok ]]; then
        cncli_slot_nbr=$(jq -r .slot_number <<< "${cncli_block_data}")
        if [[ ${cncli_slot_nbr} -ne ${block_slot} ]]; then
          echo "ERROR: CNCLI slot nbr[${cncli_slot_nbr}] doesn't match adopted block slot nbr[${block_slot}] for hash '${block_hash}'"
        else
          cncli_block_nbr=$(jq -r .block_number <<< "${cncli_block_data}")
          [[ $((block_tip-cncli_block_nbr)) -lt ${CONFIRM_SLOT_CNT} ]] && return # To make sure enough blocks has been built on top before validating
          # Block confimed
          cncli_block_hash=$(jq -r .hash <<< "${cncli_block_data}")
          jq --arg _slot "${block_slot}" \
             --arg _block "${cncli_block_nbr}" \
             --arg _hash "${cncli_block_hash}" \
             '[.[] | select(.slot == $_slot) += {"block": $_block,"hash": $_hash,"status": "confirmed"}}]' \
             "${blocks_file}" > "/tmp/blocks.json" && mv -f "/tmp/blocks.json" "${blocks_file}"
          echo "CONFIRMED: Block[${cncli_block_nbr}] / Slot[${block_slot}] at $(date '+%F %T Z' "--date=@$(jq -r '.at' <<< "${block}")"), hash: ${cncli_block_hash}"
        fi
      else
        jq --arg _slot "${block_slot}" \
           '[.[] | select(.slot == $_slot) += {"status": "ghosted"}}]' \
           "${blocks_file}" > "/tmp/blocks.json" && mv -f "/tmp/blocks.json" "${blocks_file}"
        echo "GHOSTED: Leader for slot '${block_slot}' but block hash '${block_hash}' not found, stolen in slot/height battle or block propagation issue!"
      fi
    else
      echo "ERROR: Block adopted for slot '${block_slot}' but no hash logged?"
    fi
  fi
}



#################################

case ${subcommand} in
  install ) 
    cncliInit && cncliInstall ;;
  sync ) 
    cncliInit && cncliSync ;;
  leaderlog )
    cncliInit && cncliLeaderlog ;;
  validate )
    cncliInit && cncliValidate ;;
  * ) usage ;;
esac