#!/usr/bin/env bash
# Virtual Handle label-000 datum decoding. No metadata/IPFS/parent redirects.
# Schema: kora-labs-common 6.9.2; lifecycle: handles-personalization d54bc81.
# Expiry is a lease/revocation threshold, NOT an automatic destination change.
# shellcheck disable=SC2034

cntools_handle_virtual_into() {
  local -n hv_address_ref="$1" hv_details_ref="$2"
  local hv_selected="$3" hv_decoded="" hv_hex="" hv_address="" hv_now=""
  hv_address_ref=""; hv_details_ref=""
  printf -v hv_now '%(%s)T' -1
  # Look up exact bytes keys, independent of map order. Reject duplicate keys,
  # missing/ill-typed fields and unknown datum versions instead of guessing.
  hv_decoded="$(jq -ce --argjson now "${hv_now}" '
    def entry($key):
      .map | select(type == "array" and length <= 128) |
      select(all(.[]; (.k | keys) == ["bytes"] and
        (.k.bytes | type == "string" and test("^([0-9a-f]{2})*$")))) |
      select((map(.k.bytes) | unique | length) == length) |
      map(select(.k.bytes == $key)) | select(length == 1) | .[0].v;
    . as $selected |
    select(.datumHash | type == "string" and test("^[0-9a-f]{64}$")) |
    .datum | select(.constructor == 0 and (.fields | type == "array" and length == 3)) |
    select((.fields[0].map | type == "array") and .fields[1] == {int:1}) |
    .fields[2] as $extra |
    ($extra | entry("7265736f6c7665645f616464726573736573") | entry("616461")) as $ada |
    ($extra | entry("7669727475616c")) as $virtual |
    ($virtual | entry("657870697265735f74696d65")) as $expires |
    ($virtual | entry("7075626c69635f6d696e74")) as $public |
    select(($ada | keys) == ["bytes"] and
      ($ada.bytes | type == "string" and length <= 256 and test("^([0-9a-f]{2})+$"))) |
    select(($expires | keys) == ["int"] and
      ($expires.int | type == "number" and . >= 0 and . <= 9007199254740991 and floor == .)) |
    select($public == {int:0} or $public == {int:1}) |
    {addressHex:$ada.bytes, datumHash:$selected.datumHash,
      expiresTimeMs:($expires.int | tostring), publicMint:($public.int == 1),
      leaseStatus:(if $now * 1000 >= $expires.int then "expired" else "unexpired" end)}
    ' <<< "${hv_selected}")" || {
    cntools_handle_fail 'The virtual subhandle has missing, malformed or unsupported inline datum. No holding/parent address was used.'; return 1;
  }
  hv_hex="$(jq -r '.addressHex' <<< "${hv_decoded}")"
  cntools_recipient_from_hex_into hv_address "${hv_hex}" || {
    cntools_handle_fail 'The virtual subhandle datum does not contain a supported payment-key address for this network.'; return 1;
  }
  hv_details_ref="$(jq -c 'del(.addressHex)' <<< "${hv_decoded}")" || return 1
  hv_address_ref="${hv_address}"
}

# Only fields relevant to the reviewed destination/lease. A renewed lease or a
# change of public/private mode requires review again, even if ADA is unchanged.
# Datum hash/UTxO may change merely for personalization; they remain provenance.
cntools_handle_review_state() {
  jq -ce '{type,policy,asset,virtual:(if .virtual then
    (.virtual | {expiresTimeMs,publicMint,leaseStatus}) else null end)}' <<< "$1"
}
