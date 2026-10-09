#!/usr/bin/env bash
# Preserve JSON integer literals before jq parses them. No floating-point
# round trips for metadata, ledger quantities or unknown transaction effects.

cntools_json_exact_integer_strings() {
  LC_ALL=C awk '
    BEGIN { quoted=0; escaped=0 }
    {
      result=""
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (quoted) {
          result=result c
          if (escaped) escaped=0
          else if (c=="\\") escaped=1
          else if (c=="\"") quoted=0
        } else if (c=="\"") { quoted=1; result=result c }
        else if (c ~ /[0-9-]/ && match(substr($0,i), /^-?[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?/)) {
          token=substr($0,i,RLENGTH)
          result=result (token ~ /[.eE]/ ? token : "\"" token "\"")
          i+=RLENGTH-1
        } else result=result c
      }
      print result
    }
    END { if (quoted || escaped) exit 1 }
  '
}


# Compact scalar paths for a readable tree/property table, preserving values.
cntools_json_scalar_records() {
  cntools_json_exact_integer_strings | jq -r '
    def compact: walk(if type=="object" then with_entries(select(.value!=null and .value!=[] and .value!={}))
      elif type=="array" then map(select(.!=null and .!=[] and .!={})) else . end);
    compact | paths(scalars) as $p |
    [($p|map(if type=="number" then .+1|tostring else . end)|join(" / ")),
      (getpath($p)|tostring)] |
    map(gsub("[\u0000-\u001f\u007f]"; " ")) | join("\u001f")'
}
