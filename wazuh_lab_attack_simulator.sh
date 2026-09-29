#!/usr/bin/env bash
set -u

# ============================================================
# Wazuh Lab Attack Simulator
# Kali -> Ubuntu + Windows
#
# Default lab targets:
#   Ubuntu : 192.168.187.131
#   Wazuh  : 192.168.187.130
#   Windows: 192.168.187.132
#
# IMPORTANT:
# Use ONLY against systems you own/control in your isolated lab.
# This script intentionally uses small, bounded test counts.
# ============================================================

UBUNTU_IP="${UBUNTU_IP:-192.168.187.131}"
WINDOWS_IP="${WINDOWS_IP:-192.168.187.132}"
WAZUH_IP="${WAZUH_IP:-192.168.187.130}"

UBUNTU_USER="${UBUNTU_USER:-labtest}"
WINDOWS_USER="${WINDOWS_USER:-labtest}"

# Deliberately invalid password used only to generate failed-logon events.
LAB_BAD_PASS="${LAB_BAD_PASS:-WrongLabPass!2026}"

COUNT="${COUNT:-6}"

log()  { printf '\n[+] %s\n' "$*"; }
warn() { printf '\n[!] %s\n' "$*"; }
die()  { printf '\n[-] %s\n' "$*" >&2; exit 1; }

need_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "Run with: sudo bash $0"
    fi
}

valid_lab_ip() {
    local ip="$1"
    [[ "$ip" =~ ^(10\.) ]] && return 0
    [[ "$ip" =~ ^192\.168\. ]] && return 0
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
    return 1
}

check_target_ips() {
    valid_lab_ip "$UBUNTU_IP" || die "Ubuntu IP is not RFC1918/private: $UBUNTU_IP"
    valid_lab_ip "$WINDOWS_IP" || die "Windows IP is not RFC1918/private: $WINDOWS_IP"
}

install_tools() {
    log "Installing/checking Kali tools..."

    apt-get update
    apt-get install -y nmap netcat-openbsd openssh-client sshpass curl dnsutils

    if ! command -v xfreerdp >/dev/null 2>&1; then
        warn "xfreerdp is not installed. Searching available FreeRDP packages..."
        apt-cache search '^freerdp' | head -20 || true
        warn "Install the suitable FreeRDP client package for your Kali release, then rerun."
    fi
}

pause_step() {
    read -r -p "Press Enter to continue..." _
}

host_check() {
    log "Host reachability"
    ping -c 2 -W 2 "$UBUNTU_IP" || true
    ping -c 2 -W 2 "$WINDOWS_IP" || true
    ping -c 2 -W 2 "$WAZUH_IP" || true
}

recon() {
    log "TEST 1 - Host discovery"
    nmap -sn "${UBUNTU_IP}/32" "${WINDOWS_IP}/32"

    log "TEST 2 - Service enumeration: Ubuntu"
    nmap -sV -p 22,80,443,445,3306,3389,5985,5986 "$UBUNTU_IP"

    log "TEST 3 - Service enumeration: Windows"
    nmap -sV -p 22,80,443,135,139,445,3389,5985,5986 "$WINDOWS_IP"

    log "TEST 4 - Selected port checks"
    for port in 22 80 443 3389 445; do
        nc -zvw 2 "$UBUNTU_IP" "$port" || true
        nc -zvw 2 "$WINDOWS_IP" "$port" || true
    done
}

ssh_failures() {
    log "TEST 5 - Ubuntu SSH failed-logon simulation"
    if ! nc -zvw 2 "$UBUNTU_IP" 22 >/dev/null 2>&1; then
        warn "Ubuntu SSH port 22 is not open. Skipping SSH test."
        return
    fi

    for ((i=1; i<=COUNT; i++)); do
        printf '[SSH] Attempt %d/%d\n' "$i" "$COUNT"
        sshpass -p "$LAB_BAD_PASS" ssh \
            -o StrictHostKeyChecking=no \
            -o PreferredAuthentications=password \
            -o PubkeyAuthentication=no \
            -o ConnectTimeout=4 \
            "${UBUNTU_USER}@${UBUNTU_IP}" 'exit' >/dev/null 2>&1 || true
        sleep 1
    done

    cat <<EOF

Expected SOC/Wazuh evidence on Ubuntu:
- Failed SSH authentication events
- Username: ${UBUNTU_USER}
- Source IP: Kali IP
- Repeated failures in a short time window

Useful Wazuh search terms:
  authentication_failed
  ssh
EOF
}

windows_ssh_failures() {
    log "TEST 6 - Windows SSH failed-logon simulation"
    if ! nc -zvw 2 "$WINDOWS_IP" 22 >/dev/null 2>&1; then
        warn "Windows SSH port 22 is not open. Skipping Windows SSH test."
        return
    fi

    for ((i=1; i<=COUNT; i++)); do
        printf '[WIN-SSH] Attempt %d/%d\n' "$i" "$COUNT"
        sshpass -p "$LAB_BAD_PASS" ssh \
            -o StrictHostKeyChecking=no \
            -o PreferredAuthentications=password \
            -o PubkeyAuthentication=no \
            -o ConnectTimeout=4 \
            "${WINDOWS_USER}@${WINDOWS_IP}" 'exit' >/dev/null 2>&1 || true
        sleep 1
    done

    cat <<EOF

Expected Windows evidence:
- Failed Windows logon telemetry
- If Security auditing is configured, look for Event ID 4625
- Depending on OpenSSH/Windows configuration, also inspect OpenSSH logs

Useful Wazuh search:
  data.win.system.eventID:4625
EOF
}

windows_rdp_failures() {
    log "TEST 7 - Windows RDP failed-logon simulation"

    if ! nc -zvw 2 "$WINDOWS_IP" 3389 >/dev/null 2>&1; then
        warn "Windows RDP port 3389 is not open. Skipping RDP test."
        return
    fi

    if ! command -v xfreerdp >/dev/null 2>&1; then
        warn "xfreerdp is missing. Skipping RDP test."
        return
    fi

    for ((i=1; i<=COUNT; i++)); do
        printf '[RDP] Attempt %d/%d\n' "$i" "$COUNT"
        timeout 10 xfreerdp \
            "/v:${WINDOWS_IP}" \
            "/u:${WINDOWS_USER}" \
            "/p:${LAB_BAD_PASS}" \
            /cert:ignore \
            /sec:nla >/dev/null 2>&1 || true
        sleep 2
    done

    cat <<EOF

Expected Windows evidence:
- Event ID 4625 = failed logon
- Source IP should be the Kali address
- Review LogonType, TargetUserName and IpAddress
EOF
}

dns_test() {
    log "TEST 8 - DNS activity simulation"

    if command -v dig >/dev/null 2>&1; then
        dig example.com
        dig A example.com
        dig MX example.com
    else
        nslookup example.com
    fi
}

http_test() {
    log "TEST 9 - HTTP activity simulation"

    # Only run if HTTP is actually exposed.
    if nc -zvw 2 "$WINDOWS_IP" 80 >/dev/null 2>&1; then
        curl -I --max-time 5 "http://${WINDOWS_IP}" || true
        for ((i=1; i<=10; i++)); do
            curl -s --max-time 5 "http://${WINDOWS_IP}" >/dev/null || true
        done
    else
        warn "Windows HTTP port 80 is not open. Skipping HTTP test."
    fi

    if nc -zvw 2 "$UBUNTU_IP" 80 >/dev/null 2>&1; then
        curl -I --max-time 5 "http://${UBUNTU_IP}" || true
        for ((i=1; i<=10; i++)); do
            curl -s --max-time 5 "http://${UBUNTU_IP}" >/dev/null || true
        done
    else
        warn "Ubuntu HTTP port 80 is not open. Skipping HTTP test."
    fi
}

report() {
    log "LAB COMPLETE"

    cat <<EOF

Targets:
  Ubuntu : ${UBUNTU_IP}
  Windows: ${WINDOWS_IP}
  Wazuh  : ${WAZUH_IP}

Attack/Test phases:
  1. Host discovery
  2. Service enumeration
  3. Port connectivity
  4. Ubuntu SSH failed logons
  5. Windows SSH failed logons
  6. Windows RDP failed logons
  7. DNS activity
  8. HTTP activity

Recommended Wazuh checks:

Windows failed logon:
  data.win.system.eventID:4625

Successful Windows logon:
  data.win.system.eventID:4624

Authentication failures:
  authentication_failed

For investigation, record:
  Source IP
  Destination IP
  Username
  Event ID
  Rule ID
  Timestamp
  Number of attempts
  Logon Type
  Related events
  Verdict

Remember:
  No telemetry = no detection.
  A successful attack simulation is useful only when you can
  trace it through logs and investigate it in Wazuh.
EOF
}

main() {
    need_root
    check_target_ips
    install_tools

    log "Configuration"
    printf 'Ubuntu : %s\nWindows: %s\nWazuh  : %s\nCount  : %s\n' \
        "$UBUNTU_IP" "$WINDOWS_IP" "$WAZUH_IP" "$COUNT"

    host_check
    pause_step
    recon
    pause_step
    ssh_failures
    pause_step
    windows_ssh_failures
    pause_step
    windows_rdp_failures
    pause_step
    dns_test
    pause_step
    http_test
    report
}

main "$@"
