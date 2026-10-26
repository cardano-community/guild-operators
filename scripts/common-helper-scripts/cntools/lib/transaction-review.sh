#!/usr/bin/env bash
# Adapt the pinned CLI decode to the shared wallet-history detail layout.
# Only decoded body data is authoritative here; input addresses/values are not
# in the body and must not be invented from an imported intent summary.
# shellcheck disable=SC2034

cntools_transaction_review_normalize() {
  cntools_json_exact_integer_strings | jq '
    def metadata_content:
      if type == "array" and length > 0 and
         all(.[]; type == "array" and length == 2 and (.[0]|type)=="string") and
         (map(.[0])|unique|length)==length
      then map({key:.[0],value:(.[1]|metadata_content)}) | from_entries
      elif type == "array" then map(metadata_content)
      elif type == "object" then map_values(metadata_content) else . end;
    def input_record:
      if type == "string" and test("^[0-9a-fA-F]{64}#[0-9]+$") then
        {address:("UTxO · " + .)}
      elif type == "object" then . else {reference:.} end;
    def output_record:
      if type != "object" then {record:.} else
        . as $out | (.amount // {}) as $amount |
        [($amount | to_entries[] | select(.key|test("^policy [0-9a-fA-F]{56}$"))) as $policy |
         $policy.value | to_entries[] |
         select(.key|test("^asset [0-9a-fA-F]*( \\(.*\\))?$")) |
         {policy_id:($policy.key|ltrimstr("policy ")|ascii_downcase),
          asset_name:(.key|capture("^asset (?<hex>[0-9a-fA-F]*)").hex|ascii_downcase),quantity:.value}] as $assets |
        # Keep unrecognized value-map fields: future decode changes must not
        # silently disappear from a signing review.
        ($amount | del(.lovelace) | with_entries(
          if (.key|test("^policy [0-9a-fA-F]{56}$")) and (.value|type)=="object" then
            .value |= with_entries(select(.key|test("^asset [0-9a-fA-F]*( \\(.*\\))?$")|not)) |
            select(.value|length>0)
          else . end)) as $other |
        ($out | del(.amount,.["payment credential key hash"],.["payment credential script hash"])) +
        {value:$amount.lovelace,asset_list:$assets} +
        (if ($other|length)>0 then {"Other output amounts":$other} else {} end)
      end;
    . as $body |
    del(.inputs,.outputs,.["collateral inputs"],.["reference inputs"],
        .["return collateral"],.["validity range"],.metadata,.fee) +
    {fee:($body.fee|if type=="string" then split(" ")[0] else . end),
     invalid_before:$body["validity range"]["lower bound"],
     invalid_after:$body["validity range"]["upper bound"],
     inputs:[$body.inputs[]? | input_record],
     outputs:[$body.outputs[]? | output_record],
     collateral_inputs:[$body["collateral inputs"][]? | input_record],
     reference_inputs:[$body["reference inputs"][]? | input_record],
     collateral_output:($body["return collateral"] | if .==null then null else output_record end),
     metadata:($body.metadata|metadata_content)}
  '
}

cntools_transaction_ui_detail_view() {
  local begin="$1" detail_file='' display_file='' status=0
  local CNTOOLS_DETAIL_METADATA=N CNTOOLS_TABLE_MARGIN=4
  cntools_transaction_temp_file detail_file review-detail || return 2
  cntools_transaction_temp_file display_file review-display || return 2
  cntools_transaction_review_normalize <<< "${CNTOOLS_TRANSACTION_UI_VIEW}" > "${detail_file}" || return 2
  # The pager takes the whole screen, so the explanation goes inside it.
  {
    printf '%s\n\n' 'Decoded transaction body (cardano-cli). Inputs are UTxO references only: their addresses and balances are not in the body.'
    cntools_detail_transaction_render "${detail_file}" 'Overview · decoded transaction body'
  } > "${display_file}" || return 2
  cntools_ui_page_file "${display_file}" || status=$?
  # Closing the viewer returns to the review menu, not out of the action.
  ((status == 0 || status == 1)) || return "${status}"
  return 0
}
