#!/bin/sh

# Enforce DNS + IP anti-leak baseline for LAN clients behind OpenVPN.
# Intended for OpenWrt 24.x with firewall4 (nftables) and dnsmasq.

VPN_IFACE="vpn"
VPN_DEVICE="tun0"
LAN_NET="lan"
WAN_NET="wan"
DNS_LIST="1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4"
LAN_DNS_IP="$(uci -q get network.lan.ipaddr 2>/dev/null || echo 192.168.8.1)"
FAILED=0

log() {
	echo "[vpn-antileak] $*"
}

run_or_warn() {
	if "$@"; then
		return 0
	fi
	log "WARN: command failed: $*"
	FAILED=1
	return 0
}

ensure_dnsmasq_section() {
	if uci -q get dhcp.@dnsmasq[0] >/dev/null 2>&1; then
		return 0
	fi
	log "dnsmasq section missing in UCI dhcp, creating one"
	run_or_warn uci add dhcp dnsmasq >/dev/null
}

# delete_firewall_entries_by_prefix <rule|redirect> <prefix>
delete_firewall_entries_by_prefix() {
	entry_type="$1"
	entry_prefix_lc="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
	uci -q show firewall | sed -n "s/^firewall\.\(@${entry_type}\[[0-9]\+\]\)\.name='\(.*\)'$/\1|\2/p" | 	while IFS='|' read -r section entry_name; do
		entry_name_lc="$(printf '%s' "$entry_name" | tr '[:upper:]' '[:lower:]')"
		case "$entry_name_lc" in
			"$entry_prefix_lc"*) run_or_warn uci -q delete "firewall.${section}" ;;
		esac
	done
}

log "Pin WAN and dnsmasq DNS upstreams"
run_or_warn uci set network.wan.peerdns='0'
run_or_warn uci -q delete network.wan.dns
for dns in $DNS_LIST; do
	run_or_warn uci add_list network.wan.dns="$dns"
done

run_or_warn uci set network.${VPN_IFACE}='interface'
run_or_warn uci set network.${VPN_IFACE}.proto='none'
run_or_warn uci set network.${VPN_IFACE}.device="$VPN_DEVICE"

ensure_dnsmasq_section
run_or_warn uci set dhcp.@dnsmasq[0].noresolv='1'
run_or_warn uci -q delete dhcp.@dnsmasq[0].server
for dns in $DNS_LIST; do
	run_or_warn uci add_list dhcp.@dnsmasq[0].server="$dns"
done

# Keep IPv6 from bypassing IPv4-only VPN setups.
run_or_warn uci -q set network.lan.ip6assign='0'
if uci -q get network.wan6 >/dev/null 2>&1; then
	run_or_warn uci set network.wan6.proto='none'
else
	log "Skipping network.wan6.proto=none (wan6 section not present)"
fi

log "Ensure only LAN->VPN forwarding"
while uci -q delete firewall.@forwarding[0] >/dev/null 2>&1; do :; done
fw_fwd="$(uci add firewall forwarding 2>/dev/null || true)"
if [ -n "$fw_fwd" ]; then
	run_or_warn uci set firewall.${fw_fwd}.src="$LAN_NET"
	run_or_warn uci set firewall.${fw_fwd}.dest="$VPN_IFACE"
else
	log "WARN: failed to create firewall forwarding section"
	FAILED=1
fi

log "Recreate DNS block + redirect + kill-switch rules"
delete_firewall_entries_by_prefix rule 'Block-DNS-from-LAN-to-WAN-'
delete_firewall_entries_by_prefix redirect 'Force-DNS-to-Router-'
delete_firewall_entries_by_prefix rule 'KillSwitch-LAN-to-WAN'

for proto in tcp udp; do
	upper_proto="$(printf '%s' "$proto" | tr '[:lower:]' '[:upper:]')"
	rule_id="$(uci add firewall rule 2>/dev/null || true)"
	if [ -z "$rule_id" ]; then
		log "WARN: failed to add firewall rule for ${proto} DNS block"
		FAILED=1
		continue
	fi
	run_or_warn uci set firewall.${rule_id}.name="Block-DNS-from-LAN-to-WAN-${upper_proto}"
	run_or_warn uci set firewall.${rule_id}.src="$LAN_NET"
	run_or_warn uci set firewall.${rule_id}.dest="$WAN_NET"
	run_or_warn uci set firewall.${rule_id}.proto="$proto"
	run_or_warn uci set firewall.${rule_id}.dest_port='53'
	run_or_warn uci set firewall.${rule_id}.target='DROP'
done

for proto in tcp udp; do
	upper_proto="$(printf '%s' "$proto" | tr '[:lower:]' '[:upper:]')"
	redir_id="$(uci add firewall redirect 2>/dev/null || true)"
	if [ -z "$redir_id" ]; then
		log "WARN: failed to add firewall redirect for ${proto} DNS force"
		FAILED=1
		continue
	fi
	run_or_warn uci set firewall.${redir_id}.name="Force-DNS-to-Router-${upper_proto}"
	run_or_warn uci set firewall.${redir_id}.src="$LAN_NET"
	run_or_warn uci set firewall.${redir_id}.src_dport='53'
	run_or_warn uci set firewall.${redir_id}.proto="$proto"
	run_or_warn uci set firewall.${redir_id}.target='DNAT'
	run_or_warn uci set firewall.${redir_id}.dest='lan'
	run_or_warn uci set firewall.${redir_id}.dest_ip="$LAN_DNS_IP"
	run_or_warn uci set firewall.${redir_id}.dest_port='53'
done

kill_id="$(uci add firewall rule 2>/dev/null || true)"
if [ -n "$kill_id" ]; then
	run_or_warn uci set firewall.${kill_id}.name='KillSwitch-LAN-to-WAN'
	run_or_warn uci set firewall.${kill_id}.src="$LAN_NET"
	run_or_warn uci set firewall.${kill_id}.dest="$WAN_NET"
	run_or_warn uci set firewall.${kill_id}.target='REJECT'
else
	log "WARN: failed to add KillSwitch-LAN-to-WAN"
	FAILED=1
fi

log "Commit and reload services"
run_or_warn uci commit network
run_or_warn uci commit dhcp
run_or_warn uci commit firewall

# Apply only services needed for new settings.
run_or_warn /etc/init.d/dnsmasq reload
run_or_warn /etc/init.d/firewall reload

if [ "$FAILED" -eq 0 ]; then
	log "Anti-leak baseline applied"
else
	log "Finished with warnings; review log lines above"
fi
