#!/usr/bin/env bash
# Public native-asset inventory and Koios metadata parsing; shared by wallet and funds views.
# shellcheck disable=SC2034

declare -Ag CNTOOLS_WALLET_ASSET_QUANTITIES=()
declare -Ag CNTOOLS_WALLET_ASSET_FINGERPRINTS=()
declare -Ag CNTOOLS_WALLET_ASSET_DECIMALS=()
declare -Ag CNTOOLS_WALLET_ASSET_ASCII_NAMES=()
declare -Ag CNTOOLS_WALLET_ASSET_METADATA_NAMES=()
declare -Ag CNTOOLS_WALLET_ASSET_TICKERS=()
declare -Ag CNTOOLS_WALLET_ASSET_DESCRIPTIONS=()
declare -Ag CNTOOLS_WALLET_ASSET_URLS=()
declare -Ag CNTOOLS_WALLET_ASSET_TOTAL_SUPPLIES=()
declare -Ag CNTOOLS_WALLET_ASSET_METADATA_AVAILABLE=()
declare -Ag CNTOOLS_WALLET_ASSET_METADATA_DECIMALS=()
declare -Ag CNTOOLS_WALLET_ASSET_CLASSES=()
declare -Ag CNTOOLS_WALLET_ASSET_CIP67_LABELS=()
declare -Ag CNTOOLS_WALLET_ASSET_METADATA_SOURCES=()
declare -Ag CNTOOLS_WALLET_ASSET_METADATA_JSON=()
declare -Ag CNTOOLS_WALLET_ASSET_METADATA_QUERIED=()

declare -ag CNTOOLS_WALLET_ASSET_IDS=()

cntools_wallet_asset_sort_ids() {
  local sorted_output=""
  local -a sorted_ids=()

  (( ${#CNTOOLS_WALLET_ASSET_IDS[@]} > 1 )) || return 0
  sorted_output="$(
    printf '%s\n' "${CNTOOLS_WALLET_ASSET_IDS[@]}" | LC_ALL=C sort
  )" || return 1
  mapfile -t sorted_ids <<< "${sorted_output}"
  (( ${#sorted_ids[@]} == ${#CNTOOLS_WALLET_ASSET_IDS[@]} )) || return 1
  CNTOOLS_WALLET_ASSET_IDS=("${sorted_ids[@]}")
}


cntools_wallet_asset_add() {
  local asset_id="${1:-}"
  local quantity="${2:-}"
  local fingerprint="${3:-}"
  local decimals="${4:-}"
  local asset_name=""
  local current=""
  local normalized_quantity=""

  asset_id="${asset_id,,}"
  [[ "${asset_id}" =~ ^[0-9a-f]{56}\.([0-9a-f]{2}){0,32}$ &&
     "${quantity}" =~ ^[0-9]+$ && ${#quantity} -le 80 ]] || return 2
  if [[ -z "${CNTOOLS_WALLET_ASSET_QUANTITIES[${asset_id}]+x}" ]]; then
    CNTOOLS_WALLET_ASSET_IDS+=("${asset_id}")
    [[ "${quantity}" =~ ^0*([1-9][0-9]*|0)$ ]] || return 1
    normalized_quantity="${BASH_REMATCH[1]}"
    CNTOOLS_WALLET_ASSET_QUANTITIES["${asset_id}"]="${normalized_quantity}"
  else
    current="${CNTOOLS_WALLET_ASSET_QUANTITIES[${asset_id}]}"
    cntools_uint_add_into \
      normalized_quantity "${current}" "${quantity}" || return 1
    CNTOOLS_WALLET_ASSET_QUANTITIES["${asset_id}"]="${normalized_quantity}"
  fi
  if [[ -n "${fingerprint}" &&
        "${fingerprint}" =~ ^asset1[023456789acdefghjklmnpqrstuvwxyz]{38}$ ]]; then
    CNTOOLS_WALLET_ASSET_FINGERPRINTS["${asset_id}"]="${fingerprint}"
  fi
  if [[ "${decimals}" =~ ^[0-9]+$ ]]; then
    if (( 10#${decimals} <= 255 )); then
      CNTOOLS_WALLET_ASSET_DECIMALS["${asset_id}"]="$((10#${decimals}))"
    fi
  fi
  asset_name="${asset_id#*.}"
  CNTOOLS_WALLET_ASSET_CLASSES["${asset_id}"]="FT"
  case "${asset_name}" in
    000de140*)
      CNTOOLS_WALLET_ASSET_CIP67_LABELS["${asset_id}"]="222"
      ;;
    0014df10*)
      CNTOOLS_WALLET_ASSET_CIP67_LABELS["${asset_id}"]="333"
      ;;
    001bc280*)
      CNTOOLS_WALLET_ASSET_CIP67_LABELS["${asset_id}"]="444"
      ;;
    *)
      CNTOOLS_WALLET_ASSET_CIP67_LABELS["${asset_id}"]=""
      ;;
  esac
  CNTOOLS_WALLET_ASSET_COUNT="${#CNTOOLS_WALLET_ASSET_IDS[@]}"
}


cntools_wallet_asset_fill_fingerprints() {
  local asset_id=""
  local policy_id=""
  local asset_name=""
  local fingerprint=""
  local failures=0
  local status=0

  for asset_id in "${CNTOOLS_WALLET_ASSET_IDS[@]}"; do
    [[ -z "${CNTOOLS_WALLET_ASSET_FINGERPRINTS[${asset_id}]:-}" ]] ||
      continue
    policy_id="${asset_id%%.*}"
    asset_name="${asset_id#*.}"
    fingerprint=""
    status=0
    if declare -F cntools_wallet_asset_fingerprint_into >/dev/null 2>&1; then
      cntools_wallet_asset_fingerprint_into \
        fingerprint "${policy_id}" "${asset_name}" || status=$?
    elif declare -F cntools_wallet_asset_fingerprint >/dev/null 2>&1; then
      fingerprint="$(cntools_wallet_asset_fingerprint \
        "${policy_id}" "${asset_name}" 2>/dev/null || true)"
      [[ -n "${fingerprint}" ]] || status=1
    else
      # Koios normally supplies fingerprints itself. Missing local helper
      # support must not turn an otherwise valid balance query into a failure.
      return 0
    fi
    if (( status == 0 )) &&
       [[ "${fingerprint}" =~ ^asset1[023456789acdefghjklmnpqrstuvwxyz]{38}$ ]]; then
      CNTOOLS_WALLET_ASSET_FINGERPRINTS["${asset_id}"]="${fingerprint}"
    else
      failures=$((failures + 1))
    fi
  done
  if (( failures > 0 )); then
    cntools_wallet_log WARN \
      "Could not derive ${failures} native-asset fingerprint(s)"
  fi
  return 0
}


cntools_wallet_query_koios_asset_payload() {
  local _cntools_output_name="${1:-}"
  local _cntools_payload=""
  local _cntools_asset_id=""

  shift || return 2
  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && $# -gt 0 ]] ||
    return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  for _cntools_asset_id in "$@"; do
    [[ "${_cntools_asset_id}" =~ ^[0-9a-f]{56}\.([0-9a-f]{2}){0,32}$ ]] ||
      return 2
  done
  _cntools_payload="$(
    for _cntools_asset_id in "$@"; do
      printf '%s\t%s\n' \
        "${_cntools_asset_id%%.*}" "${_cntools_asset_id#*.}"
    done | jq -Rsc '
      split("\n")
      | map(select(length > 0) | split("\t"))
      | {_asset_list: .}
    '
  )" || return 1
  _cntools_output_ref="${_cntools_payload}"
}


cntools_wallet_query_koios_asset_payload_limit() {
  if [[ -n "${CNTOOLS_KOIOS_TOKEN:-}" ]]; then
    printf '%s\n' "${CNTOOLS_WALLET_KOIOS_AUTH_PAYLOAD_MAX_BYTES}"
  else
    printf '%s\n' "${CNTOOLS_WALLET_KOIOS_PAYLOAD_MAX_BYTES}"
  fi
}


cntools_wallet_query_koios_asset_pace() {
  local completed_batches="${1:-0}"

  [[ "${completed_batches}" =~ ^[0-9]+$ ]] || return 2
  (( completed_batches > 0 &&
     completed_batches % CNTOOLS_WALLET_KOIOS_RATE_BATCHES == 0 )) || return 0
  cntools_wallet_log API \
    "Koios asset_info rate window reached; pausing metadata batches"
  sleep "${CNTOOLS_WALLET_KOIOS_RATE_PAUSE_SECONDS}"
}


cntools_wallet_query_koios_asset_metadata_batch() {
  local response_file=""
  local payload=""
  local requested=""
  local records=""
  local policy_id=""
  local asset_name=""
  local asset_id=""
  local ascii_name=""
  local fingerprint=""
  local total_supply=""
  local metadata_name=""
  local ticker=""
  local decimals=""
  local description=""
  local url=""
  local asset_class=""
  local cip67_label=""
  local metadata_source=""
  local metadata_json=""

  (( $# > 0 )) || return 2
  cntools_wallet_query_temp_file response_file || return 1
  cntools_wallet_query_koios_asset_payload payload "$@" || return 1
  requested="$(jq -c '
    [._asset_list[] | ((.[0] + "." + .[1]) | ascii_downcase)]
  ' <<< "${payload}")" || return 1
  if ! cntools_asset_details_fetch "${response_file}" "$@"; then
    cntools_wallet_log ERROR "Koios asset_info request failed"
    return 1
  fi
  cntools_asset_response_valid "${response_file}" "${requested}" || {
    cntools_wallet_log ERROR "Koios asset_info returned invalid JSON"
    return 1
  }
  records="$(jq -r '
    def clean($maximum):
      if . == null then ""
      else tostring
        | gsub("[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]"; " ")
        | gsub("^[ ]+|[ ]+$"; "")
        | if length > $maximum
          then .[0:($maximum - 1)] + "…"
          else .
          end
      end;
    def human_ascii:
      if . == null or type != "string" or
         test("[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]") or
         test("\\\\[0-7]{3}")
      then ""
      else clean(80)
        | if test("^[ -~]+$") then . else "" end
      end;
    def text_value:
      if type == "string" then . else null end;
    def decimal_value:
      if type == "number" and floor == . and . >= 0 and . <= 255
      then tostring
      elif type == "string" and test("^[0-9]{1,3}$") and
           (tonumber >= 0 and tonumber <= 255)
      then (tonumber | tostring)
      else null
      end;
    def hex_nibble:
      . as $character
      | ("0123456789abcdef" | index($character));
    def hex_bytes:
      ascii_downcase as $hex
      | if ($hex | type) != "string" or
           ($hex | length) > 8192 or
           (($hex | length) % 2) != 0 or
           ($hex | test("^[0-9a-f]*$") | not)
        then null
        else [range(0; ($hex | length); 2) as $index
          | (($hex[$index:$index + 1] | hex_nibble) * 16) +
            ($hex[$index + 1:$index + 2] | hex_nibble)]
        end;
    def utf8_codepoints($bytes; $index; $result):
      if $bytes == null then null
      elif $index == ($bytes | length) then $result
      elif $index > ($bytes | length) then null
      else $bytes[$index] as $first
        | if $first <= 127 then
            utf8_codepoints($bytes; $index + 1; $result + [$first])
          elif $first >= 194 and $first <= 223 and
               ($index + 1) < ($bytes | length) and
               $bytes[$index + 1] >= 128 and
               $bytes[$index + 1] <= 191 then
            utf8_codepoints($bytes; $index + 2;
              $result + [($first - 192) * 64 +
                         ($bytes[$index + 1] - 128)])
          elif $first >= 224 and $first <= 239 and
               ($index + 2) < ($bytes | length) and
               $bytes[$index + 1] >=
                 (if $first == 224 then 160 else 128 end) and
               $bytes[$index + 1] <=
                 (if $first == 237 then 159 else 191 end) and
               $bytes[$index + 2] >= 128 and
               $bytes[$index + 2] <= 191 then
            utf8_codepoints($bytes; $index + 3;
              $result + [($first - 224) * 4096 +
                         ($bytes[$index + 1] - 128) * 64 +
                         ($bytes[$index + 2] - 128)])
          elif $first >= 240 and $first <= 244 and
               ($index + 3) < ($bytes | length) and
               $bytes[$index + 1] >=
                 (if $first == 240 then 144 else 128 end) and
               $bytes[$index + 1] <=
                 (if $first == 244 then 143 else 191 end) and
               $bytes[$index + 2] >= 128 and
               $bytes[$index + 2] <= 191 and
               $bytes[$index + 3] >= 128 and
               $bytes[$index + 3] <= 191 then
            utf8_codepoints($bytes; $index + 4;
              $result + [($first - 240) * 262144 +
                         ($bytes[$index + 1] - 128) * 4096 +
                         ($bytes[$index + 2] - 128) * 64 +
                         ($bytes[$index + 3] - 128)])
          else null
          end
      end;
    def hex_text:
      hex_bytes as $bytes
      | utf8_codepoints($bytes; 0; []) as $codepoints
      | if $codepoints == null then null else ($codepoints | implode) end;
    def ci_get($object; $key):
      ($key | ascii_downcase) as $needle
      | if ($object | type) != "object" then null
        else ($object[$key] //
          ([$object | to_entries[]
            | select((.key | ascii_downcase) == $needle)
            | .value][0] // null))
        end;
    def asset_text($asset_name):
      ($asset_name | hex_text) as $decoded
      | if $decoded == null or
           ($decoded | test("[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]"))
        then null
        else $decoded
        end;
    def mint_metadata($row; $container):
      ci_get(($container // {}); $row.policy_id) as $policy
      | asset_text(($row.asset_name // "")) as $asset_text
      | (ci_get($policy; ($row.asset_name // "")) //
         (if $asset_text == null then null
          elif ($policy | type) == "object" then $policy[$asset_text]
          else null
          end)) as $metadata
      | if ($metadata | type) == "object" then $metadata else {} end;
    def plutus_map_value($map; $key):
      if ($map | type) != "object" or ($map.map | type) != "array"
      then null
      else [$map.map[]
        | select((.k | type) == "object" and
                 (.k.bytes | type) == "string" and
                 ((.k.bytes | ascii_downcase) == ($key | ascii_downcase)))
        | .v]
        | if length == 1 then .[0] else null end
      end;
    def plutus_key:
      if type != "object" then null
      elif (.bytes | type) == "string" then
        (.bytes | ascii_downcase) as $hex
        | if ($hex | length) == 0 then null
          elif ($hex | length) > 128 then "[byte key omitted]"
          else ($hex | hex_text) as $decoded
            | if $decoded == null or $decoded == "" then
                if ($hex | test("^([0-9a-f]{2})+$"))
                then "0x" + $hex
                else "[byte key omitted]"
                end
              elif ($decoded | length) > 64
              then $decoded[0:63] + "…"
              else $decoded
              end
          end
      elif (.int | type) == "number" then
        (.int | tostring) as $integer
        | if ($integer | length) > 64
          then "[integer key omitted]"
          else $integer
          end
      else null
      end;
    def unique_key($object; $base; $suffix):
      ($base +
        (if $suffix == 0 then ""
         else " [" + (($suffix + 1) | tostring) + "]"
         end)) as $candidate
      | if ($object | has($candidate))
        then unique_key($object; $base; $suffix + 1)
        else $candidate
        end;
    def plutus_value($depth):
      if type != "object" then null
      elif (.bytes | type) == "string" then
        (.bytes | ascii_downcase) as $hex
        | if ($hex | length) > 640 then "[byte string omitted]"
          else ($hex | hex_text) as $decoded
            | if $decoded == null then
                if ($hex | test("^([0-9a-f]{2})+$"))
                then "0x" + $hex
                else "[byte string omitted]"
                end
              else $decoded
              end
          end
      elif (.int | type) == "number" then
        (.int | tostring) as $integer
        | if ($integer | length) > 320
          then "[number omitted]"
          else .int
          end
      elif $depth >= 6 then "[nested data omitted]"
      elif (.list | type) == "array" then
        .list as $items
        | (if ($items | length) > 32 then 31 else 32 end) as $limit
        | ([$items[0:$limit][] | plutus_value($depth + 1)] +
           (if ($items | length) > 32 then
              ["[" + ((($items | length) - $limit) | tostring) +
               " items omitted]"]
            else [] end))
      elif (.map | type) == "array" then
        .map as $items
        | (if ($items | length) > 48 then 47 else 48 end) as $limit
        | (reduce $items[0:$limit][] as $entry ({};
          ($entry.k | plutus_key) as $key
          | if $key == null or ($key | length) == 0 then .
            else unique_key(.; $key; 0) as $unique
              | .[$unique] = ($entry.v | plutus_value($depth + 1))
            end)) as $decoded
        | if ($items | length) > 48 then
            unique_key($decoded; "[More metadata]"; 0) as $marker
            | $decoded + {
                ($marker):
                  (((($items | length) - $limit) | tostring) +
                   " fields omitted")
              }
          else $decoded
          end
      elif (.fields | type) == "array" then
        .fields as $items
        | (if ($items | length) > 32 then 31 else 32 end) as $limit
        | ([$items[0:$limit][] | plutus_value($depth + 1)] +
           (if ($items | length) > 32 then
              ["[" + ((($items | length) - $limit) | tostring) +
               " fields omitted]"]
            else [] end))
      else null
      end;
    def cip68_map($row; $label):
      (($row.cip68_metadata // {})[$label] // null) as $datum
      | if ($datum | type) != "object" or
           $datum.constructor != 0 or
           ($datum.fields | type) != "array" or
           ($datum.fields | length) < 1 or
           ($datum.fields[0].map | type) != "array"
        then null
        else $datum.fields[0] as $direct
          | plutus_map_value($direct; "373231") as $nested
          | if ($nested.map | type) != "array" then $direct
            else ([$nested.map[]
                    | select((.k.bytes | type) == "string" and
                             (.k.bytes | test("^[0-9a-fA-F]{56}$")) and
                             (.v.map | type) == "array")]
                  | length > 0) as $wrapper_shaped
              | if ($wrapper_shaped | not) then $direct
                else plutus_map_value($nested; $row.policy_id) as $policy
                  | plutus_map_value($policy;
                      (($row.asset_name // "")[8:])) as $metadata
                  | if ($metadata.map | type) == "array"
                    then $metadata
                    else null
                    end
                end
            end
        end;
    def cip68_metadata($row; $label):
      cip68_map($row; $label) as $metadata
      | if $metadata == null then {} else ($metadata | plutus_value(0)) end;
    # CIP-67 prefixes for CIP-68 user-token labels 222, 333, and 444.
    def cip67_label($row):
      ($row.asset_name // "" | ascii_downcase) as $asset_name
      | if ($asset_name | startswith("000de140")) then "222"
        elif ($asset_name | startswith("0014df10")) then "333"
        elif ($asset_name | startswith("001bc280")) then "444"
        else ""
        end;
    def asset_class($total_supply):
      if $total_supply == "1" then "NFT" else "FT" end;
    def meaningful:
      if . == null then false
      elif type == "string" then length > 0
      elif type == "array" or type == "object" then length > 0
      else true
      end;
    def document_has_value:
      [.. | select(
        (type == "string" and length > 0) or
        type == "number" or type == "boolean")]
      | length > 0;
    def metadata_sources($label; $registry; $cip68; $mint20; $mint721):
      if $label == "222" then
          [
            {source:"CIP-68 (222)", document:$cip68},
            {source:"CIP-25 (721)", document:$mint721}
          ]
        elif $label == "333" then
          [
            {source:"CIP-68 (333)", document:$cip68},
            {source:"CIP-X (label 20)", document:$mint20},
            {source:"Token Registry", document:$registry}
          ]
        elif $label == "444" then
          [
            {source:"CIP-68 (444)", document:$cip68},
            {source:"Token Registry", document:$registry}
          ]
        else
          [
            {source:"CIP-X (label 20)", document:$mint20},
            {source:"Token Registry", document:$registry},
            {source:"CIP-25 (721)", document:$mint721}
          ]
        end;
    def selected_metadata($sources):
      [$sources[]
        | select((.document | type) == "object" and
                 (.document | document_has_value))][0] //
      {source:"", document:{}};
    def safe_string($maximum):
      tostring
      | gsub("[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]"; " ")
      | gsub("^[ ]+|[ ]+$"; "")
      | if startswith("data:") and length > 160
        then .[0:96] + "… [embedded data truncated]"
        elif length > $maximum
        then .[0:($maximum - 1)] + "…"
        else .
        end;
    def safe_key:
      tostring | safe_string(64);
    def chunk_field($key):
      ($key | ascii_downcase) as $normalized
      | $normalized == "image" or
        $normalized == "src" or
        $normalized == "description" or
        $normalized == "url" or
        $normalized == "website" or
        $normalized == "proposal_url";
    def safe_document($depth; $parent_key; $strip_nft_units):
      if . == null then null
      elif type == "string" then safe_string(320)
      elif type == "number" then
        (tostring) as $number
        | if ($number | length) > 320
          then "[number omitted]"
          else .
          end
      elif type == "boolean" then .
      elif $depth >= 6 then "[nested data omitted]"
      elif type == "array" then
        . as $items
        | if ($items | length) <= 32 and
             chunk_field($parent_key) and
             all($items[]; type == "string")
          then ($items | join("") | safe_string(320))
          else
            (if ($items | length) > 32 then 31 else 32 end) as $limit
            | ([$items[0:$limit][] |
                safe_document($depth + 1; ""; $strip_nft_units)]
             | map(select(meaningful))) +
            (if ($items | length) > 32 then
               ["[" + ((($items | length) - $limit) | tostring) +
                " items omitted]"]
             else [] end)
          end
      elif type == "object" then
        . as $object
        | (if ($object | length) > 48 then 47 else 48 end) as $limit
        | (reduce ($object | to_entries[0:$limit][]) as $entry ({};
            ($entry.key | safe_key) as $base
            | ($entry.key | ascii_downcase) as $normalized_key
            | ($entry.value |
               safe_document($depth + 1; $entry.key; $strip_nft_units)) as $value
            | if ($strip_nft_units and
                  ($normalized_key == "ticker" or
                   $normalized_key == "decimals")) or
                 ($base | length) == 0 or ($value | meaningful | not)
              then .
              else unique_key(.; $base; 0) as $key
                | .[$key] = $value
              end)) as $safe
        | if ($object | length) > 48 then
            unique_key($safe; "[More metadata]"; 0) as $marker
            | $safe + {
                ($marker):
                  (((($object | length) - $limit) | tostring) +
                   " fields omitted")
              }
          else $safe
          end
      else null
      end;
    def pretty_key:
      gsub("_"; " ")
      | if length == 0 then "Field"
        else (.[0:1] | ascii_upcase) + .[1:]
        end;
    def tree_rows($value; $prefix; $depth):
      if $depth >= 6 then
        [{property:($prefix + "└─ More"), value:"[nested data omitted]"}]
      elif ($value | type) == "object" then
        ($value | to_entries) as $items
        | [range(0; ($items | length)) as $index
          | $items[$index] as $item
          | ($index == (($items | length) - 1)) as $last
          | ($prefix + (if $last then "└─ " else "├─ " end) +
             ($item.key | pretty_key)) as $property
          | ($prefix + (if $last then "   " else "│  " end)) as $next
          | if ($item.value | type) == "object" or
               (($item.value | type) == "array")
            then [{property:$property,value:""}] +
                 tree_rows($item.value; $next; $depth + 1)
            else [{property:$property,value:($item.value | tostring)}]
            end] | add // []
      elif ($value | type) == "array" then
        [range(0; ($value | length)) as $index
          | ($index == (($value | length) - 1)) as $last
          | ($prefix + (if $last then "└─ " else "├─ " end) +
             "Item " + (($index + 1) | tostring)) as $property
          | ($prefix + (if $last then "   " else "│  " end)) as $next
          | if ($value[$index] | type) == "object" or
               (($value[$index] | type) == "array")
            then [{property:$property,value:""}] +
                 tree_rows($value[$index]; $next; $depth + 1)
            else [{property:$property,value:($value[$index] | tostring)}]
            end] | add // []
      else []
      end;
    .[] as $row
    | (($row.registry_metadata // $row.token_registry_metadata // {
        name:$row.metadata_name,
        ticker:$row.metadata_ticker,
        decimals:$row.metadata_decimals,
        description:$row.metadata_description,
        url:$row.metadata_url
      }) | if type == "object" then . else {} end) as $registry
    | cip67_label($row) as $label
    | cip68_metadata($row; $label) as $cip68
    | mint_metadata($row; $row.metadata_20) as $mint20
    | mint_metadata($row; $row.metadata_721) as $mint721
    | metadata_sources($label; $registry; $cip68; $mint20; $mint721) as $sources
    | selected_metadata($sources) as $selected
    | ($selected.document
       | safe_document(0; ""; ($row.total_supply == "1"))) as $display_document
    | (ci_get($display_document; "name") | text_value | clean(80)) as $name
    | (if $row.total_supply == "1" then ""
       else (ci_get($display_document; "ticker") | text_value | clean(32))
       end) as $ticker
    | (if $row.total_supply == "1" then ""
       else (ci_get($display_document; "decimals") | decimal_value) // ""
       end) as $decimals
    | ((ci_get($display_document; "description") //
        ci_get($display_document; "desc")) | text_value | clean(160)) as $description
    | ((ci_get($display_document; "url") //
        ci_get($display_document; "website")) | text_value | clean(160)) as $url
    | tree_rows($display_document; ""; 0) as $all_details
    | (if ($all_details | length) > 96 then
         ($all_details[0:95] + [{
           property:"└─ More metadata",
           value:(((($all_details | length) - 95) | tostring) +
                  " rows omitted")
         }])
       else $all_details end | tojson) as $details
    | [
      $row.policy_id,
      ($row.asset_name // ""),
      ($row.asset_name_ascii | human_ascii),
      $row.fingerprint,
      $row.total_supply,
      asset_class($row.total_supply),
      $label,
      $selected.source,
      $name,
      $ticker,
      $decimals,
      $description,
      $url,
      $details
    ] | join("\u001f")
  ' "${response_file}" 2>/dev/null)" || return 1
  while IFS=$'\037' read -r \
      policy_id asset_name ascii_name fingerprint total_supply \
      asset_class cip67_label metadata_source metadata_name ticker \
      decimals description url metadata_json; do
    [[ -n "${policy_id}" ]] || continue
    asset_id="${policy_id,,}.${asset_name,,}"
    [[ -n "${CNTOOLS_WALLET_ASSET_QUANTITIES[${asset_id}]+x}" ]] ||
      return 1
    CNTOOLS_WALLET_ASSET_METADATA_QUERIED["${asset_id}"]=1
    CNTOOLS_WALLET_ASSET_ASCII_NAMES["${asset_id}"]="${ascii_name}"
    if [[ "${CNTOOLS_MODE:-}" != "local" &&
          -z "${CNTOOLS_WALLET_ASSET_FINGERPRINTS[${asset_id}]:-}" ]]; then
      CNTOOLS_WALLET_ASSET_FINGERPRINTS["${asset_id}"]="${fingerprint}"
    elif [[ -n "${CNTOOLS_WALLET_ASSET_FINGERPRINTS[${asset_id}]:-}" &&
            "${CNTOOLS_WALLET_ASSET_FINGERPRINTS[${asset_id}]}" != "${fingerprint}" ]]; then
      cntools_wallet_log WARN \
        "Ignoring mismatched Koios fingerprint for asset=${asset_id}"
    fi
    CNTOOLS_WALLET_ASSET_TOTAL_SUPPLIES["${asset_id}"]="${total_supply}"
    CNTOOLS_WALLET_ASSET_CLASSES["${asset_id}"]="${asset_class}"
    CNTOOLS_WALLET_ASSET_CIP67_LABELS["${asset_id}"]="${cip67_label}"
    CNTOOLS_WALLET_ASSET_METADATA_SOURCES["${asset_id}"]="${metadata_source}"
    CNTOOLS_WALLET_ASSET_METADATA_JSON["${asset_id}"]="${metadata_json}"
    CNTOOLS_WALLET_ASSET_METADATA_NAMES["${asset_id}"]="${metadata_name}"
    CNTOOLS_WALLET_ASSET_TICKERS["${asset_id}"]="${ticker}"
    CNTOOLS_WALLET_ASSET_DESCRIPTIONS["${asset_id}"]="${description}"
    CNTOOLS_WALLET_ASSET_URLS["${asset_id}"]="${url}"
    if [[ -n "${metadata_source}" ]]; then
      CNTOOLS_WALLET_ASSET_METADATA_AVAILABLE["${asset_id}"]=1
    fi
    if [[ "${decimals}" =~ ^[0-9]+$ ]]; then
      if (( 10#${decimals} <= 255 )); then
        CNTOOLS_WALLET_ASSET_METADATA_DECIMALS["${asset_id}"]="$((10#${decimals}))"
      fi
    fi
  done <<< "${records}"
}


cntools_wallet_query_koios_asset_metadata() {
  local asset_id=""
  local payload=""
  local total_batches=0
  local successful_batches=0
  local payload_limit=0
  local -a batch=()
  local -a candidate=()

  CNTOOLS_WALLET_ASSET_ASCII_NAMES=()
  CNTOOLS_WALLET_ASSET_METADATA_NAMES=()
  CNTOOLS_WALLET_ASSET_TICKERS=()
  CNTOOLS_WALLET_ASSET_DESCRIPTIONS=()
  CNTOOLS_WALLET_ASSET_URLS=()
  CNTOOLS_WALLET_ASSET_TOTAL_SUPPLIES=()
  CNTOOLS_WALLET_ASSET_METADATA_AVAILABLE=()
  CNTOOLS_WALLET_ASSET_METADATA_DECIMALS=()
  CNTOOLS_WALLET_ASSET_METADATA_SOURCES=()
  CNTOOLS_WALLET_ASSET_METADATA_JSON=()
  CNTOOLS_WALLET_ASSET_METADATA_QUERIED=()
  if [[ "${CNTOOLS_KOIOS_ENABLED:-Y}" != "Y" ]]; then
    CNTOOLS_WALLET_ASSET_METADATA_STATUS="not-requested"
    cntools_wallet_log WALLET \
      "Koios token metadata skipped because ENABLE_KOIOS=N"
    return 0
  fi
  if (( ${#CNTOOLS_WALLET_ASSET_IDS[@]} == 0 )); then
    CNTOOLS_WALLET_ASSET_METADATA_STATUS="empty"
    return 0
  fi
  CNTOOLS_WALLET_ASSET_METADATA_STATUS="unavailable"
  payload_limit="$(cntools_wallet_query_koios_asset_payload_limit)" || return 1
  [[ "${payload_limit}" =~ ^[1-9][0-9]*$ ]] || return 1
  for asset_id in "${CNTOOLS_WALLET_ASSET_IDS[@]}"; do
    candidate=("${batch[@]}" "${asset_id}")
    cntools_wallet_query_koios_asset_payload payload \
      "${candidate[@]}" || return 1
    if (( ${#payload} > payload_limit &&
          ${#batch[@]} > 0 )); then
      cntools_wallet_query_koios_asset_pace "${total_batches}" || return 1
      total_batches=$((total_batches + 1))
      if cntools_wallet_query_koios_asset_metadata_batch "${batch[@]}"; then
        successful_batches=$((successful_batches + 1))
      fi
      batch=("${asset_id}")
    else
      batch=("${candidate[@]}")
    fi
  done
  if (( ${#batch[@]} > 0 )); then
    cntools_wallet_query_koios_asset_pace "${total_batches}" || return 1
    total_batches=$((total_batches + 1))
    if cntools_wallet_query_koios_asset_metadata_batch "${batch[@]}"; then
      successful_batches=$((successful_batches + 1))
    fi
  fi
  if (( successful_batches == total_batches )); then
    CNTOOLS_WALLET_ASSET_METADATA_STATUS="available"
    return 0
  elif (( successful_batches > 0 )); then
    CNTOOLS_WALLET_ASSET_METADATA_STATUS="partial"
  else
    CNTOOLS_WALLET_ASSET_METADATA_STATUS="unavailable"
  fi
  return 1
}
