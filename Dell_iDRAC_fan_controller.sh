#!/bin/bash

# Strict mode disabled -- see github.com/tigerblue77/Dell_iDRAC_fan_controller/issues/48
# set -euo pipefail

source functions.sh
source constants.sh

# Trap the signals for container exit and run graceful_exit function
trap 'graceful_exit' SIGINT SIGQUIT SIGTERM

# readonly DELL_FRESH_AIR_COMPLIANCE=45

# Check if FAN_SPEED variable is in hexadecimal format. If not, convert it to hexadecimal
if [[ "$FAN_SPEED" == 0x* ]]; then
  readonly DECIMAL_FAN_SPEED=$(convert_hexadecimal_value_to_decimal "$FAN_SPEED")
  readonly HEXADECIMAL_FAN_SPEED="$FAN_SPEED"
else
  readonly DECIMAL_FAN_SPEED="$FAN_SPEED"
  readonly HEXADECIMAL_FAN_SPEED=$(convert_decimal_value_to_hexadecimal "$FAN_SPEED")
fi

# Multi-alarm discovery and configuration
# Per-alarm config arrays (indexed by position in ALARM_IDS)
declare -a ALARM_START_TIMES=()
declare -a ALARM_END_TIMES=()
declare -a ALARM_DAYS_LIST=()
declare -a ALARM_CHECK_HOSTS_LIST=()
declare -a ALARM_HOST_LOGIC_LIST=()
declare -a ALARM_FAN_SPEEDS_DEC=()
declare -a ALARM_FAN_SPEEDS_HEX=()
declare -a ALARM_PERSIST_LIST=()
declare -a ALARM_MAX_DURATION_LIST=()
# Per-alarm state arrays
declare -a ALARM_IS_ACTIVE=()
declare -a ALARM_TRIGGERED_DATES=()
declare -a ALARM_START_EPOCHS=()

ALARM_COUNT=0
if [[ "$ALARM_ENABLED" == "true" ]]; then
  discover_alarms

  if [[ ${#ALARM_IDS[@]} -eq 0 ]]; then
    print_error_and_exit "ALARM_ENABLED is true but no alarm schedules found. Set ALARM_1_START_TIME, ALARM_2_START_TIME, etc."
  fi

  for i in "${!ALARM_IDS[@]}"; do
    local_id="${ALARM_IDS[$i]}"

    # Load config with fallback to base ALARM_* vars
    ALARM_START_TIMES[$i]=$(get_alarm_config "$local_id" "START_TIME")
    ALARM_END_TIMES[$i]=$(get_alarm_config "$local_id" "END_TIME")
    ALARM_DAYS_LIST[$i]=$(get_alarm_config "$local_id" "DAYS")
    ALARM_CHECK_HOSTS_LIST[$i]=$(get_alarm_config "$local_id" "CHECK_HOSTS")
    ALARM_HOST_LOGIC_LIST[$i]=$(get_alarm_config "$local_id" "HOST_LOGIC")
    ALARM_PERSIST_LIST[$i]=$(get_alarm_config "$local_id" "PERSIST")
    ALARM_MAX_DURATION_LIST[$i]=$(get_alarm_config "$local_id" "MAX_DURATION")

    # Convert fan speed to hex/dec
    local_fan_speed=$(get_alarm_config "$local_id" "FAN_SPEED")
    if [[ "$local_fan_speed" == 0x* ]]; then
      ALARM_FAN_SPEEDS_DEC[$i]=$(convert_hexadecimal_value_to_decimal "$local_fan_speed")
      ALARM_FAN_SPEEDS_HEX[$i]="$local_fan_speed"
    else
      ALARM_FAN_SPEEDS_DEC[$i]="$local_fan_speed"
      ALARM_FAN_SPEEDS_HEX[$i]=$(convert_decimal_value_to_hexadecimal "$local_fan_speed")
    fi

    # Validate
    if (( ALARM_FAN_SPEEDS_DEC[$i] < 0 || ALARM_FAN_SPEEDS_DEC[$i] > 100 )); then
      print_error_and_exit "Alarm ${local_id}: FAN_SPEED must be between 0 and 100, got: $local_fan_speed"
    fi
    if [[ -z "${ALARM_CHECK_HOSTS_LIST[$i]}" ]]; then
      print_error_and_exit "Alarm ${local_id}: CHECK_HOSTS is empty. At least one host is required for alarm dismissal"
    fi
    if [[ -z "${ALARM_START_TIMES[$i]}" || -z "${ALARM_END_TIMES[$i]}" ]]; then
      print_error_and_exit "Alarm ${local_id}: START_TIME and END_TIME are required"
    fi

    # Init state
    ALARM_IS_ACTIVE[$i]=false
    ALARM_TRIGGERED_DATES[$i]=""
    ALARM_START_EPOCHS[$i]=0
  done

  ALARM_COUNT=${#ALARM_IDS[@]}
fi

set_iDRAC_login_string "$IDRAC_HOST" "$IDRAC_USERNAME" "$IDRAC_PASSWORD"

get_Dell_server_model

if [[ ! $SERVER_MANUFACTURER == "DELL" ]]; then
  print_error_and_exit "Your server isn't a Dell product"
fi

# If server model is Gen 14 (*40) or newer
if [[ $SERVER_MODEL =~ .*[RT][[:space:]]?[0-9][4-9]0.* ]]; then
  readonly DELL_POWEREDGE_GEN_14_OR_NEWER=true
  readonly CPU1_TEMPERATURE_INDEX=2
  readonly CPU2_TEMPERATURE_INDEX=4
else
  readonly DELL_POWEREDGE_GEN_14_OR_NEWER=false
  readonly CPU1_TEMPERATURE_INDEX=1
  readonly CPU2_TEMPERATURE_INDEX=2
fi

# Log startup info
echo "Server model: $SERVER_MANUFACTURER $SERVER_MODEL"
echo "iDRAC/IPMI host: $IDRAC_HOST"

echo "Fan speed objective: $DECIMAL_FAN_SPEED%"
echo "CPU temperature threshold: "$CPU_TEMPERATURE_THRESHOLD"°C"
echo "Check interval: ${CHECK_INTERVAL}s"
if [[ "$ALARM_ENABLED" == "true" ]]; then
  echo ""
  echo "*** ALARM CLOCK ENABLED ($ALARM_COUNT alarm(s)) ***"
  for i in "${!ALARM_IDS[@]}"; do
    local_id="${ALARM_IDS[$i]}"
    echo "  --- Alarm $local_id ---"
    echo "    Window: ${ALARM_START_TIMES[$i]} - ${ALARM_END_TIMES[$i]}"
    echo "    Days: ${ALARM_DAYS_LIST[$i]}"
    echo "    Check hosts: ${ALARM_CHECK_HOSTS_LIST[$i]} (logic: ${ALARM_HOST_LOGIC_LIST[$i]})"
    echo "    Fan speed: ${ALARM_FAN_SPEEDS_DEC[$i]}%"
    echo "    Persist past window: ${ALARM_PERSIST_LIST[$i]}"
    if [[ "${ALARM_PERSIST_LIST[$i]}" == "true" ]]; then
      echo "    Max alarm duration: ${ALARM_MAX_DURATION_LIST[$i]} minutes"
    fi
  done
  echo "  Timezone: ${TZ:-UTC}"
fi
echo ""

TABLE_HEADER_PRINT_COUNTER=$TABLE_HEADER_PRINT_INTERVAL
# Set the flag used to check if the active fan control profile has changed
IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=true

# Check present sensors
IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT=true
IS_CPU2_TEMPERATURE_SENSOR_PRESENT=true
retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT $IS_CPU2_TEMPERATURE_SENSOR_PRESENT
if [ -z "$EXHAUST_TEMPERATURE" ]; then
  echo "No exhaust temperature sensor detected."
  IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT=false
fi
if [ -z "$CPU2_TEMPERATURE" ]; then
  echo "No CPU2 temperature sensor detected."
  IS_CPU2_TEMPERATURE_SENSOR_PRESENT=false
fi
# Blank line after sensor detection messages
if ! $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT || ! $IS_CPU2_TEMPERATURE_SENSOR_PRESENT; then
  echo ""
fi

#readonly NUMBER_OF_DETECTED_CPUS=(${CPUS_TEMPERATURES//;/ })
# TODO : write "X CPU sensors detected." and remove previous ifs
readonly HEADER=$(build_header $NUMBER_OF_DETECTED_CPUS)

# Start monitoring
while true; do
  # Sleep for the specified interval before taking another reading
  sleep "$CHECK_INTERVAL" &
  SLEEP_PROCESS_PID=$!

  retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT $IS_CPU2_TEMPERATURE_SENSOR_PRESENT

  # --- Alarm clock logic (multi-alarm) ---
  ALARM_SHOULD_SOUND=false
  ACTIVE_ALARM_HEX=""
  ACTIVE_ALARM_DEC=0
  ACTIVE_ALARM_LABEL=""
  if [[ "$ALARM_ENABLED" == "true" ]]; then
    local_today=$(date +%Y-%m-%d)

    for i in "${!ALARM_IDS[@]}"; do
      local_id="${ALARM_IDS[$i]}"
      local_label="Alarm $local_id"

      IN_WINDOW=false
      if is_alarm_day "${ALARM_DAYS_LIST[$i]}" && is_in_alarm_window "${ALARM_START_TIMES[$i]}" "${ALARM_END_TIMES[$i]}"; then
        IN_WINDOW=true
      fi

      ALREADY_TRIGGERED_TODAY=false
      if [[ "${ALARM_TRIGGERED_DATES[$i]}" == "$local_today" ]]; then
        ALREADY_TRIGGERED_TODAY=true
      fi

      if ${ALARM_IS_ACTIVE[$i]}; then
        # This alarm is currently sounding — check for dismissal, timeout, or window expiry
        if check_alarm_hosts "${ALARM_CHECK_HOSTS_LIST[$i]}" "${ALARM_HOST_LOGIC_LIST[$i]}"; then
          ALARM_IS_ACTIVE[$i]=false
          ALARM_TRIGGERED_DATES[$i]=$local_today
          echo "$(date +"%d-%m-%Y %T") $local_label DISMISSED: host(s) came online, resuming normal fan control"
        elif ! $IN_WINDOW && [[ "${ALARM_PERSIST_LIST[$i]}" != "true" ]]; then
          ALARM_IS_ACTIVE[$i]=false
          ALARM_TRIGGERED_DATES[$i]=$local_today
          echo "$(date +"%d-%m-%Y %T") $local_label EXPIRED: window ended, resuming normal fan control"
        elif [[ "${ALARM_PERSIST_LIST[$i]}" == "true" ]] && (( $(date +%s) - ALARM_START_EPOCHS[$i] > ALARM_MAX_DURATION_LIST[$i] * 60 )); then
          ALARM_IS_ACTIVE[$i]=false
          ALARM_TRIGGERED_DATES[$i]=$local_today
          echo "$(date +"%d-%m-%Y %T") $local_label TIMED OUT: max duration of ${ALARM_MAX_DURATION_LIST[$i]} minutes reached, resuming normal fan control"
        else
          # Keep sounding — pick highest fan speed if multiple alarms active
          if (( ALARM_FAN_SPEEDS_DEC[$i] > ACTIVE_ALARM_DEC )); then
            ACTIVE_ALARM_HEX="${ALARM_FAN_SPEEDS_HEX[$i]}"
            ACTIVE_ALARM_DEC=${ALARM_FAN_SPEEDS_DEC[$i]}
            ACTIVE_ALARM_LABEL="$local_label"
          fi
          ALARM_SHOULD_SOUND=true
        fi
      elif $IN_WINDOW && ! $ALREADY_TRIGGERED_TODAY; then
        # In window, alarm hasn't triggered yet today — check if we should trigger
        if ! check_alarm_hosts "${ALARM_CHECK_HOSTS_LIST[$i]}" "${ALARM_HOST_LOGIC_LIST[$i]}"; then
          ALARM_IS_ACTIVE[$i]=true
          ALARM_START_EPOCHS[$i]=$(date +%s)
          echo "$(date +"%d-%m-%Y %T") $local_label TRIGGERED: host(s) offline, ramping fans to ${ALARM_FAN_SPEEDS_DEC[$i]}%"
          if (( ALARM_FAN_SPEEDS_DEC[$i] > ACTIVE_ALARM_DEC )); then
            ACTIVE_ALARM_HEX="${ALARM_FAN_SPEEDS_HEX[$i]}"
            ACTIVE_ALARM_DEC=${ALARM_FAN_SPEEDS_DEC[$i]}
            ACTIVE_ALARM_LABEL="$local_label"
          fi
          ALARM_SHOULD_SOUND=true
        fi
      fi
    done
  fi

  # Reset comment for this cycle
  COMMENT=" -"
  # Check if CPU 1 is overheating then apply Dell default dynamic fan control profile if true
  if CPU1_OVERHEATING; then
    apply_Dell_default_fan_control_profile

    if ! $IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED; then
      IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=true

      # If CPU 2 temperature sensor is present, check if it is overheating too.
      # Do not apply Dell default dynamic fan control profile as it has already been applied before
      if $IS_CPU2_TEMPERATURE_SENSOR_PRESENT && CPU2_OVERHEATING; then
        COMMENT="CPU 1 and CPU 2 temperatures are too high, Dell default dynamic fan control profile applied for safety"
      else
        COMMENT="CPU 1 temperature is too high, Dell default dynamic fan control profile applied for safety"
      fi
    fi
  # If CPU 2 temperature sensor is present, check if it is overheating then apply Dell default dynamic fan control profile if true
  elif $IS_CPU2_TEMPERATURE_SENSOR_PRESENT && CPU2_OVERHEATING; then
    apply_Dell_default_fan_control_profile

    if ! $IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED; then
      IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=true
      COMMENT="CPU 2 temperature is too high, Dell default dynamic fan control profile applied for safety"
    fi
  elif $ALARM_SHOULD_SOUND; then
    apply_alarm_fan_control_profile "$ACTIVE_ALARM_HEX" "$ACTIVE_ALARM_DEC"

    if ! $IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED; then
      COMMENT="$ACTIVE_ALARM_LABEL ACTIVE: fans at $ACTIVE_ALARM_DEC% — waiting for host(s) to come online"
    else
      IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=false
      COMMENT="$ACTIVE_ALARM_LABEL ACTIVE: fans at $ACTIVE_ALARM_DEC% (overriding Dell default)"
    fi
  else
    apply_user_fan_control_profile

    # Check if user fan control profile is applied then apply it if not
    if $IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED; then
      IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=false
      COMMENT="CPU temperature decreased and is now OK (<= $CPU_TEMPERATURE_THRESHOLD°C), user's fan control profile applied."
    fi
  fi

  # If server model is not Gen 14 (*40) or newer
  if ! $DELL_POWEREDGE_GEN_14_OR_NEWER; then
    # Enable or disable, depending on the user's choice, third-party PCIe card Dell default cooling response
    # No comment will be displayed on the change of this parameter since it is not related to the temperature of any device (CPU, GPU, etc...) but only to the settings made by the user when launching this Docker container
    if "$DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE"; then
      disable_third_party_PCIe_card_Dell_default_cooling_response
      THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Disabled"
    else
      enable_third_party_PCIe_card_Dell_default_cooling_response
      THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Enabled"
    fi
  fi

  # Print temperatures, active fan control profile and comment if any change happened during last time interval
  if [ $TABLE_HEADER_PRINT_COUNTER -eq $TABLE_HEADER_PRINT_INTERVAL ]; then
    printf "%s\n" "$HEADER"
    TABLE_HEADER_PRINT_COUNTER=0
  fi
  print_temperature_array_line "$INLET_TEMPERATURE" "$CPUS_TEMPERATURES" "$EXHAUST_TEMPERATURE" "$CURRENT_FAN_CONTROL_PROFILE" "$THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS" "$COMMENT"
  ((TABLE_HEADER_PRINT_COUNTER++))
  wait $SLEEP_PROCESS_PID
done
