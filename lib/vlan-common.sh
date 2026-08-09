#!/bin/sh
# shellcheck shell=sh

PATH="/sbin:/bin:/usr/sbin:/usr/bin"
export PATH

DEFAULT_CONFIG_FILE="/jffs/configs/vlan-automation.conf"
DEFAULT_LOG_TAG="vlan-automation"

CONFIG_FILE="${CONFIG_FILE:-$DEFAULT_CONFIG_FILE}"
LOG_TAG="${LOG_TAG:-$DEFAULT_LOG_TAG}"

log_message() {
  level=$1
  shift
  message=$*

  printf '%s: %s\n' "$level" "$message" >&2
  logger -t "$LOG_TAG" "$level: $message" 2>/dev/null || :
}

fail() {
  log_message "ERROR" "$*"
  return 1
}

is_uint() {
  case ${1-} in
  '' | *[!0-9]*)
    return 1
    ;;
  *)
    return 0
    ;;
  esac
}

validate_boolean() {
  name=$1
  value=$2

  case $value in
  0 | 1)
    return 0
    ;;
  *)
    fail "$name must be 0 or 1; received '$value'"
    return 1
    ;;
  esac
}

validate_positive_integer() {
  name=$1
  value=$2

  if ! is_uint "$value" || [ "$value" -eq 0 ]; then
    fail "$name must be a positive integer; received '$value'"
    return 1
  fi
}

validate_interface_name() {
  name=$1
  value=$2

  case $value in
  '' | *[!A-Za-z0-9_.-]*)
    fail "$name must use only letters, digits, dots, underscores, or hyphens; received '$value'"
    return 1
    ;;
  esac

  if [ "${#value}" -gt 15 ]; then
    fail "$name must be 15 characters or fewer; received '$value'"
    return 1
  fi

  return 0
}

validate_vlan_id() {
  name=$1
  value=$2

  if ! is_uint "$value" || [ "${#value}" -gt 4 ]; then
    fail "$name must be a VLAN ID from 1 through 4094; received '$value'"
    return 1
  fi

  if [ "$value" -lt 1 ] || [ "$value" -gt 4094 ]; then
    fail "$name must be a VLAN ID from 1 through 4094; received '$value'"
    return 1
  fi

  return 0
}

interface_exists() {
  interface_name=${1-}

  validate_interface_name "interface name" "$interface_name" || return 1
  [ -d "/sys/class/net/$interface_name" ]
}

# Print the bridge containing an interface.
# Return 1 when no bridge membership can be found.
bridge_for_interface() {
  interface_name=${1-}

  validate_interface_name "interface name" "$interface_name" || return 2

  bridge_link="/sys/class/net/$interface_name/brport/bridge"

  if [ -L "$bridge_link" ]; then
    bridge_path=$(readlink "$bridge_link" 2>/dev/null) || return 1
    bridge_name=${bridge_path##*/}

    validate_interface_name "detected bridge name" "$bridge_name" || return 2
    printf '%s\n' "$bridge_name"
    return 0
  fi

  if ! which brctl >/dev/null 2>&1; then
    return 1
  fi

  brctl show 2>/dev/null | awk -v target="$interface_name" '
        NR == 1 {
            next
        }

        NF >= 3 {
            bridge = $1

            if (NF >= 4 && $4 == target) {
                print bridge
                found = 1
                exit
            }

            next
        }

        NF == 1 && $1 == target {
            print bridge
            found = 1
            exit
        }

        END {
            if (!found)
                exit 1
        }
    '
}

wait_for_interface() {
  interface_name=${1-}
  timeout_seconds=${WAIT_TIMEOUT_SECONDS:-30}
  interval_seconds=${WAIT_INTERVAL_SECONDS:-1}

  validate_interface_name "interface name" "$interface_name" || return 1
  validate_positive_integer "WAIT_TIMEOUT_SECONDS" "$timeout_seconds" || return 1
  validate_positive_integer "WAIT_INTERVAL_SECONDS" "$interval_seconds" || return 1

  elapsed_seconds=0

  while ! interface_exists "$interface_name"; do
    if [ "$elapsed_seconds" -ge "$timeout_seconds" ]; then
      fail "Timed out after ${timeout_seconds}s waiting for interface '$interface_name'"
      return 1
    fi

    remaining_seconds=$((timeout_seconds - elapsed_seconds))
    sleep_seconds=$interval_seconds

    if [ "$sleep_seconds" -gt "$remaining_seconds" ]; then
      sleep_seconds=$remaining_seconds
    fi

    sleep "$sleep_seconds"
    elapsed_seconds=$((elapsed_seconds + sleep_seconds))
  done

  return 0
}

load_config() {
  if [ ! -r "$CONFIG_FILE" ]; then
    fail "Configuration is not readable: $CONFIG_FILE"
    return 1
  fi

  # shellcheck disable=SC1090
  . "$CONFIG_FILE" || {
    fail "Unable to load configuration: $CONFIG_FILE"
    return 1
  }

  if [ "${CONFIG_VERSION:-}" != "1" ]; then
    fail "Unsupported or missing CONFIG_VERSION"
    return 1
  fi

  DRY_RUN="${DRY_RUN:-1}"
  HEALTH_REPAIR="${HEALTH_REPAIR:-0}"
  TRACE_ENABLED="${TRACE_ENABLED:-0}"

  WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-30}"
  WAIT_INTERVAL_SECONDS="${WAIT_INTERVAL_SECONDS:-1}"

  BOOT_LOG_TAG="${BOOT_LOG_TAG:-vlan-automation}"
  HEALTH_LOG_TAG="${HEALTH_LOG_TAG:-wifi-health}"

  TRUNK_INTERFACE="${TRUNK_INTERFACE:-}"
  VLAN_BRIDGE_MAP="${VLAN_BRIDGE_MAP:-}"
  STALE_VLAN_IDS="${STALE_VLAN_IDS:-}"
  PORT_BRIDGE_MAP="${PORT_BRIDGE_MAP:-}"
  VIF_BRIDGE_MAP="${VIF_BRIDGE_MAP:-}"
  RADIO_NVRAM_KEYS="${RADIO_NVRAM_KEYS:-}"
  BSS_NVRAM_KEYS="${BSS_NVRAM_KEYS:-}"

  validate_boolean "DRY_RUN" "$DRY_RUN" || return 1
  validate_boolean "HEALTH_REPAIR" "$HEALTH_REPAIR" || return 1
  validate_boolean "TRACE_ENABLED" "$TRACE_ENABLED" || return 1

  validate_positive_integer \
    "WAIT_TIMEOUT_SECONDS" "$WAIT_TIMEOUT_SECONDS" || return 1

  validate_positive_integer \
    "WAIT_INTERVAL_SECONDS" "$WAIT_INTERVAL_SECONDS" || return 1

  return 0
}

run_mutation() {
  if [ "${DRY_RUN:-1}" = "1" ]; then
    log_message "INFO" "DRY-RUN: $*"
    return 0
  fi

  "$@"
  status=$?

  if [ "$status" -ne 0 ]; then
    fail "Command failed with status $status: $*"
    return "$status"
  fi

  return 0
}
