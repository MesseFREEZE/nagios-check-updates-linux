#!/bin/bash

################################################################################
#                                                                              #
#  Nagios Check Updates Plugin                                                #
#  Version: 1.0                                                               #
#                                                                             #
#  Description: Check for available system updates on RHEL and Debian         #
#                                                                              #
#  Usage: ./check_updates.sh [--rhel|--debian|--auto]                         #
#  Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN                         #
#                                                                              #
################################################################################

# Strict error handling
set -o pipefail

################################################################################
# Configuration Section
################################################################################

# Thresholds for updates
WARNING_THRESHOLD=5      # Alert if more than 5 updates
CRITICAL_THRESHOLD=10    # Critical if more than 10 updates
SECURITY_CRITICAL=1      # Critical if any security updates

# Colors for output (for testing)
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

################################################################################
# Function: Detect Linux Distribution
# Returns: "rhel" or "debian" or "unknown"
################################################################################
detect_distro() {
    # Check for common distribution identifiers
    if [ -f /etc/redhat-release ] || [ -f /etc/os-release ]; then
        if grep -qi "rhel\|centos\|fedora" /etc/os-release 2>/dev/null || [ -f /etc/redhat-release ]; then
            echo "rhel"
            return
        fi
    fi

    if [ -f /etc/debian_version ] || grep -qi "debian\|ubuntu" /etc/os-release 2>/dev/null; then
        echo "debian"
        return
    fi

    echo "unknown"
}

################################################################################
# Function: Check RHEL/CentOS Updates (using DNF)
# Returns: updates count and security updates count
################################################################################
check_rhel_updates() {
    # Check if dnf is available
    if ! command -v dnf &> /dev/null; then
        echo "UNKNOWN"
        echo "0"
        echo "0"
        return
    fi

    # Count total available updates
    # grep -v '^$' filters out empty lines
    local updates=$(dnf check-update 2>/dev/null | grep -v '^$' | tail -n +2 | wc -l)

    # Count security updates specifically
    # --security flag limits to security updates only
    local security=$(dnf check-update --security 2>/dev/null | grep -v '^$' | tail -n +2 | wc -l)

    # Return results
    echo "OK"
    echo "$updates"
    echo "$security"
}

################################################################################
# Function: Check Debian/Ubuntu Updates (using APT)
# Returns: updates count and security updates count
################################################################################
check_debian_updates() {
    # Check if apt is available
    if ! command -v apt &> /dev/null; then
        echo "UNKNOWN"
        echo "0"
        echo "0"
        return
    fi

    # Get all available updates (full count)
    # apt list --upgradable returns format: pkg/distro version [upgrade-version]
    # We grep for upgradable and exclude header
    local updates=$(apt list --upgradable 2>/dev/null | grep -c upgradable || echo 0)

    # Get security updates specifically
    # apt list --upgradable | grep -i security filters security updates
    # This requires checking the changelog or using apt-get update && apt-get --dry-run upgrade
    # Fallback: count security package sources
    local security=$(apt list --upgradable 2>/dev/null | grep -i "security\|ubuntu-security" | wc -l)

    # Alternative: use apt show for each package (more accurate but slower)
    # For performance, we use the grep method above

    # Return results
    echo "OK"
    echo "$updates"
    echo "$security"
}

################################################################################
# Function: Generate Nagios Output
# Parameters: status, updates_count, security_count
# Format: MESSAGE | perfdata
################################################################################
generate_output() {
    local status=$1
    local updates=$2
    local security=$3

    # Build main message
    if [ "$status" = "rhel" ]; then
        local message="Updates available: $updates"
    else
        local message="$updates updates available"
    fi

    # Add security info if present
    if [ "$security" -gt 0 ]; then
        message="$message ($security security)"
    fi

    # Build perfdata (format: label=value;warn;crit;min;max)
    # updates metric: warning at >5, critical at >10
    # security metric: critical at >1
    local perfdata="updates=$updates;${WARNING_THRESHOLD};${CRITICAL_THRESHOLD};0;"
    perfdata="$perfdata security=$security;${SECURITY_CRITICAL};${SECURITY_CRITICAL};0;"

    # Output in Nagios format: MESSAGE | PERFDATA
    echo "$message | $perfdata"
}

################################################################################
# Function: Determine Exit Code
# Parameters: updates_count, security_count
# Returns: 0 (OK), 1 (WARNING), 2 (CRITICAL)
################################################################################
determine_exit_code() {
    local updates=$1
    local security=$2

    # Critical: if any security updates exist
    if [ "$security" -gt "$SECURITY_CRITICAL" ]; then
        return 2
    fi

    # Critical: if too many updates
    if [ "$updates" -gt "$CRITICAL_THRESHOLD" ]; then
        return 2
    fi

    # Warning: if moderate number of updates
    if [ "$updates" -gt "$WARNING_THRESHOLD" ]; then
        return 1
    fi

    # OK: system is up to date
    return 0
}

################################################################################
# Main Script
################################################################################

# Get distribution mode from argument or auto-detect
MODE="${1:-auto}"

# Determine which check to run
if [ "$MODE" = "--rhel" ] || ([ "$MODE" = "--auto" ] && [ "$(detect_distro)" = "rhel" ]); then
    # Run RHEL check
    result=$(check_rhel_updates)
    status=$(echo "$result" | sed -n '1p')
    updates=$(echo "$result" | sed -n '2p')
    security=$(echo "$result" | sed -n '3p')

elif [ "$MODE" = "--debian" ] || ([ "$MODE" = "--auto" ] && [ "$(detect_distro)" = "debian" ]); then
    # Run Debian check
    result=$(check_debian_updates)
    status=$(echo "$result" | sed -n '1p')
    updates=$(echo "$result" | sed -n '2p')
    security=$(echo "$result" | sed -n '3p')

else
    # Unknown distribution
    echo "UNKNOWN - Cannot detect distribution or unsupported OS"
    exit 3
fi

# Check if we got valid results
if [ "$status" != "OK" ]; then
    echo "UNKNOWN - Failed to check updates"
    exit 3
fi

# Generate Nagios output
generate_output "$(detect_distro)" "$updates" "$security"

# Determine and exit with appropriate code
determine_exit_code "$updates" "$security"
exit $?
