#!/usr/bin/env bash
# PIN-encrypted Catalyst QR creation. Never persist the unencrypted Bech32 key.
# shellcheck disable=SC2034,SC2015
CNTOOLS_CATALYST_QR_OUTPUT='' CNTOOLS_CATALYST_QR_TEXT=''

cntools_catalyst_qr_create() {
  local directory="$1" pin="$2" binary='' signing='' verification='' bech='' key='' image='' text='' errors='' status=0
  local -a names=()
  CNTOOLS_CATALYST_QR_OUTPUT=''; CNTOOLS_CATALYST_QR_TEXT=''
  [[ "${pin}" =~ ^[0-9]{4}$ ]] && cntools_catalyst_names_into names &&
    cntools_transaction_directory_safe "${directory}" && cntools_transaction_require_cli || return 1
  binary="${CNTOOLS_CATALYST_TOOLBOX:-$(type -P catalyst-toolbox || true)}"
  [[ -f "${binary}" && -x "${binary}" ]] || {
    cntools_catalyst_fail 'Catalyst Toolbox is required for voting-app QR codes. Install it using Guild Deploy.'; return 1;
  }
  signing="${directory}/${names[0]}"; verification="${directory}/${names[1]}"
  [[ ! -e "${signing}.gpg" && ! -L "${signing}.gpg" ]] &&
    cntools_catalyst_keys_prepare "${directory}" && cntools_catalyst_pair_valid "${signing}" "${verification}" || {
    cntools_catalyst_fail 'A matching unencrypted Catalyst voting key is required to generate the QR. Restore/decrypt it first.'; return 1;
  }
  cntools_transaction_snapshot_into signing "${signing}" 65536 catalyst-qr-signing &&
    cntools_transaction_temp_file key catalyst-bech32 && cntools_transaction_temp_file text catalyst-qr-console &&
    cntools_transaction_temp_file errors catalyst-qr-errors &&
    cntools_wallet_material_temp_file image "${directory}" catalyst-qr-image || return 1
  # Toolbox infers its image format from the extension. Keep the temporary PNG
  # in the wallet filesystem so publication can be no-overwrite hard linking.
  local png="${image}.png"
  [[ ! -e "${png}" && ! -L "${png}" ]] && ln -- "${image}" "${png}" || return 1
  CNTOOLS_WALLET_MATERIAL_TEMP_FILES+=("${png}")
  cntools_drep_bech32_into bech "$(jq -r '.cborHex[4:132]|ascii_downcase' "${signing}")" ed25519e_sk || return 1
  printf '%s\n' "${bech}" > "${key}"; unset bech
  # Toolbox has no PIN descriptor option. Redact argv in logs; its PIN is
  # briefly visible to same-user process inspection (documented in the UI).
  cntools_run_command_timeout 60 00001000000 -- "${binary}" qr-code encode --pin "${pin}" --input "${key}" \
    --output "${png}" --opts img > "${text}" 2> "${errors}" || status=$?
  if ((status == 0)); then
    [[ -s "${png}" && ! -L "${png}" && "${png}" -ef "${image}" &&
       "$(od -An -tx1 -N8 "${png}" | tr -d ' \n')" == 89504e470d0a1a0a ]] || status=1
  fi
  ((status == 0)) || { cntools_catalyst_fail "Catalyst QR generation failed (status ${status}); no existing QR was replaced."; return 1; }
  cntools_run_command_timeout 60 000010000 -- "${binary}" qr-code encode --pin "${pin}" --input "${key}" --opts img \
    > "${text}" 2> "${errors}" || status=$?
  ((status == 0)) || { cntools_catalyst_fail 'Catalyst console QR generation failed. No QR was published.'; return 1; }
  # Keep an existing QR intact. A new PIN produces a separate numbered artifact.
  local target="${directory}/${names[2]}" suffix=0
  while [[ -e "${target}" || -L "${target}" ]]; do
    suffix=$((suffix+1)); ((suffix <= 100)) || return 1
    target="${directory}/${names[2]%.png}-${suffix}.png"
  done
  chmod 0600 -- "${png}" && ln -- "${png}" "${target}" || return 1
  CNTOOLS_CATALYST_QR_OUTPUT="${target}"; CNTOOLS_CATALYST_QR_TEXT="${text}"
  cntools_transaction_log CATALYST "PIN-encrypted QR saved wallet=${directory##*/} file=${target}"
}
