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
