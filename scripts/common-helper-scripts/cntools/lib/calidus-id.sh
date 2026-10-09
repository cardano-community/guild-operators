#!/usr/bin/env bash
# Calidus pool identity: a1 + Blake2b-224(public key), Bech32 HRP calidus.
# Share the checksum-tested encoder; hash public bytes with cardano-cli.
cntools_calidus_id_into() {
  local output="$1" file="$2" ci_public='' ci_hash='' ci_id=''
  cntools_transaction_key_id_from_verification_file_into ci_public "${file}" &&
    cntools_transaction_credential_from_key_id_into ci_hash "${ci_public}" &&
    cntools_drep_bech32_into ci_id "a1${ci_hash}" calidus || return 1
  printf -v "${output}" '%s' "${ci_id}"
}
