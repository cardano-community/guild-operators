#!/usr/bin/env bash
# Help contracts are checked against options extracted from production calls.
# Only version/help and device-free transaction validation/transform are run.
ck_hw_inventory() {
  awk -f "$CK_HOME/lib/data/hardware-calls.awk" "$CK_SOURCE"/lib/*.sh > "$CK_WORK/hardware-calls.tsv" || {
    ck_note 'Could not extract Hardware CLI calls from CNTools source'; return 1;
  }
  cp "$CK_WORK/hardware-calls.tsv" "$CK_CASE_DIR/source-calls.tsv" || return
  local location='' command='' flags='' count=0
  while IFS=$'\t' read -r location command flags; do
    case "$command" in
      'device version'|'address key-gen'|'transaction validate'|'transaction transform'|'transaction witness'|'node key-gen'|'node issue-op-cert'|'vote registration-metadata') ;;
      *) ck_note "Unmapped hardware command at $location: $command. Add a device-safe compatibility check."; return 1 ;;
    esac
    printf '%s: %s%s\n' "$location" "$command" "$flags"
    count=$((count+1))
  done < "$CK_WORK/hardware-calls.tsv"
  printf 'Extracted %s hardware invocations, including wallet/multisig, pool/KES and Catalyst calls.\n' "$count"
}
ck_hw_require() {
  [[ -n "$CK_HWCLI" && -x "$CK_HWCLI" ]] || { ck_skip 'Optional: install candidate cardano-hw-cli on PATH or supply --hw-cli'; return 77; }
}
ck_hw_version() {
  ck_hw_require || return
  ck_exec "$CK_CASE_DIR/version.txt" N "$CK_HWCLI" version || return
  local actual='' pin=''
  actual="$(< "$CK_CASE_DIR/version.txt")"
  [[ "$actual" =~ Cardano[[:space:]]+HW[[:space:]]+CLI[[:space:]]+Tool[[:space:]]+version[[:space:]]+v?([0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?) ]] || {
    ck_note 'Hardware CLI version output no longer matches the CNTools parser'; return 1;
  }
  actual="${BASH_REMATCH[1]}"
  pin="$(jq -er '.tools["cardano-hw-cli"].version' "$CK_REPO/files/node-implementations/common/release.json")" || return
  printf 'Executable: %s\nReported: %s\nDeployment hardware pin: %s\n' "$CK_HWCLI" "$actual" "$pin"
  [[ "$actual" == "$pin" ]] || ck_note 'Candidate differs from deployment pin. Passing checks do not change the production version guard.'
}
ck_hw_arguments() {
  local command="$1" flag='' required='' help="$CK_CASE_DIR/help.txt"
  local -a words=()
  ck_hw_require || return
  ck_require_file "$CK_WORK/hardware-calls.tsv" || return
  required="$(awk -F '\t' -v command="$command" '$2==command {print $3; found=1} END {if (!found) exit 1}' "$CK_WORK/hardware-calls.tsv")" || {
    ck_note "No source invocation found for $command; review the contract catalog"; return 1;
  }
  read -r -a words <<< "$command"
  ck_exec "$help" N "$CK_HWCLI" "${words[@]}" --help || return
  grep -F -- "cardano-hw-cli $command" "$help" >/dev/null || {
    ck_note "Help did not identify the requested Hardware CLI subcommand: $command"; return 1;
  }
  # --help bypasses option parsing: passing CNTools flags alongside --help
  # would falsely pass removed arguments. Compare exact advertised flag tokens.
  grep -Eo -- '--[a-z][a-z0-9-]*' "$help" | sort -u > "$CK_CASE_DIR/advertised-options.txt" || return
  for flag in $required; do
    grep -Fx -- "$flag" "$CK_CASE_DIR/advertised-options.txt" >/dev/null || {
      ck_note "Hardware CLI $command no longer advertises CNTools argument $flag"; return 1;
    }
  done
  printf 'Production arguments checked: %s\n' "${required:-none (subcommand only)}"
  ck_note 'Syntax contract only: value/repeat semantics and device approval/output are not established by help.'
}
ck_hw_transaction() {
  ck_hw_require || return
  # Use disposable CLI fixtures, including a token-bearing transaction. No
  # key export, device discovery, signing or certificate issuance is requested.
  if [[ ! -s "$CK_WORK/base.addr" ]]; then
    ck_cli_key payment && ck_cli_key stake && ck_cli_key drep && ck_cli_addresses || return
  fi
  local kind='' status=0 original='' transformed='' directory=''
  for kind in ada assets; do
    directory="$CK_WORK/tx-$kind"
    if [[ ! -s "$directory/body.json" ]]; then ck_cli_transaction "$kind" || return; fi
    status=0
    ck_exec "$CK_CASE_DIR/$kind-validation.txt" N "$CK_HWCLI" transaction validate --tx-file "$directory/body.json" || status=$?
    (( status == 0 || status == 3 )) || { ck_note "Hardware validator returned unexpected status $status for $kind fixture (expected 0 or 3)"; return 1; }
    transformed="$CK_WORK/hardware-$kind.json"
    ck_exec "$CK_WORK/out" N "$CK_HWCLI" transaction transform --tx-file "$directory/body.json" --out-file "$transformed" || return
    ck_envelope "$transformed" || return
    ck_exec "$CK_CASE_DIR/$kind-transformed-validation.txt" N "$CK_HWCLI" transaction validate --tx-file "$transformed" || return
    ck_cli "$CK_WORK/hardware-original-id" latest transaction txid --tx-file "$directory/body.json" --output-text || return
    ck_cli "$CK_WORK/hardware-transformed-id" latest transaction txid --tx-file "$transformed" --output-text || return
    original="$(< "$CK_WORK/hardware-original-id")"
    [[ "$original" == "$(< "$CK_WORK/hardware-transformed-id")" ]] || {
      ck_note "Hardware transform changed the canonical $kind transaction ID"; return 1;
    }
  done
  ck_note 'ADA and native-asset transactions validate and transform without a device; canonical transaction IDs are unchanged.'
}
ck_suite_hardware() {
  ck_run tools-hardware-source 'Hardware CLI — production call/argument inventory' discovery ck_hw_inventory
  ck_run tools-hardware-version 'Hardware CLI — version output contract' executed ck_hw_version
  local command='' id=''
  for command in 'device version' 'address key-gen' 'transaction validate' 'transaction transform' 'transaction witness' 'node key-gen' 'node issue-op-cert' 'vote registration-metadata'; do
    id="${command// /-}"
    ck_run "tools-hardware-$id" "Hardware CLI — $command arguments used by CNTools" syntax ck_hw_arguments "$command"
  done
  ck_run tools-hardware-transactions 'Hardware CLI — device-free validation and transform' executed ck_hw_transaction
}
