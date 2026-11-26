#!/usr/bin/env bash
# shellcheck disable=SC2034
ck_tool() {
  local -n tool_result="$1"
  tool_result="$(type -P "$2" || true)"
  [[ -n "$tool_result" ]] || { ck_skip "Optional companion not installed: $2 (install candidate and add to PATH)"; return 77; }
}
ck_tools_openssl() {
  local binary='' plain='Compatibility CIP-83 round-trip' password='Disposable compatibility password' recovered='' salt=''
  local -a args=()
  ck_tool binary openssl || return
  ck_exec "$CK_CASE_DIR/version.txt" N "$binary" version || return
  cntools_message_crypto_arguments_into args || { ck_note 'OpenSSL lacks the PBKDF2 options required for CIP-83'; return 1; }
  printf '%s' "$plain" > "$CK_WORK/plain"
  ck_exec "$CK_WORK/encrypted" Y "$binary" enc -e "${args[@]}" -pass fd:3 3<<< "$password" < "$CK_WORK/plain" || return
  ck_exec "$CK_WORK/decrypted" Y "$binary" enc -d "${args[@]}" -pass fd:3 3<<< "$password" < "$CK_WORK/encrypted" || return
  recovered="$(< "$CK_WORK/decrypted")"
  [[ "$recovered" == "$plain" ]] || { ck_note 'CIP-83 round-trip mismatch'; return 1; }
  ck_exec "$CK_WORK/cipher-bytes" Y "$binary" base64 -d -A < "$CK_WORK/encrypted" || return
  salt="$(od -An -N8 -tx1 "$CK_WORK/cipher-bytes" | tr -d ' \n')"
  [[ "$salt" == 53616c7465645f5f && "$(wc -c < "$CK_WORK/cipher-bytes" | tr -d ' ')" == 48 ]] || { ck_note 'Unexpected CIP-83 Salted__ envelope / eight-byte salt layout'; return 1; }
  # Ed25519 verification is also required for detached transaction witnesses.
  ck_exec "$CK_WORK/out" Y "$binary" genpkey -algorithm ED25519 -out "$CK_WORK/ed25519.pem" || return
  ck_exec "$CK_WORK/out" N "$binary" pkey -in "$CK_WORK/ed25519.pem" -pubout -out "$CK_WORK/ed25519.pub" || return
  ck_exec "$CK_WORK/out" N "$binary" pkeyutl -sign -rawin -inkey "$CK_WORK/ed25519.pem" -in "$CK_WORK/plain" -out "$CK_WORK/signature" || return
  ck_exec "$CK_WORK/out" N "$binary" pkeyutl -verify -rawin -pubin -inkey "$CK_WORK/ed25519.pub" -in "$CK_WORK/plain" -sigfile "$CK_WORK/signature" || return
  printf 'Changed' > "$CK_WORK/changed"
  local status=0
  ck_exec "$CK_WORK/out" N "$binary" pkeyutl -verify -rawin -pubin -inkey "$CK_WORK/ed25519.pub" -in "$CK_WORK/changed" -sigfile "$CK_WORK/signature" || status=$?
  (( status != 0 && status != 124 )) || { ck_note 'Invalid Ed25519 signature was accepted, or verification timed out'; return 1; }
  ck_note 'CIP-83 encryption and Ed25519 positive/negative verification passed.'
}
ck_tools_gpg() {
  local binary='' password='Disposable compatibility password' short_password=legacy
  ck_tool binary gpg || return
  local GNUPGHOME="$CK_WORK/gnupg"; export GNUPGHOME
  mkdir -m700 "$GNUPGHOME" || return
  # Only the private test agent is stopped; never touch the user's GPG home.
  trap 'if type -P gpgconf >/dev/null; then gpgconf --homedir "$CK_WORK/gnupg" --kill all >/dev/null 2>&1 || true; fi' EXIT
  ck_exec "$CK_CASE_DIR/version.txt" N "$binary" --no-options --version || return
  printf '{"type":"Disposable","cborHex":"00"}\n' > "$CK_WORK/key-plain"
  local pass='' status=0
  for pass in "$password" "$short_password"; do
    : > "$CK_WORK/key-encrypted"; : > "$CK_WORK/key-decrypted"; : > "$CK_WORK/gpg-errors"
    cntools_key_crypto_run "$binary" encrypt "$CK_WORK/key-plain" "$CK_WORK/key-encrypted" "$pass" "$CK_WORK/gpg-errors" "$CK_TIMEOUT" || status=$?
    if (( status == 0 )); then
      cntools_key_crypto_run "$binary" decrypt "$CK_WORK/key-encrypted" "$CK_WORK/key-decrypted" "$pass" "$CK_WORK/gpg-errors" "$CK_TIMEOUT" 65536 || status=$?
    fi
    if (( status != 0 )); then
      cp "$CK_WORK/gpg-errors" "$CK_CASE_DIR/gpg-errors.log"
      if grep -Eqi 'Operation not permitted|Permission denied|No agent running|IPC connect' "$CK_WORK/gpg-errors"; then ck_block 'GPG-agent IPC unavailable in this environment'; return 78; fi
      ck_note "GPG round-trip failed (status $status). See gpg-errors.log."; return 1
    fi
    cmp -s "$CK_WORK/key-plain" "$CK_WORK/key-decrypted" || { ck_note 'Decrypted key bytes differ'; return 1; }
  done
}
ck_tools_address() {
  local binary='' phrase='' role='' path='' CK_SECRET=Y
  ck_tool binary cardano-address || return
  if [[ ! -s "$CK_WORK/mnemonic" ]]; then ck_cli "$CK_WORK/mnemonic" latest key generate-mnemonic --size 24 || return; fi
  ck_exec "$CK_CASE_DIR/version.txt" N "$binary" --version || return
  phrase="$(< "$CK_WORK/mnemonic")"
  ck_exec "$CK_WORK/root" Y "$binary" key from-recovery-phrase Shelley <<< "$phrase" || return
  for role in payment stake; do
    path="1854H/0H/0H/0/0"; [[ "$role" != stake ]] || path="1854H/0H/0H/2/0"
    ck_exec "$CK_WORK/child" Y "$binary" key child "$path" < "$CK_WORK/root" || return
    local selector=--shelley-payment-key; [[ "$role" != stake ]] || selector=--shelley-stake-key
    ck_cli "$CK_WORK/out" key convert-cardano-address-key "$selector" --signing-key-file "$CK_WORK/child" --out-file "$CK_WORK/address-$role.skey" || return
    ck_envelope "$CK_WORK/address-$role.skey" || return
  done
  ck_note 'Custom CIP-1854 payment and stake derivation succeeded; recovery words are not retained.'
}
ck_tools_signer() {
  local binary='' CK_SECRET=Y
  ck_tool binary cardano-signer || return
  ck_exec "$CK_CASE_DIR/version.txt" N "$binary" --version || return
  ck_exec "$CK_WORK/out" Y "$binary" keygen --cip36 --out-skey "$CK_WORK/catalyst.skey" --out-vkey "$CK_WORK/catalyst.vkey" || return
  ck_require_file "$CK_WORK/catalyst.skey" && ck_require_file "$CK_WORK/catalyst.vkey" || return 1
  if [[ ! -s "$CK_WORK/cold.skey" ]]; then ck_cli_pool_keys || return; fi
  if [[ ! -s "$CK_WORK/payment.vkey" ]]; then ck_cli_key payment || return; fi
  local public=''; public="$(jq -r '.cborHex|.[4:]' "$CK_WORK/payment.vkey")"
  ck_exec "$CK_WORK/out" N "$binary" sign --cip88 --calidus-public-key "$public" --secret-key "$CK_WORK/cold.skey" --nonce 1 --json --out-file "$CK_WORK/calidus.json" || return
  ck_exec "$CK_CASE_DIR/verified.json" N "$binary" verify --cip88 --data-file "$CK_WORK/calidus.json" --json-extended || return
  local cold=''; cold="$(jq -r '.cborHex|.[4:]' "$CK_WORK/cold.vkey")"
  ck_assert "$CK_CASE_DIR/verified.json" "type==\"object\" and .workMode==\"verify-cip88\" and .result==\"true\" and .calidusPublicKey==\"$public\" and .publicKey==\"$cold\" and .nonce==1" 'CIP-88/151 verification result, identity and nonce'
}
ck_tools_syntax() {
  local binary=''; ck_tool binary "$1" || return
  ck_exec "$CK_WORK/tool-help" N "$binary" "${@:2}" --help
}
ck_tools_registry() {
  local binary='' policy='' subject='' directory="$CK_WORK/registry"
  ck_tool binary token-metadata-creator || return
  if [[ ! -s "$CK_WORK/payment.vkey" ]]; then ck_cli_key payment || return; fi
  ck_cli "$CK_WORK/registry-keyhash" address key-hash --payment-verification-key-file "$CK_WORK/payment.vkey" || return
  mkdir "$directory" || return
  jq -n --arg h "$(< "$CK_WORK/registry-keyhash")" '{type:"sig",keyHash:$h}' > "$directory/policy.json" || return
  ck_cli "$CK_WORK/registry-policyid" latest transaction policyid --script-file "$directory/policy.json" || return
  policy="$(< "$CK_WORK/registry-policyid")"; subject="${policy}74657374"
  cd "$directory" || return
  ck_exec "$CK_WORK/out" N "$binary" entry "$subject" --init --policy "$directory/policy.json" \
    --name '"Compatibility"' --description '"Disposable compatibility token"' --ticker '"CHECK"' --decimals 6 || return
  ck_exec "$CK_WORK/out" N "$binary" entry "$subject" -a "$CK_WORK/payment.skey" || return
  ck_exec "$CK_WORK/out" N "$binary" entry "$subject" --finalize || return
  ck_exec "$CK_WORK/out" N "$binary" validate "$directory/$subject.json" || return
  ck_assert "$directory/$subject.json" ".subject==\"$subject\" and .name.value==\"Compatibility\" and .decimals.value==6 and all(.name,.description; (.sequenceNumber|type==\"number\" and .>=0) and (.signatures|length>0))" 'Finalized signed Token Registry fields'
}
ck_tools_archive() {
  local binary='' directory="$CK_WORK/archive"
  ck_tool binary tar || return
  type -P gzip >/dev/null || { ck_block 'gzip is required for archive checks'; return 78; }
  mkdir -p "$directory/source" "$directory/restored" || return
  printf 'Disposable archive compatibility data\n' > "$directory/source/entry.txt"
  ck_exec "$CK_WORK/out" N "$binary" -czf "$directory/archive.tar.gz" -C "$directory/source" entry.txt || return
  ck_exec "$CK_WORK/out" N gzip -t "$directory/archive.tar.gz" || return
  ck_exec "$CK_CASE_DIR/members.txt" N "$binary" -tzf "$directory/archive.tar.gz" || return
  [[ "$(< "$CK_CASE_DIR/members.txt")" == entry.txt ]] || { ck_note 'Unexpected archive member listing'; return 1; }
  ck_exec "$CK_WORK/out" N "$binary" -xzf "$directory/archive.tar.gz" -C "$directory/restored" || return
  cmp -s "$directory/source/entry.txt" "$directory/restored/entry.txt" || { ck_note 'Archive round-trip changed file contents'; return 1; }
}
ck_tools_sqlite() {
  local binary=''; ck_tool binary sqlite3 || return
  ck_exec "$CK_WORK/out" N "$binary" -batch -bail -init /dev/null "$CK_WORK/blocklog.db" \
    "CREATE TABLE blocklog(slot INTEGER,at TEXT,epoch INTEGER,block INTEGER,slot_in_epoch INTEGER,hash TEXT,size INTEGER,status TEXT); INSERT INTO blocklog VALUES(1,'2026-01-01T00:00:00Z',1,1,1,'dummy',100,'confirmed');" || return
  ck_exec "$CK_CASE_DIR/rows.json" N "$binary" -readonly -batch -bail -init /dev/null -cmd '.timeout 3000' "$CK_WORK/blocklog.db" \
    "PRAGMA trusted_schema=OFF; PRAGMA query_only=ON; BEGIN; SELECT json_group_array(json_object('slot',slot,'status',status)) FROM blocklog; COMMIT;" || return
  ck_assert "$CK_CASE_DIR/rows.json" 'length==1 and .[0].slot==1 and .[0].status=="confirmed"' 'Read-only SQLite JSON query and transaction behavior'
}
ck_suite_tools() {
  ck_run tools-openssl 'OpenSSL — CIP-83 and Ed25519 verification' executed ck_tools_openssl
  ck_run tools-gpg 'GPG — isolated AES-256 encrypt/decrypt and legacy short password' executed ck_tools_gpg
  ck_run tools-address 'Cardano Address — custom CIP-1854 derivation and CLI conversion' executed ck_tools_address
  ck_run tools-signer 'Cardano Signer — Catalyst keygen and Calidus signing/verification' executed ck_tools_signer
  ck_suite_hardware
  ck_run tools-hardware-device 'Device key export, approval and hardware witnesses' integration ck_skip 'Requires a connected hardware wallet and explicit operator approval; not automated.'
  ck_run tools-registry 'Token Registry — create, attest, finalize and validate' executed ck_tools_registry
  ck_run tools-toolbox 'Catalyst Toolbox QR encode command availability' syntax ck_tools_syntax catalyst-toolbox qr-code encode
  ck_run tools-archive 'Tar/gzip — disposable archive round-trip' executed ck_tools_archive
  ck_run tools-sqlite 'SQLite — read-only JSON query' executed ck_tools_sqlite
}
