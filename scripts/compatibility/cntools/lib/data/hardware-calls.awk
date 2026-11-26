# Inventory literal HW CLI calls, their continuation lines and witness array
# additions. This reads source, never evaluates it. Unmapped commands fail in
# hardware.sh rather than being invoked against an attached device.
function collect(line, flag) {
  if (line ~ /\$\{network(_arguments)?\[@\]\}/) network[row] = 1
  while (match(line, /--[a-z][a-z0-9-]*/)) {
    flag = substr(line, RSTART, RLENGTH)
    flags[row] = flags[row] " " flag
    line = substr(line, RSTART + RLENGTH)
  }
}
function continuation(line) {
  return array ? line !~ /\)[ \t]*$/ : line ~ /\\[ \t]*$/
}
FNR == 1 { fn = ""; active = 0; witness = 0; previous = "" }
/^[a-zA-Z_][a-zA-Z0-9_]*\(\)[ \t]*\{/ {
  fn = $1; sub(/\(\)/, "", fn); witness = 0
}
fn == "cntools_transaction_network_arguments_into" {
  network_source = network_source " " $0
}
{
  if (match($0, /"\$\{CNTOOLS_(TRANSACTION_HWCLI|WALLET_HARDWARE_BIN)\}"[ \t]+[a-z]/)) {
    tail = substr($0, RSTART)
    sub(/^"[^\"]*"[ \t]+/, "", tail)
    split(tail, words, /[ \t]+/)
    sub(/[^a-z0-9-].*$/, "", words[2])
    row++; command[row] = words[1] " " words[2]
    location[row] = FILENAME ":" FNR
    array = $0 ~ /(command|hw_command)=\(/ || previous ~ /command=\([ \t]*$/
    collect(tail)
    active = continuation($0)
    witness = command[row] == "transaction witness"
  } else if (active) {
    collect($0); active = continuation($0)
  } else if (witness && $0 ~ /command\+=\(/) {
    array = 1; collect($0); active = continuation($0)
  }
  previous = $0
}
END {
  # Network selectors are appended indirectly by the shared production helper.
  for (i = 1; i <= row; i++) {
    if (network[i]) {
      rest = network_source
      while (match(rest, /--[a-z][a-z0-9-]*/)) {
        flags[i] = flags[i] " " substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
    printf "%s\t%s\t%s\n", location[i], command[i], flags[i]
  }
  if (row == 0) exit 1
}
