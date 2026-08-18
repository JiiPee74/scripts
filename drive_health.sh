#!/usr/bin/env bash

# SPDX-License-Identifier: MIT
# Version: 1.0.0
#
# MIT License
#
# Copyright (c) 2026 JiiPee
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.


# =============================================================================
# SMART DRIVE HEALTH REPORT
# =============================================================================
#
# Discovers SMART-capable drives using smartctl --scan-open.
#
# Each drive is queried once with smartctl. The resulting JSON is processed
# with one jq query to extract all required information.
#
# Drive type detection:
#
#   device.type == nvme       -> NVMe
#   device.protocol == nvme   -> NVMe
#   rotation_rate == 0        -> SSD
#   rotation_rate > 0         -> HDD
#   rotation_rate not reported -> HDD
#
# Requirements: bash, smartctl, jq, numfmt, column, sort
#
# =============================================================================

# =============================================================================
# USER CONFIGURATION
# =============================================================================

# -----------------------------------------------------------------------------
# TEMPERATURE
# -----------------------------------------------------------------------------
#
# C = Celsius
# F = Fahrenheit
#
TEMP_UNIT="C"

# Temperature thresholds are always configured in Celsius.
#
# <= TEMP_GREEN_MAX  = green
# <= TEMP_YELLOW_MAX = yellow
# >  TEMP_YELLOW_MAX = red
#
TEMP_GREEN_MAX=50
TEMP_YELLOW_MAX=60

# -----------------------------------------------------------------------------
# DRIVE LIFE
# -----------------------------------------------------------------------------
#
# Remaining life thresholds.
#
# >= LIFE_GREEN_MIN = green
# >= LIFE_YELLOW_MIN = yellow
# <  LIFE_YELLOW_MIN = red
#
LIFE_GREEN_MIN=50
LIFE_YELLOW_MIN=25

# -----------------------------------------------------------------------------
# MODEL DISPLAY
# -----------------------------------------------------------------------------
#
# Maximum number of characters displayed for MODEL.
#
# Minimum allowed value is 15.
#
MODEL_MAX_LENGTH=30

# -----------------------------------------------------------------------------
# SORTING
# -----------------------------------------------------------------------------
SORT_COLUMN="MODEL"

# ASC = ascending
# DESC = descending
#
SORT_DIRECTION="ASC"

# -----------------------------------------------------------------------------
# DISPLAY
# -----------------------------------------------------------------------------

# yes = colors enabled
# no  = colors disabled
#
USE_COLORS="yes"

# yes = show processing spinner
# no  = don't show spinner
#
SHOW_PROGRESS="yes"

# -----------------------------------------------------------------------------
# SIZE DISPLAY
# -----------------------------------------------------------------------------
#
# SI  = decimal units: MB, GB, TB
# IEC = binary units:  MiB, GiB, TiB
#
SIZE_UNIT="IEC"

# =============================================================================
# INTERNAL VARIABLES
# =============================================================================

DRIVE_DEVICES=()
RESULTS=()
FAILED_DEVICES=()

# =============================================================================
# COLORS
# =============================================================================

if [[ "$USE_COLORS" == "yes" && -t 1 ]]; then

    COLOR_RESET=$'\033[0m'

    COLOR_RED=$'\033[31m'
    COLOR_GREEN=$'\033[32m'
    COLOR_YELLOW=$'\033[33m'

    # Light blue.
    COLOR_LIGHT_BLUE=$'\033[94m'

else

    COLOR_RESET=""
    COLOR_RED=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_LIGHT_BLUE=""
fi

# =============================================================================
# ERROR HANDLING
# =============================================================================

die()
{
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}


# =============================================================================
# DEPENDENCY CHECK
# =============================================================================

check_dependencies()
{
    local command missing=""

    for command in smartctl jq numfmt column sort; do
        if ! command -v "$command" >/dev/null 2>&1; then missing+="$command "; fi
    done

    if [[ -n "$missing" ]]; then printf 'ERROR: Missing required commands:\n' >&2; printf '  %s\n' "$missing" >&2; exit 1; fi
}

# =============================================================================
# CONFIGURATION VALIDATION
# =============================================================================

validate_integer()
{
    local name="$1" value="$2"

    [[ "$value" =~ ^[0-9]+$ ]] ||
        die "$name must be a non-negative integer: '$value'"
}

validate_config()
{
    # Temperature unit.
    case "$TEMP_UNIT" in C|F) ;; *) die "TEMP_UNIT must be C or F" ;; esac

    # Colors.
    case "$USE_COLORS" in yes|no) ;; *) die "USE_COLORS must be yes or no" ;; esac

    # Progress spinner.
    case "$SHOW_PROGRESS" in yes|no) ;; *) die "SHOW_PROGRESS must be yes or no" ;; esac

    # Size units.
    case "$SIZE_UNIT" in SI|IEC) ;; *) die "SIZE_UNIT must be SI or IEC" ;; esac

    # Sort direction.
    case "$SORT_DIRECTION" in ASC|DESC) ;; *) die "SORT_DIRECTION must be ASC or DESC" ;; esac

    # Sort column.
    case "$SORT_COLUMN" in
        KERNEL|DEVTYPE|MODEL|FIRMWARE|SERIAL|SIZE|HEALTH|POH|TEMP|AGE|LIFE|REALLOC|UNCORR) ;;
        *) die "Invalid SORT_COLUMN: '$SORT_COLUMN'" ;;
    esac

    # Numeric configuration.
    validate_integer "TEMP_GREEN_MAX" "$TEMP_GREEN_MAX"
    validate_integer "TEMP_YELLOW_MAX" "$TEMP_YELLOW_MAX"

    validate_integer "LIFE_GREEN_MIN" "$LIFE_GREEN_MIN"
    validate_integer "LIFE_YELLOW_MIN" "$LIFE_YELLOW_MIN"

    validate_integer "MODEL_MAX_LENGTH" "$MODEL_MAX_LENGTH"

    # Temperature thresholds.
    (( TEMP_GREEN_MAX < TEMP_YELLOW_MAX )) || die "TEMP_GREEN_MAX must be lower than TEMP_YELLOW_MAX"

    # Life thresholds.
    (( LIFE_GREEN_MIN <= 100 )) || die "LIFE_GREEN_MIN cannot exceed 100"

    (( LIFE_YELLOW_MIN <= 100 )) || die "LIFE_YELLOW_MIN cannot exceed 100"

    (( LIFE_GREEN_MIN > LIFE_YELLOW_MIN )) || die "LIFE_GREEN_MIN must be greater than LIFE_YELLOW_MIN"

    # Model length.
    (( MODEL_MAX_LENGTH >= 15 )) || die "MODEL_MAX_LENGTH must be at least 15"
}

# =============================================================================
# SPINNER
# =============================================================================

SPINNER_CHARS=('-' '\\' '|' '/')
SPINNER_INDEX=0

print_progress()
{
    local current="$1" total="$2" device="$3"

    [[ "$SHOW_PROGRESS" == "yes" ]] || return

    local spinner="${SPINNER_CHARS[$SPINNER_INDEX]}"

    ((SPINNER_INDEX++))

    if (( SPINNER_INDEX >= ${#SPINNER_CHARS[@]} )); then
        SPINNER_INDEX=0
    fi

    printf '\r\033[K[%s] Checking %d/%d: %s' "$spinner" "$current" "$total" "$device"
}

finish_progress()
{
    [[ "$SHOW_PROGRESS" == "yes" ]] || return

    printf '\r\033[K'
}

# =============================================================================
# DRIVE DISCOVERY
# =============================================================================
#
# Use smartctl JSON output instead of parsing the human-readable scan output.
# We need only the device name and type passed to smartctl -d.
#
# =============================================================================

discover_drives()
{
    local scan_json

    scan_json=$(smartctl -j --scan-open 2>/dev/null) ||
        die "smartctl --scan-open failed."

    [[ -n "$scan_json" ]] ||
        die "smartctl --scan-open returned no data."

    mapfile -t DRIVE_DEVICES < <(jq -r '.devices[] | [.name, .type] | @tsv' <<< "$scan_json")

    ((${#DRIVE_DEVICES[@]} > 0)) ||
        die "smartctl --scan-open did not find any usable devices."
}

# =============================================================================
# DRIVE TYPE DETECTION
# =============================================================================
#
# NVMe:
#   device.type == nvme
#   OR device.protocol == nvme
#
# SSD:
#   rotation_rate == 0
#
# HDD:
#   rotation_rate > 0
#   OR rotation_rate is not reported
#
# =============================================================================

get_drive_type()
{
    local device_type="$1" protocol="$2" rotation_rate="$3"

    if [[ "${device_type,,}" == "nvme" ]]; then
        echo "NVMe"
        return
    fi

    if [[ "${protocol,,}" == "nvme" ]]; then
        echo "NVMe"
        return
    fi

    if [[ "$rotation_rate" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        rotation_rate=${rotation_rate%%.*}
        if (( rotation_rate > 0 )); then echo "HDD"; else echo "SSD"; fi
        return
    fi

    # No rotation rate reported.
    # According to our detection rules, treat it as HDD.
    echo "HDD"
}


# =============================================================================
# FORMAT AGE
# =============================================================================
#
# Power-on hours are converted to days.
#
# Assumptions:
#
#   365 days = 1 year
#   30 days  = 1 month
#
# If months ever reaches 12, it is normalized into one additional year.
#
# =============================================================================

format_age()
{
    local poh="$1" days years months

    [[ "$poh" =~ ^[0-9]+$ ]] || {
        printf '%10s' "-"
        return
    }

    days=$((poh / 24))
    years=$((days / 365))
    days=$((days % 365))

    months=$((days / 30))
    days=$((days % 30))

    # Never display 12 months.
    if (( months == 12 )); then years=$(( years + 1 )); months=0; fi

    printf '%2dy %2dm %2dd' "$years" "$months" "$days"
}


# =============================================================================
# PROCESS DRIVE
# =============================================================================
#
# One smartctl call per drive.
#
# Extract: MODEL FIRMWARE SERIAL SIZE HEALTH POH TEMP LIFE ROTATION DEVTYPE PROTOCOL REALLOC UNCORR
# Missing values are represented by "-" so Bash field positions remain stable.
#
# =============================================================================

process_drive()
{
    local scan_entry="$1" device scan_type json smart_data

    IFS=$'\t' read -r device scan_type <<< "$scan_entry"

    # -------------------------------------------------------------------------
    # Query the drive once.
    #
    # smartctl exit status is deliberately not used as the success test.
    # SMART warnings can cause a non-zero smartctl status while still returning
    # useful JSON containing the information we want.
    # -------------------------------------------------------------------------

    # -j JSON, -i identity, -H health, -A attributes, -l ssd SSD statistics. Deliberately no -a.
    json=$(smartctl -j -i -H -A -l ssd -d "$scan_type" "$device" 2>/dev/null)

    [[ -n "$json" ]] || {
        FAILED_DEVICES+=("$device")
        return 1
    }

    # Extract all values with one jq query.
    # "-" is used for unavailable values so Bash field positions stay stable.
    # SMART attribute 5   = Reallocated_Sector_Ct
    # SMART attribute 198 = Offline_Uncorrectable

    if ! smart_data=$(jq -r '
        [
            (.model_name // "-"),
            (.firmware_version // "-"),
            (.serial_number // "-"),
            (.user_capacity.bytes // "-"),
            (if .smart_status.passed == true then "PASSED" elif .smart_status.passed == false then "FAILED" else "UNKNOWN" end),
            (.power_on_time.hours // "-"),
            (.temperature.current // "-"),
            (.endurance_used.current_percent // "-"),
            (.rotation_rate // "-"),
            (.device.type // "-"),
            (.device.protocol // "-"),
            ([.ata_smart_attributes.table[]? | select(.id == 5) | .raw.value] | first // "-"),
            ([.ata_smart_attributes.table[]? | select(.id == 198) | .raw.value] | first // "-")
        ]
        | @tsv
    ' <<< "$json")
    then
        FAILED_DEVICES+=("$device")
        return 1
    fi

    [[ -n "$smart_data" ]] || {
        FAILED_DEVICES+=("$device")
        return 1
    }

    # -------------------------------------------------------------------------
    # Read the single jq result.
    # -------------------------------------------------------------------------

    local model firmware serial size_bytes health poh temp_c
    local endurance_used rotation_rate device_type protocol realloc uncorrectable

    IFS=$'\t' read -r model firmware serial size_bytes health poh temp_c \
        endurance_used rotation_rate device_type protocol realloc uncorrectable <<< "$smart_data"

    # -------------------------------------------------------------------------
    # Basic information.
    # -------------------------------------------------------------------------

    if [[ "$model" == "-" || -z "$model" ]]; then FAILED_DEVICES+=("$device"); return 1; fi

    local kernel devtype life

    kernel="${device##*/}"
    devtype=$(get_drive_type "$device_type" "$protocol" "$rotation_rate")
    if (( ${#model} > MODEL_MAX_LENGTH )); then model="${model:0:$((MODEL_MAX_LENGTH - 1))}…"; fi

    # -------------------------------------------------------------------------
    # LIFE
    # -------------------------------------------------------------------------
    #
    # LIFE applies only to SSD/NVMe.
    #
    # endurance_used.current_percent is the percentage already used.
    #
    # Therefore:
    #
    #   remaining life = 100 - endurance used
    #
    # HDDs always get "-".
    # -------------------------------------------------------------------------

    life="-"

    if [[ "$devtype" != "HDD" && "$endurance_used" =~ ^[0-9]+$ ]]; then
        life=$((100 - endurance_used)); (( life < 0 )) && life=0; (( life > 100 )) && life=100
    fi

    # -------------------------------------------------------------------------
    # REALLOC / UNCORR
    #
    # These are HDD-only.
    # -------------------------------------------------------------------------

    if [[ "$devtype" != "HDD" ]]; then realloc="-"; uncorrectable="-"; fi

    # -------------------------------------------------------------------------
    # Store raw row.
    # -------------------------------------------------------------------------

    RESULTS+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        "$kernel" "$devtype" "$model" "$firmware" "$serial" "$size_bytes" "$health" \
        "$poh" "$temp_c" "$life" "$realloc" "$uncorrectable")")
}

# =============================================================================
# SORT RESULTS
# =============================================================================

sort_results()
{
    local sort_column_number sort_options=() sorted_output

    case "$SORT_COLUMN" in
        KERNEL)   sort_column_number=1 ;;
        DEVTYPE)  sort_column_number=2 ;;
        MODEL)    sort_column_number=3 ;;
        FIRMWARE) sort_column_number=4 ;;
        SERIAL)   sort_column_number=5 ;;
        SIZE)     sort_column_number=6; sort_options+=(-n) ;;
        HEALTH)   sort_column_number=7 ;;
        POH)      sort_column_number=8; sort_options+=(-n) ;;
        TEMP)     sort_column_number=9; sort_options+=(-n) ;;
        AGE)      sort_column_number=8; sort_options+=(-n) ;;
        LIFE)     sort_column_number=10; sort_options+=(-n) ;;
        REALLOC)  sort_column_number=11; sort_options+=(-n) ;;
        UNCORR)   sort_column_number=12; sort_options+=(-n) ;;
    esac

    [[ "$SORT_DIRECTION" == "DESC" ]] && sort_options+=(-r)

    sorted_output=$(
        printf '%s\n' "${RESULTS[@]}" |
            sort -t $'\t' -k"${sort_column_number},${sort_column_number}" "${sort_options[@]}"
    )

    RESULTS=()
    while IFS= read -r row; do
        [[ -n "$row" ]] && RESULTS+=("$row")
    done <<< "$sorted_output"
}

# =============================================================================
# PRINT TABLE
# =============================================================================

print_table()
{
    local header underline table_data="" row i

    header=$'KERNEL\tDEVTYPE\tMODEL\tFIRMWARE\tSERIAL\tSIZE\tHEALTH\tPOH\tTEMP\tAGE\tLIFE\tREALLOC\tUNCORR'

    # Make an underline matching the header.
    underline=""
    for ((i = 0; i < ${#header}; i++)); do
        [[ "${header:i:1}" == $'\t' ]] && underline+=$'\t' || underline+='-'
done

    # Header and underline use the same light-blue color.
    table_data+="${COLOR_LIGHT_BLUE}${header}${COLOR_RESET}"$'\n'
    table_data+="${COLOR_LIGHT_BLUE}${underline}${COLOR_RESET}"$'\n'

    for row in "${RESULTS[@]}"; do
        local kernel devtype model firmware serial size_bytes health poh temp_c life realloc uncorrectable
        IFS=$'\t' read -r kernel devtype model firmware serial size_bytes health poh temp_c life realloc uncorrectable <<< "$row"
        local size age display_health display_temp display_life display_realloc display_uncorrectable
        local temp_display temp_value green_max yellow_max temp_color life_color realloc_color uncorrectable_color

        size="-"
        if [[ "$size_bytes" =~ ^[0-9]+$ ]]; then
            if [[ "$SIZE_UNIT" == "SI" ]]; then
                size=$(numfmt --to=si --suffix=B "$size_bytes" 2>/dev/null || echo "-")
            else
                size=$(numfmt --to=iec-i --suffix=B "$size_bytes" 2>/dev/null || echo "-")
            fi
        fi
        age=$(format_age "$poh")

        case "$health" in
            PASSED) display_health="${COLOR_GREEN}${health}${COLOR_RESET}" ;;
            FAILED) display_health="${COLOR_RED}${health}${COLOR_RESET}" ;;
            *) display_health="${COLOR_YELLOW}${health}${COLOR_RESET}" ;;
        esac

        display_temp="-" display_life="-" display_realloc="-" display_uncorrectable="-"

        if [[ "$temp_c" != "-" ]]; then
            temp_c=${temp_c%%.*}
            if [[ "$TEMP_UNIT" == "F" ]]; then
                temp_display="$(( temp_c * 9 / 5 + 32 ))°F"; temp_value="$(( temp_c * 9 / 5 + 32 ))"
                green_max="$TEMP_GREEN_MAX"; yellow_max="$TEMP_YELLOW_MAX"
            else
                temp_display="${temp_c}°C"; temp_value="$temp_c"
                green_max="$TEMP_GREEN_MAX"; yellow_max="$TEMP_YELLOW_MAX"
            fi
            if (( temp_value <= green_max )); then temp_color="$COLOR_GREEN"
            elif (( temp_value <= yellow_max )); then temp_color="$COLOR_YELLOW"
            else temp_color="$COLOR_RED"
            fi
            display_temp="${temp_color}${temp_display}${COLOR_RESET}"
        fi

        if [[ "$life" != "-" ]]; then
            if (( life >= LIFE_GREEN_MIN )); then life_color="$COLOR_GREEN"
            elif (( life >= LIFE_YELLOW_MIN )); then life_color="$COLOR_YELLOW"
            else life_color="$COLOR_RED"
            fi
            display_life="${life_color}${life}%${COLOR_RESET}"
        fi

        if [[ "$realloc" != "-" ]]; then
            if (( realloc == 0 )); then realloc_color="$COLOR_GREEN"; else realloc_color="$COLOR_RED"; fi
            display_realloc="${realloc_color}${realloc}${COLOR_RESET}"
        fi

        if [[ "$uncorrectable" != "-" ]]; then
            if (( uncorrectable == 0 )); then uncorrectable_color="$COLOR_GREEN"; else uncorrectable_color="$COLOR_RED"; fi
            display_uncorrectable="${uncorrectable_color}${uncorrectable}${COLOR_RESET}"
        fi

        table_data+="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
            "$kernel" "$devtype" "$model" "$firmware" "$serial" "$size" "$display_health" \
            "$poh" "$display_temp" "$age" "$display_life" "$display_realloc" "$display_uncorrectable")"$'\n'
    done

    printf '%s' "$table_data" | column -t -s $'\t'
}

# =============================================================================
# FAILED DEVICES
# =============================================================================

print_failed_devices()
{
    ((${#FAILED_DEVICES[@]} > 0)) || return

    echo

    printf '%sFailed SMART queries:%s\n' "$COLOR_RED" "$COLOR_RESET"

    local device
    for device in "${FAILED_DEVICES[@]}"; do printf '  %s\n' "$device"; done
}

# =============================================================================
# MAIN
# =============================================================================

validate_config
check_dependencies

echo
echo "SMART Drive Health Report"
echo "========================="
echo

discover_drives

total=${#DRIVE_DEVICES[@]}
current=0

printf 'Found %d SMART-capable device(s).\n\n' "$total"

for scan_entry in "${DRIVE_DEVICES[@]}"; do
    ((current++))
    device="${scan_entry%%$'\t'*}"
    print_progress "$current" "$total" "$device"
    process_drive "$scan_entry"
done

finish_progress

successful=${#RESULTS[@]}
failed=${#FAILED_DEVICES[@]}

((successful > 0 )) || die "No drives returned usable SMART information."

printf 'SMART processing complete: %d OK, %d failed.\n' "$successful" "$failed"

sort_results

echo
print_table
print_failed_devices
echo
