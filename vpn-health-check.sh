#!/bin/sh

# OpenWrt VPN/DNS quick diagnostic collector.
#
# Recommended placement on router:
#   /root/vpn-health-check.sh or /usr/bin/vpn-health-check.sh
#
# Usage:
#   sh vpn-health-check.sh                       # compact output + /tmp/vpn-health-check.txt
#   sh vpn-health-check.sh --full               # include full UCI dumps
#   sh vpn-health-check.sh -o /tmp/out.txt      # compact output + custom file
#   sh vpn-health-check.sh -                    # stdout only (no file)
#   sh vpn-health-check.sh -h                   # help

DEFAULT_OUTPUT_FILE="/tmp/vpn-health-check.txt"
OUTPUT_MODE="tee"
OUTPUT_FILE="$DEFAULT_OUTPUT_FILE"
FULL_MODE=0

usage() {
    cat <<'USAGE'
OpenWrt VPN/DNS quick diagnostic collector

Usage:
  sh vpn-health-check.sh
      Compact diagnostics to stdout and /tmp/vpn-health-check.txt

  sh vpn-health-check.sh --full
      Include full UCI dumps for network/firewall/dhcp/openvpn

  sh vpn-health-check.sh -o /tmp/your-file.txt
      Write to stdout and selected file

  sh vpn-health-check.sh -
      Print to stdout only (no output file)
USAGE
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --full)
                FULL_MODE=1
                ;;
            -o|--output)
                shift
                if [ "$#" -eq 0 ]; then
                    echo "error: missing value for --output" >&2
                    exit 1
                fi
                OUTPUT_MODE="tee"
                OUTPUT_FILE="$1"
                ;;
            -)
                OUTPUT_MODE="stdout"
                OUTPUT_FILE=""
                ;;
            *)
                # Backward compatibility: first positional arg is output file path.
                OUTPUT_MODE="tee"
                OUTPUT_FILE="$1"
                ;;
        esac
        shift
    done
}

log() {
    printf '%s\n' "$*"
}

section() {
    log
    log "===== $1 ====="
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

run() {
    # Usage: run "description" command [args...]
    desc="$1"
    shift
    section "$desc"
    if have_cmd "$1"; then
        "$@"
    else
        log "[skip] command not found: $1"
    fi
}

run_logread_filter() {
    section "OPENVPN LOG (tail)"
    if have_cmd logread; then
        logread | grep -Ei 'openvpn|tls|handshake|route|tun0|reconnect|resolve|network unreachable|Initialization Sequence Completed' | tail -n 120
    else
        log "[skip] command not found: logread"
    fi
}

run_uci_show() {
    # Usage: run_uci_show "title" "target"
    title="$1"
    target="$2"

    section "$title"
    if have_cmd uci; then
        uci show "$target"
    else
        log "[skip] command not found: uci"
    fi
}

run_uci_grep() {
    # Usage: run_uci_grep "title" "target" "pattern"
    title="$1"
    target="$2"
    pattern="$3"

    section "$title"
    if have_cmd uci; then
        uci show "$target" | grep -E "$pattern" || true
    else
        log "[skip] command not found: uci"
    fi
}

run_dns_tests() {
    section "DNS TESTS"
    if ! have_cmd nslookup; then
        log "[skip] command not found: nslookup"
        return
    fi

    for server in 127.0.0.1 192.168.8.1 198.18.0.1 198.18.0.2 1.1.1.1 8.8.8.8; do
        log "--- nslookup google.com $server ---"
        nslookup google.com "$server" || true
        log
    done

    section "PUBLIC IP / DNS LEAK CHECK HOSTS"
    log "--- nslookup myip.opendns.com resolver1.opendns.com ---"
    nslookup myip.opendns.com resolver1.opendns.com || true
    log
    log "--- nslookup o-o.myaddr.l.google.com ns1.google.com ---"
    nslookup o-o.myaddr.l.google.com ns1.google.com || true
}

run_compact_uci() {
    run_uci_grep "OPENVPN (important)" "openvpn" 'enabled|config|auth|remote|proto|pull|dhcp-option|route|dev|resolv-retry'

    run_uci_grep "NETWORK (important)" "network" '^network\.(wan|vpn|lan|globals)\.|^network\.(wan|vpn|lan)='

    run_uci_grep "FIREWALL (vpn/dns relevant)" "firewall" 'name=.*(DNS|vpn|VPN)|@zone\[[0-9]+\]\.name=|@zone\[[0-9]+\]\.network=|@forwarding\[[0-9]+\]|dest_port=.53|dest_port=.853|src_dport=.53|target='

    run_uci_grep "DHCP/DNSMASQ (important)" "dhcp" '^dhcp\.@dnsmasq\[0\]\.(noresolv|resolvfile|server|doh_|strictorder|allservers)|^dhcp\.lan\.dhcp_option|^dhcp\.@dnsmasq\[0\]='
}

run_full_uci() {
    run_uci_show "OPENVPN UCI (full)" "openvpn"
    run_uci_show "NETWORK UCI (full)" "network"
    run_uci_show "FIREWALL UCI (full)" "firewall"
    run_uci_show "DHCP UCI (full)" "dhcp"
}

main() {
    section "TIME"
    date

    run "INTERFACES (ip -4 a)" ip -4 a
    run "ROUTES (ip -4 r)" ip -4 r

    section "OPENVPN PROCESS"
    if have_cmd ps; then
        ps w | grep -E '[o]penvpn' || true
    else
        log "[skip] command not found: ps"
    fi

    run_logread_filter

    if [ "$FULL_MODE" -eq 1 ]; then
        run_full_uci
    else
        run_compact_uci
    fi

    section "DNSMASQ RUNTIME"
    if have_cmd ps; then
        ps w | grep '[d]nsmasq' || true
    else
        log "[skip] command not found: ps"
    fi

    section "RESOLV FILES"
    if have_cmd ls; then
        ls -l /tmp/resolv.conf* 2>/dev/null || true
    fi

    log "--- /tmp/resolv.conf ---"
    cat /tmp/resolv.conf 2>/dev/null || true
    log "--- /tmp/resolv.conf.d/resolv.conf.auto ---"
    cat /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null || true

    run_dns_tests

    if [ "$FULL_MODE" -eq 0 ]; then
        section "NOTE"
        log "Compact mode enabled. Use --full to include full UCI dumps."
    fi
}

parse_args "$@"

if [ "$OUTPUT_MODE" = "tee" ]; then
    main | tee "$OUTPUT_FILE"
    echo
    echo "Saved diagnostic output to: $OUTPUT_FILE" >&2
else
    main
fi
