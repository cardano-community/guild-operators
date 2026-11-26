#!/usr/bin/env bash
# CNTools pickers say what the chosen thing is for: every wallet, pool,
# policy, asset and file picker call passes a purpose, and the purpose is drawn
# above the list (Gum's --header) without pushing the list off screen.
set -o pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  printf 'cntools picker tests skipped: Bash 5+ required\n'
  exit 0
fi
command -v python3 >/dev/null 2>&1 || { printf 'cntools picker tests skipped: python3 is not installed\n'; exit 0; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CNTOOLS_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
failures=0
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; }

# ── every call names a purpose ───────────────────────────────────────────────
problems="$(CNTOOLS_DIR="${CNTOOLS_SOURCE}" python3 -I - <<'PY'
import glob, os, re, shlex
root = os.environ["CNTOOLS_DIR"]
files = sorted(glob.glob(f"{root}/core/*.sh") + glob.glob(f"{root}/lib/*.sh") +
               glob.glob(f"{root}/modules/root/**/action.sh", recursive=True))
# picker -> index of its purpose argument (after the function name)
pickers = {
    "cntools_wallet_choose": 1, "cntools_pool_choose_into": 1,
    "cntools_ui_choose_for": 1, "cntools_shortcuts_pick_entry_into": 1,
    "cntools_policy_selection_into": 2, "cntools_policy_choose_into": 2,
    "cntools_policy_asset_choose_into": 2, "cntools_governance_wallet_select_into": 2,
}
# Labels that only say what kind of thing is listed, never what it is for.
generic = re.compile(r"^(Filter (wallets|pools|policies|assets)…|Select pool|Policy|Asset|Wallet|"
                     r"Select governance proposal|Local stake pool|Choose a transaction file)$")
out = []
for path in files:
    lines = open(path, errors="replace").read().split("\n")
    i = 0
    while i < len(lines):
        number, text = i + 1, lines[i]
        while text.rstrip().endswith("\\") and i + 1 < len(lines):
            i += 1; text = text.rstrip()[:-1] + " " + lines[i].strip()
        i += 1
        if re.match(r"^\s*#", text):
            continue
        for name, position in pickers.items():
            for match in re.finditer(r"\b" + name + r"\b(?!\(\))", text):
                rest = text[match.end():]
                if rest.startswith("()") or rest.startswith(" <") or rest.startswith(":"):
                    continue
                rest = re.split(r"\|\||&&|;|\bthen\b", rest)[0]
                try:
                    words = shlex.split(rest, posix=True)
                except ValueError:
                    words = rest.split()
                if len(words) <= position or not words[position].strip():
                    out.append(f"{os.path.relpath(path, root)}:{number} {name} has no purpose")
        for match in re.finditer(r"\bcntools_ui_choose\s+\S+\s+('([^']*)'|\"([^\"]*)\")", text):
            label = match.group(2) if match.group(2) is not None else match.group(3)
            if generic.match(label):
                out.append(f"{os.path.relpath(path, root)}:{number} picker labelled only '{label}'")
print("\n".join(out))
PY
)"
assert_eq "${problems}" "" "picker calls without a purpose"

# ── the purpose reaches Gum ──────────────────────────────────────────────────
# shellcheck source=/dev/null
for library in number filesystem; do . "${CNTOOLS_SOURCE}/lib/${library}.sh" || exit 1; done
# shellcheck source=/dev/null
for core in log gum; do . "${CNTOOLS_SOURCE}/core/${core}.sh" || exit 1; done
# shellcheck source=/dev/null
. "${CNTOOLS_SOURCE}/lib/wallet.sh" || exit 1
cntools_log() { :; }
cntools_gum_log() { :; }
cntools_wallet_log() { :; }
cntools_gum_width() { printf '%s\n' "${WIDTH:-80}"; }
cntools_gum_header_rows() { printf '5\n'; }
cntools_gum_terminal_lines() { printf '%s\n' "${LINES_ON_SCREEN:-40}"; }
# Records the filter arguments (it runs in a command substitution, so in a
# file) and picks the row that contains PICK.
ARGS_FILE="$(mktemp "${TMPDIR:-/tmp}/guild-cntools-pickers.XXXXXX")"
trap 'rm -f "${ARGS_FILE}"' EXIT
cntools_gum() {
  local row=""
  printf '%s\0' "$@" > "${ARGS_FILE}"
  while IFS= read -r row; do
    [[ "${row}" != *"${PICK:-}"* ]] || { printf '%s\n' "${row}"; return 0; }
  done
  return 1
}
gum_args() { mapfile -d '' -t GUM_ARGS < "${ARGS_FILE}"; }
arg_after() { local i; gum_args; for (( i = 0; i < ${#GUM_ARGS[@]} - 1; i++ )); do [[ "${GUM_ARGS[i]}" != "$1" ]] || { printf '%s' "${GUM_ARGS[i+1]}"; return 0; }; done; return 1; }
has_arg() { local a; gum_args; for a in "${GUM_ARGS[@]}"; do [[ "${a}" != "$1" ]] || return 0; done; return 1; }

chosen='' index=''
PICK=b cntools_ui_choose_for chosen 'Wallet that pays the transaction fee' 'Filter wallets…' a b c
assert_eq "${chosen}" "b" "chosen row"
assert_eq "$(arg_after --header)" "Wallet that pays the transaction fee" "purpose is the header"
assert_eq "$(arg_after --placeholder)" "Filter wallets…" "placeholder stays a filter hint"
has_arg --header.bold || fail "the purpose is bold"
with_header="$(arg_after --height)"
PICK=b cntools_ui_choose chosen 'Filter wallets…' a b c
has_arg --header && fail "a plain chooser has no header"
assert_eq "$(( with_header - $(arg_after --height) ))" "1" "a one-line purpose adds its row to the widget"
cntools_ui_choose_for chosen '' 'Filter…' a b; assert_eq "$?" "2" "a picker without a purpose is refused"

# A short screen: the purpose takes a list row, never a row below the screen.
mapfile -t many < <(seq -f 'row %g' 1 60)
LINES_ON_SCREEN=20 PICK='row 1' cntools_ui_choose chosen 'Filter…' "${many[@]}"
plain="$(arg_after --height)"
LINES_ON_SCREEN=20 PICK='row 1' cntools_ui_choose_for chosen 'Pool to show' 'Filter…' "${many[@]}"
assert_eq "$(arg_after --height)" "${plain}" "on a full screen the widget keeps its size"

# A long purpose is wrapped inside the padding and every line is counted.
long='Wallet whose stake address to de-register · it pays the fee and gets the deposit back'
WIDTH=40 PICK=b cntools_ui_choose_for chosen "${long}" 'Filter wallets…' a b c
header="$(arg_after --header)"
rows="$(printf '%s\n' "${header}" | wc -l)"; rows="${rows//[[:space:]]/}"
(( rows > 1 )) || fail "a long purpose is wrapped: '${header}'"
while IFS= read -r line; do (( ${#line} <= 36 )) || fail "wrapped line wider than the widget: '${line}'"; done <<< "${header}"
WIDTH=40 PICK=b cntools_ui_choose chosen 'Filter wallets…' a b c
plain="$(arg_after --height)"
WIDTH=40 PICK=b cntools_ui_choose_for chosen "${long}" 'Filter wallets…' a b c
assert_eq "$(( $(arg_after --height) - plain ))" "${rows}" "every wrapped line is counted"

# The wallet picker shows its purpose, and asks for one.
CNTOOLS_WALLET_NAMES=(alpha beta) CNTOOLS_WALLET_PATHS=(/w/alpha /w/beta)
CNTOOLS_WALLET_TYPES=(CLI CLI) CNTOOLS_WALLET_PROTECTIONS=(Open Open)
PICK=beta cntools_wallet_choose index 'Wallet that pays the transaction fee for this pool update' Cancel
assert_eq "${index}:$(arg_after --header)" "1:Wallet that pays the transaction fee for this pool update" "wallet picker purpose"
cntools_wallet_choose index '' Cancel; assert_eq "$?" "2" "a wallet picker without a purpose is refused"

if (( failures > 0 )); then
  printf '%s cntools picker check(s) failed\n' "${failures}" >&2
  exit 1
fi
printf 'cntools picker tests passed\n'
