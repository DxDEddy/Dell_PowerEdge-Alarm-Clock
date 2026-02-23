#!/bin/bash

# Strict mode disabled -- see github.com/tigerblue77/Dell_iDRAC_fan_controller/issues/48
# set -euo pipefail

source functions.sh

set_iDRAC_login_string "$IDRAC_HOST" "$IDRAC_USERNAME" "$IDRAC_PASSWORD"

ipmitool -I $IDRAC_LOGIN_STRING sdr type temperature
