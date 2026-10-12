#!/usr/bin/env bash
# Read-only credential facts from checksum-validated Shelley addresses and DRep
# IDs. Key/Script describes the ledger credential, not CLI/hardware origin or
# native/Plutus script language. No network requests or key files are needed.
# shellcheck disable=SC2034

cntools_address_credentials_into() {
  local ac_target="$1" ac_address="$2" ac_hrp='' ac_hex='' ac_kind=0
  local ac_payment='' ac_payment_type='' ac_stake='' ac_stake_type='' ac_pointer=N
  local ac_drep='' ac_drep_kind='' ac_drep_hash=''
  [[ "${ac_target}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n ac_result="${ac_target}"
  ac_result='{}'
  case "${ac_address}" in
    addr1*) ac_hrp=addr ;;
    addr_test1*) ac_hrp=addr_test ;;
    stake1*) ac_hrp=stake ;;
    stake_test1*) ac_hrp=stake_test ;;
    pool1*)
      cntools_bech32_decode_into ac_hex "${ac_address}" pool || return 1
      [[ "${ac_hex}" =~ ^[0-9a-f]{56}$ ]] || return 1
      printf -v ac_result '{"credential":{"hash":"%s","type":"Key"}}' "${ac_hex}"
      return 0 ;;
    drep1*|drep_script1*)
      declare -F cntools_drep_id_into >/dev/null || return 1
      cntools_drep_id_into ac_drep ac_drep_kind ac_drep_hash "${ac_address}" || return 1
      case "${ac_drep_kind}" in key) ac_drep_kind=Key ;; script) ac_drep_kind=Script ;; *) return 1 ;; esac
      printf -v ac_result '{"credential":{"hash":"%s","type":"%s"}}' "${ac_drep_hash}" "${ac_drep_kind}"
      return 0 ;;
    *) return 1 ;;
  esac
  cntools_bech32_decode_into ac_hex "${ac_address}" "${ac_hrp}" || return 1
  [[ "${ac_hex}" =~ ^[0-9a-f]+$ ]] || return 1
  if [[ "${ac_hrp}" == addr || "${ac_hrp}" == stake ]]; then
    [[ "${ac_hex:1:1}" == 1 ]] || return 1
  else
    [[ "${ac_hex:1:1}" != 1 ]] || return 1
  fi
  ac_kind=$((16#${ac_hex:0:1}))
  case "${ac_kind}" in
    0|1|2|3)
      [[ "${ac_hrp}" == addr* && ${#ac_hex} == 114 ]] || return 1
      ac_payment="${ac_hex:2:56}"; ac_stake="${ac_hex:58:56}"
      ac_payment_type=Key; ac_stake_type=Key
      (( ac_kind % 2 == 0 )) || ac_payment_type=Script
      (( ac_kind < 2 )) || ac_stake_type=Script ;;
    4|5)
      [[ "${ac_hrp}" == addr* && ${#ac_hex} -ge 64 ]] || return 1
      # Three canonical variable-length unsigned pointer coordinates.
      local ac_index=58 ac_coordinates=0 ac_byte=0 ac_start=Y
      while (( ac_index < ${#ac_hex} )); do
        (( ac_coordinates < 3 )) || return 1
        ac_byte=$((16#${ac_hex:ac_index:2}))
        [[ "${ac_start}" != Y || ${ac_byte} != 128 ]] || return 1
        ac_start=N; ac_index=$((ac_index+2))
        if (( ac_byte < 128 )); then ac_coordinates=$((ac_coordinates+1)); ac_start=Y; fi
      done
      (( ac_coordinates == 3 && ac_byte < 128 )) || return 1
      ac_payment="${ac_hex:2:56}"; ac_payment_type=Key; ac_pointer=Y
      (( ac_kind == 4 )) || ac_payment_type=Script ;;
    6|7)
      [[ "${ac_hrp}" == addr* && ${#ac_hex} == 58 ]] || return 1
      ac_payment="${ac_hex:2}"; ac_payment_type=Key
      (( ac_kind == 6 )) || ac_payment_type=Script ;;
    14|15)
      [[ "${ac_hrp}" == stake* && ${#ac_hex} == 58 ]] || return 1
      ac_stake="${ac_hex:2}"; ac_stake_type=Key
      (( ac_kind == 14 )) || ac_stake_type=Script ;;
    *) return 1 ;;
  esac
  # All interpolated values are validated hex or fixed enums.
  ac_result="$(jq -nc --arg payment "${ac_payment}" --arg paymentType "${ac_payment_type}" \
    --arg stake "${ac_stake}" --arg stakeType "${ac_stake_type}" --arg pointer "${ac_pointer}" '
    (if $payment=="" then {} else {payment:{hash:$payment,type:$paymentType}} end) +
    (if $stake=="" then {} else {stake:{hash:$stake,type:$stakeType}} end) +
    (if $pointer=="Y" then {stakeReference:"Pointer"} else {} end)')" || return 1
}
