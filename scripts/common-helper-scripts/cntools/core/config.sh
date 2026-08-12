#!/usr/bin/env bash
# CNTools configuration parsing and legacy-header migration helpers.
# This file defines functions only. It must be safe to source in any shell.

# Purpose: report a configuration error without echoing operator-controlled data.
# Parameters: message, optional line number, optional key.
# Result: diagnostic on stderr.
# Status: always 1.
# Context/side effects: reads no runtime context; writes only stderr.
# External commands/secrets: none; values are deliberately excluded.
_cntools_config_error() {
  local message="${1:-Invalid CNTools configuration}"
  local line_number="${2:-}"
  local key="${3:-}"
  local location=""

  [[ -n "${line_number}" ]] && location=" at line ${line_number}"
  [[ -n "${key}" ]] && location="${location} for ${key}"
  printf 'CNTools configuration error%s: %s\n' "${location}" "${message}" >&2
  return 1
}

_cntools_config_assoc_valid() {
  local variable_name="${1:-}"
  local declaration=""

  [[ "${variable_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  declaration="$(declare -p "${variable_name}" 2>/dev/null)" || return 1
  [[ "${declaration}" == 'declare -A '* ]]
}

_cntools_config_key_supported() {
  case "${1:-}" in
    CNTOOLS_CONFIG_VERSION|TIMEOUT_NO_OF_SLOTS|CNTOOLS_LOG|CHECK_KES|\
      KES_ALERT_PERIOD|KES_WARNING_PERIOD|TX_TTL|\
      WALLET_SELECTION_FILTER_LIMIT|ENABLE_CHATTR|ENABLE_DIALOG|\
      ENABLE_ADVANCED|CURRENCY|CNTOOLS_MODE|CATALYST_API|EXPLORER_TX)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_cntools_config_path_syntax_valid() {
  local path="${1:-}"
  local component=""
  local -a components=()

  [[ "${path}" == /* && "${path}" != */ &&
     "${path}" =~ ^/[A-Za-z0-9._/+@:-]+$ &&
     "${path}" != *//* ]] || return 1
  IFS='/' read -r -a components <<< "${path}"
  for component in "${components[@]}"; do
    [[ -z "${component}" ||
       ( "${component}" != "." && "${component}" != ".." ) ]] || return 1
  done
}

_cntools_config_path_has_no_symlink_components() {
  local path="${1:-}"
  local current=""
  local component=""
  local -a components=()

  _cntools_config_path_syntax_valid "${path}" || return 1
  IFS='/' read -r -a components <<< "${path}"
  for component in "${components[@]}"; do
    [[ -n "${component}" ]] || continue
    current="${current}/${component}"
    [[ ! -L "${current}" ]] || return 1
  done
}

_cntools_config_https_url_valid() {
  local value="${1:-}"
  local url_pattern='^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~%+,:@/-]*)?$'

  [[ "${value}" =~ ${url_pattern} ]]
}

_cntools_config_integer_valid() {
  local value="${1:-}"
  local allow_zero="${2:-N}"

  [[ "${value}" =~ ^(0|[1-9][0-9]{0,9})$ ]] || return 1
  (( 10#${value} <= 2147483647 )) || return 1
  [[ "${allow_zero}" == "Y" || "${value}" != "0" ]]
}

_cntools_config_value_valid() {
  local key="${1:-}"
  local value="${2:-}"
  local marker_prefix="" marker_suffix=""

  case "${key}" in
    CNTOOLS_CONFIG_VERSION)
      [[ "${value}" == "1" ]]
      ;;
    TIMEOUT_NO_OF_SLOTS|TX_TTL)
      _cntools_config_integer_valid "${value}" N
      ;;
    KES_ALERT_PERIOD|KES_WARNING_PERIOD|WALLET_SELECTION_FILTER_LIMIT)
      _cntools_config_integer_valid "${value}" Y
      ;;
    CHECK_KES|ENABLE_CHATTR|ENABLE_DIALOG|ENABLE_ADVANCED)
      [[ "${value}" == "true" || "${value}" == "false" ]]
      ;;
    CURRENCY)
      [[ "${value}" == "off" ||
         "${value}" =~ ^[a-z][a-z0-9_-]{0,15}$ ]]
      ;;
    CNTOOLS_MODE)
      [[ "${value}" == "local" || "${value}" == "light" ||
         "${value}" == "offline" ]]
      ;;
    CNTOOLS_LOG)
      _cntools_config_path_syntax_valid "${value}"
      ;;
    CATALYST_API)
      _cntools_config_https_url_valid "${value}"
      ;;
    EXPLORER_TX)
      _cntools_config_https_url_valid "${value}" || return 1
      marker_prefix="${value%%__tx_id__*}"
      [[ "${marker_prefix}" != "${value}" ]] || return 1
      marker_suffix="${value#*__tx_id__}"
      [[ "${marker_suffix}" != *'__tx_id__'* ]]
      ;;
    *)
      return 1
      ;;
  esac
}

_cntools_config_file_is_text() {
  local file="${1:-}"
  local maximum_bytes="${2:-32768}"
  local byte_count=""

  [[ -f "${file}" && ! -L "${file}" ]] || return 1
  [[ "${maximum_bytes}" =~ ^[0-9]+$ ]] || return 1
  byte_count="$(wc -c < "${file}" 2>/dev/null)" || return 1
  byte_count="${byte_count//[[:space:]]/}"
  [[ "${byte_count}" =~ ^[0-9]+$ &&
     "${byte_count}" -le "${maximum_bytes}" ]] || return 1
  if LC_ALL=C od -An -v -t u1 "${file}" 2>/dev/null |
      grep -Eq '(^|[[:space:]])0([[:space:]]|$)'; then
    return 1
  fi
}

# Purpose: parse canonical, data-only CNTools configuration records.
# Parameters: configuration file, caller-declared associative-array name.
# Result: explicit validated records, including CNTOOLS_CONFIG_VERSION.
# Status: 0 success, 1 unsafe/malformed data, 2 invalid caller contract.
# Context/side effects: no runtime context; clears and fills only the output map.
# External commands: wc, od, and grep. No configuration text is executed.
# Security: mode and ownership are intentionally checked by the runtime wrapper,
# allowing the managed read-only example to use this semantic validator.
cntools_config_parse() {
  local file="${1:-}"
  local output_name="${2:-}"
  local line="" key="" value="" first_key=""
  local line_number=0
  local assignment_pattern='^([A-Z][A-Z0-9_]*)=([^[:space:]]+)$'
  local -A __cntools_config_records=()

  _cntools_config_assoc_valid "${output_name}" || {
    _cntools_config_error "output must name a declared associative array"
    return 2
  }
  local -n output_ref="${output_name}"
  output_ref=()

  _cntools_config_file_is_text "${file}" || {
    _cntools_config_error "file must be a small, regular, non-symlink text file"
    return 1
  }

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line_number=$((line_number + 1))
    [[ "${line}" != *$'\r'* ]] || {
      _cntools_config_error "carriage returns are not allowed" "${line_number}"
      return 1
    }
    [[ "${line}" =~ ^[[:space:]]*$ ||
       "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" =~ ${assignment_pattern} ]] || {
      _cntools_config_error \
        "expected an unquoted KEY=VALUE assignment without inline comments" \
        "${line_number}"
      return 1
    }
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    _cntools_config_key_supported "${key}" || {
      _cntools_config_error "unknown key" "${line_number}" "${key}"
      return 1
    }
    [[ -z "${__cntools_config_records[${key}]+set}" ]] || {
      _cntools_config_error "duplicate key" "${line_number}" "${key}"
      return 1
    }
    [[ -n "${first_key}" ]] || first_key="${key}"
    _cntools_config_value_valid "${key}" "${value}" || {
      _cntools_config_error "value does not satisfy its declared type" \
        "${line_number}" "${key}"
      return 1
    }
    __cntools_config_records["${key}"]="${value}"
  done < "${file}"

  [[ "${first_key}" == "CNTOOLS_CONFIG_VERSION" &&
     "${__cntools_config_records[CNTOOLS_CONFIG_VERSION]:-}" == "1" ]] || {
    _cntools_config_error \
      "CNTOOLS_CONFIG_VERSION=1 must be the first assignment"
    return 1
  }

  for key in "${!__cntools_config_records[@]}"; do
    output_ref["${key}"]="${__cntools_config_records[${key}]}"
  done
}

# Purpose: compatibility alias that emphasizes data-only validation.
# Parameters/result/status: identical to cntools_config_parse.
# Context/side effects/external commands/security: identical to that function.
cntools_config_parse_data() {
  cntools_config_parse "$@"
}

# Purpose: construct documented built-in CNTools settings.
# Parameters: caller-declared output associative array, validated LOG_DIR.
# Result: complete version-1 configuration map.
# Status: 0 success, 1 unsafe LOG_DIR, 2 invalid caller contract.
# Context/side effects: reads only the supplied path; mutates only output map.
# External commands/secrets: none; contains no credentials.
cntools_config_defaults() {
  local output_name="${1:-}"
  local log_dir="${2:-}"

  _cntools_config_assoc_valid "${output_name}" || return 2
  # shellcheck disable=SC2178 # Bash nameref to caller-declared associative array.
  local -n output_ref="${output_name}"
  output_ref=()
  _cntools_config_path_has_no_symlink_components "${log_dir}" || {
    _cntools_config_error "LOG_DIR must be an absolute safe path"
    return 1
  }

  output_ref[CNTOOLS_CONFIG_VERSION]="1"
  output_ref[TIMEOUT_NO_OF_SLOTS]="600"
  output_ref[CNTOOLS_LOG]="${log_dir}/cntools-history.log"
  output_ref[CHECK_KES]="true"
  output_ref[KES_ALERT_PERIOD]="172800"
  output_ref[KES_WARNING_PERIOD]="604800"
  output_ref[TX_TTL]="3600"
  output_ref[WALLET_SELECTION_FILTER_LIMIT]="10"
  output_ref[ENABLE_CHATTR]="true"
  output_ref[ENABLE_DIALOG]="false"
  output_ref[ENABLE_ADVANCED]="false"
  output_ref[CURRENCY]="off"
  output_ref[CNTOOLS_MODE]="local"
  output_ref[CATALYST_API]="https://api.projectcatalyst.io/api/v1"
  output_ref[EXPLORER_TX]="https://adastat.net/transactions/__tx_id__"
}

# Purpose: overlay explicit records on built-in values and validate relationships.
# Parameters: input associative array, output associative array, validated LOG_DIR.
# Result: complete resolved configuration map.
# Status: 0 success, 1 invalid content/path relationship, 2 caller error.
# Context/side effects: filesystem reads for symlink checks; output map only.
# External commands/secrets: none; configuration must contain no secrets.
cntools_config_resolve() {
  local input_name="${1:-}"
  local output_name="${2:-}"
  local log_dir="${3:-}"
  local key="" log_prefix=""
  local -A __cntools_config_resolved=()

  _cntools_config_assoc_valid "${input_name}" || return 2
  _cntools_config_assoc_valid "${output_name}" || return 2
  local -n input_ref="${input_name}"
  # shellcheck disable=SC2178 # Bash nameref to caller-declared associative array.
  local -n output_ref="${output_name}"
  output_ref=()

  cntools_config_defaults __cntools_config_resolved "${log_dir}" || return 1
  [[ "${input_ref[CNTOOLS_CONFIG_VERSION]:-}" == "1" ]] || {
    _cntools_config_error "unsupported or missing configuration version"
    return 1
  }
  for key in "${!input_ref[@]}"; do
    _cntools_config_key_supported "${key}" || {
      _cntools_config_error "unknown key" "" "${key}"
      return 1
    }
    _cntools_config_value_valid "${key}" "${input_ref[${key}]}" || {
      _cntools_config_error "value does not satisfy its declared type" "" "${key}"
      return 1
    }
    __cntools_config_resolved["${key}"]="${input_ref[${key}]}"
  done

  (( 10#${__cntools_config_resolved[KES_ALERT_PERIOD]} <=
     10#${__cntools_config_resolved[KES_WARNING_PERIOD]} )) || {
    _cntools_config_error \
      "KES_ALERT_PERIOD must not exceed KES_WARNING_PERIOD"
    return 1
  }
  log_prefix="${log_dir%/}/"
  [[ "${__cntools_config_resolved[CNTOOLS_LOG]}" == "${log_prefix}"* ]] || {
    _cntools_config_error "CNTOOLS_LOG must remain below LOG_DIR" "" "CNTOOLS_LOG"
    return 1
  }
  _cntools_config_path_has_no_symlink_components \
    "${__cntools_config_resolved[CNTOOLS_LOG]}" || {
    _cntools_config_error "CNTOOLS_LOG has an unsafe path component" "" "CNTOOLS_LOG"
    return 1
  }

  for key in "${!__cntools_config_resolved[@]}"; do
    output_ref["${key}"]="${__cntools_config_resolved[${key}]}"
  done
}

_cntools_config_runtime_stat() {
  local file="${1:-}"

  if stat -c $'%u\t%a\t%h' "${file}" >/dev/null 2>&1; then
    stat -c $'%u\t%a\t%h' "${file}"
  else
    stat -f $'%u\t%Lp\t%l' "${file}"
  fi
}

# Purpose: validate and resolve an operator-owned runtime configuration file.
# Parameters: file, output associative array, LOG_DIR, optional expected UID.
# Result: complete resolved configuration map.
# Status: 0 success, 1 unsafe/malformed file, 2 invalid caller contract.
# Context/side effects: reads file metadata/content; mutates only output map.
# External commands: id, stat, wc, od, grep. No data is executed.
# Security: requires regular non-symlink, one link, expected owner, mode 0600.
cntools_config_load_runtime() {
  local file="${1:-}"
  local output_name="${2:-}"
  local log_dir="${3:-}"
  local expected_uid="${4:-}"
  local owner="" mode="" links=""
  # shellcheck disable=SC2034 # Populated by cntools_config_parse via nameref.
  local -A __cntools_config_explicit=()

  _cntools_config_assoc_valid "${output_name}" || return 2
  # shellcheck disable=SC2178 # Bash nameref to caller-declared associative array.
  local -n output_ref="${output_name}"
  output_ref=()
  [[ -n "${expected_uid}" ]] || expected_uid="$(id -u)" || return 1
  [[ "${expected_uid}" =~ ^[0-9]+$ ]] || return 2
  [[ -f "${file}" && ! -L "${file}" ]] || {
    _cntools_config_error "runtime file must be regular and must not be a symlink"
    return 1
  }
  IFS=$'\t' read -r owner mode links < <(_cntools_config_runtime_stat "${file}") || {
    _cntools_config_error "unable to inspect runtime file metadata"
    return 1
  }
  [[ "${owner}" == "${expected_uid}" && "${mode}" == "600" &&
     "${links}" == "1" ]] || {
    _cntools_config_error \
      "runtime file must have the expected owner, mode 0600, and one hard link"
    return 1
  }
  cntools_config_parse "${file}" __cntools_config_explicit || return 1
  cntools_config_resolve __cntools_config_explicit "${output_name}" "${log_dir}"
}

_cntools_config_legacy_literal() {
  local expression="${1-}"
  local output_name="${2:-}"
  local double_pattern='^"([^"]*)"[[:space:]]*(#.*)?$'
  local single_pattern="^'([^']*)'[[:space:]]*(#.*)?$"
  local plain_pattern='^([^[:space:]#]*)([[:space:]]+#.*)?$'

  [[ "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n literal_ref="${output_name}"
  literal_ref=""
  if [[ "${expression}" =~ ${double_pattern} ]]; then
    literal_ref="${BASH_REMATCH[1]}"
  elif [[ "${expression}" =~ ${single_pattern} ]]; then
    literal_ref="${BASH_REMATCH[1]}"
  elif [[ "${expression}" =~ ${plain_pattern} ]]; then
    # shellcheck disable=SC2034 # Scalar output is returned through a nameref.
    literal_ref="${BASH_REMATCH[1]}"
  else
    return 1
  fi
}

# Purpose: extract safe legacy overrides without evaluating the launcher header.
# Parameters: legacy cntools.sh, output associative array, validated LOG_DIR.
# Result: canonical explicit version-1 records suitable for later rendering.
# Status: 0 eligible migration, 1 unsafe/ambiguous header, 2 caller error.
# Context/side effects: reads the legacy file; never writes it or cntools.conf.
# External commands: wc, od, grep through the text check. No shell is evaluated.
# Security: every active pre-boundary line must be a unique allowlisted literal
# assignment. The only expansion recognized textually is ${LOG_DIR}/... for
# CNTOOLS_LOG; obsolete cntools.config and ambient variables are never read.
cntools_config_migrate_legacy_header() {
  local legacy_file="${1:-}"
  local output_name="${2:-}"
  local log_dir="${3:-}"
  local line="" key="" expression="" value="" suffix=""
  local line_number=0 boundary_found="N"
  local assignment_pattern='^[[:space:]]*([A-Z][A-Z0-9_]*)=(.*)$'
  local log_dir_marker='${LOG_DIR}/'
  local -A __cntools_migration_records=() __cntools_migration_resolved=()

  _cntools_config_assoc_valid "${output_name}" || return 2
  # shellcheck disable=SC2178 # Bash nameref to caller-declared associative array.
  local -n output_ref="${output_name}"
  output_ref=()
  _cntools_config_file_is_text "${legacy_file}" 2097152 || {
    _cntools_config_error "legacy launcher must be a safe regular text file"
    return 1
  }
  _cntools_config_path_has_no_symlink_components "${log_dir}" || {
    _cntools_config_error "LOG_DIR must be an absolute safe path"
    return 1
  }
  __cntools_migration_records[CNTOOLS_CONFIG_VERSION]="1"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line_number=$((line_number + 1))
    if [[ "${line}" == '# Do NOT modify code below'* ]]; then
      boundary_found="Y"
      break
    fi
    [[ "${line}" != *$'\r'* ]] || {
      _cntools_config_error "carriage returns are not allowed" "${line_number}"
      return 1
    }
    [[ "${line}" =~ ^[[:space:]]*$ ||
       "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" =~ ${assignment_pattern} ]] || {
      _cntools_config_error \
        "active non-assignment code prevents automatic migration" \
        "${line_number}"
      return 1
    }
    key="${BASH_REMATCH[1]}"
    expression="${BASH_REMATCH[2]}"
    [[ "${key}" != "CNTOOLS_CONFIG_VERSION" ]] || {
      _cntools_config_error "legacy header must not declare the new schema" \
        "${line_number}" "${key}"
      return 1
    }
    _cntools_config_key_supported "${key}" || {
      _cntools_config_error \
        "unknown active assignment prevents automatic migration" \
        "${line_number}" "${key}"
      return 1
    }
    [[ -z "${__cntools_migration_records[${key}]+set}" ]] || {
      _cntools_config_error "duplicate active assignment" \
        "${line_number}" "${key}"
      return 1
    }
    _cntools_config_legacy_literal "${expression}" value || {
      _cntools_config_error "assignment is not a supported literal" \
        "${line_number}" "${key}"
      return 1
    }

    # Empty legacy assignments currently fall through to library defaults.
    [[ -n "${value}" ]] || continue
    if [[ "${key}" == "CNTOOLS_LOG" &&
          "${value}" == "${log_dir_marker}"* ]]; then
      suffix="${value#"${log_dir_marker}"}"
      [[ "${suffix}" =~ ^[A-Za-z0-9._/+@:-]+$ ]] || {
        _cntools_config_error "unsafe LOG_DIR-relative path" \
          "${line_number}" "${key}"
        return 1
      }
      value="${log_dir}/${suffix}"
    elif [[ "${value}" == *'$'* || "${value}" == *'`'* ||
            "${value}" == *'\\'* ]]; then
      _cntools_config_error "expansion or escaping is not allowed" \
        "${line_number}" "${key}"
      return 1
    fi
    case "${key}" in
      CNTOOLS_MODE|CURRENCY) value="${value,,}" ;;
    esac
    _cntools_config_value_valid "${key}" "${value}" || {
      _cntools_config_error "value does not satisfy the target type" \
        "${line_number}" "${key}"
      return 1
    }
    __cntools_migration_records["${key}"]="${value}"
  done < "${legacy_file}"

  [[ "${boundary_found}" == "Y" ]] || {
    _cntools_config_error "legacy user-header boundary is missing"
    return 1
  }
  cntools_config_resolve __cntools_migration_records \
    __cntools_migration_resolved "${log_dir}" || return 1
  for key in "${!__cntools_migration_records[@]}"; do
    # shellcheck disable=SC2034 # Associative output is returned through a nameref.
    output_ref["${key}"]="${__cntools_migration_records[${key}]}"
  done
}
