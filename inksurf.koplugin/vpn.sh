#!/bin/sh
# BookFetch – VPN controller for Kindle (OpenVPN + disabling IPv6 + kill switch + DNS)
#
# Usage:
#   sh vpn.sh up <file.ovpn> <auth.txt>
#   sh vpn.sh down
#   sh vpn.sh status
#
# The last output line is always:  "OK ..."  or  "HIBA ..."

DIR=$(cd "$(dirname "$0")" && pwd)
BIN="$DIR/bin"
ST=/tmp/bookfetch
LOG="$ST/ovpn.log"
PIDF="$ST/ovpn.pid"
CHAIN=BF_KILL
FALLBACK_DNS=1.1.1.1

mkdir -p "$ST"

fail() { echo "HIBA $*"; exit 1; }

is_running() {
    [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null
}

# ---------- IPv6 (otherwise the home IPv6 address leaks) ----------
ipv6_off() {
    for ifc in all default wlan0; do
        p=/proc/sys/net/ipv6/conf/$ifc/disable_ipv6
        [ -f "$p" ] || continue
        [ -f "$ST/v6_$ifc" ] || cat "$p" > "$ST/v6_$ifc"
        echo 1 > "$p"
    done
}

ipv6_restore() {
    for ifc in all default wlan0; do
        p=/proc/sys/net/ipv6/conf/$ifc/disable_ipv6
        if [ -f "$ST/v6_$ifc" ]; then
            [ -f "$p" ] && cat "$ST/v6_$ifc" > "$p"
            rm -f "$ST/v6_$ifc"
        fi
    done
}

# ---------- Firewall: allow tun0 replies + kill switch ----------
fw_up() {
    server="$1"
    lan="$2"
    rproto="$3"
    rport="$4"
    # The Kindle firewall only allows replies on wlan0 – tun0 must be allowed too
    iptables -I INPUT -i tun0 -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Kill switch: outbound traffic only through the VPN tunnel, to the VPN server and local network
    iptables -N "$CHAIN" 2>/dev/null || iptables -F "$CHAIN"
    iptables -A "$CHAIN" -o lo -j ACCEPT
    iptables -A "$CHAIN" -o tun0 -j ACCEPT
    [ -n "$server" ] && iptables -A "$CHAIN" -d "$server" -j ACCEPT
    # The tunnel's own traffic to the VPN port – even if OpenVPN reconnects to another
    # server IP (remote-random), or the log did not provide the IP
    [ -n "$rport" ] && iptables -A "$CHAIN" -o wlan0 -p "$rproto" --dport "$rport" -j ACCEPT
    # DHCP (otherwise the Wi-Fi address lease expires after a few hours)
    iptables -A "$CHAIN" -o wlan0 -p udp --dport 67:68 -j ACCEPT
    # Allow DNS to our resolvers on wlan0 too: if Wi-Fi sleeps and the tunnel
    # drops, OpenVPN can resolve the server name and reconnect.
    for d in "$FALLBACK_DNS" 8.8.8.8; do
        iptables -A "$CHAIN" -o wlan0 -d "$d" -p udp --dport 53 -j ACCEPT
        iptables -A "$CHAIN" -o wlan0 -d "$d" -p tcp --dport 53 -j ACCEPT
    done
    [ -n "$lan" ] && iptables -A "$CHAIN" -d "$lan" -j ACCEPT
    iptables -A "$CHAIN" -j DROP
    iptables -I OUTPUT 1 -j "$CHAIN"
}

# ---------- Keep Wi-Fi awake (the Kindle turns it off after a few idle minutes) ----------
wifi_keepawake() {
    # Disable power saving on wlan0 (if supported by iwconfig/the driver)
    iwconfig wlan0 power off 2>/dev/null
    for ps in /sys/class/net/wlan0/device/power/control; do
        [ -w "$ps" ] && echo on > "$ps" 2>/dev/null
    done
    # Tell the Kindle power manager to keep Wi-Fi enabled (if available)
    lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null || true
    lipc-set-prop com.lab126.wifid enable 1 2>/dev/null || true
}

# Restore power saving when the VPN is turned off so the reader does not
# consume more power than it would without the VPN.
wifi_restore() {
    iwconfig wlan0 power on 2>/dev/null
    for ps in /sys/class/net/wlan0/device/power/control; do
        [ -w "$ps" ] && echo auto > "$ps" 2>/dev/null
    done
}

fw_down() {
    while iptables -D OUTPUT -j "$CHAIN" 2>/dev/null; do :; done
    iptables -F "$CHAIN" 2>/dev/null
    iptables -X "$CHAIN" 2>/dev/null
    while iptables -D INPUT -i tun0 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; do :; done
}

# ---------- DNS (otherwise the router sees what you look up) ----------
# The Kindle network daemon may rewrite resolv.conf to use the router's DNS,
# which the kill switch blocks -> DNS stops working. Lock it to prevent this (chattr +i).
# Use reliable DNS reachable through the tunnel (0.0.0.0/1 route).
dns_set() {
    vpn_dns="$1"
    # If resolv.conf is a symbolic link, replace it with a regular file first
    if [ -L /etc/resolv.conf ]; then
        # Save the DIRECT link target (not the final file) so it can be restored exactly
        tgt=$(readlink /etc/resolv.conf 2>/dev/null)
        rm -f /etc/resolv.conf
        : > /etc/resolv.conf
        [ -n "$tgt" ] && echo "$tgt" > "$ST/resolv.link"
    fi
    [ -f "$ST/resolv.bak" ] || cat /etc/resolv.conf > "$ST/resolv.bak" 2>/dev/null
    chattr -i /etc/resolv.conf 2>/dev/null
    {
        [ -n "$vpn_dns" ] && [ "$vpn_dns" != "$FALLBACK_DNS" ] && printf 'nameserver %s\n' "$vpn_dns"
        printf 'nameserver %s\n' "$FALLBACK_DNS"
        printf 'nameserver %s\n' 8.8.8.8
    } > /etc/resolv.conf
    # Lock it so the system cannot overwrite it (if supported by the filesystem/chattr)
    chattr +i /etc/resolv.conf 2>/dev/null
}

dns_restore() {
    chattr -i /etc/resolv.conf 2>/dev/null
    if [ -f "$ST/resolv.link" ]; then
        # It was originally a symbolic link -> restore the LINK so the system's
        # DNS daemon can manage it again (otherwise the static file persists -> no name resolution)
        tgt=$(cat "$ST/resolv.link" 2>/dev/null)
        rm -f /etc/resolv.conf
        [ -n "$tgt" ] && ln -s "$tgt" /etc/resolv.conf 2>/dev/null
        rm -f "$ST/resolv.link" "$ST/resolv.bak"
    elif [ -f "$ST/resolv.bak" ]; then
        cat "$ST/resolv.bak" > /etc/resolv.conf 2>/dev/null
        rm -f "$ST/resolv.bak"
    fi
}

# ---------- Main operations ----------
do_down() {
    if [ -f "$PIDF" ]; then
        kill "$(cat "$PIDF")" 2>/dev/null
        i=0
        while is_running && [ $i -lt 10 ]; do sleep 1; i=$((i + 1)); done
        is_running && kill -9 "$(cat "$PIDF")" 2>/dev/null
        rm -f "$PIDF"
    fi
    fw_down
    dns_restore
    ipv6_restore
    wifi_restore
    rm -f "$ST/auth" "$ST/cfg.ovpn"
}

do_up() {
    ovpn="$1"
    auth="$2"
    [ -f "$ovpn" ] || fail ".ovpn file not found: $ovpn"
    [ -f "$auth" ] || fail "auth.txt not found"
    [ -x "$BIN/openvpn" ] || chmod +x "$BIN/openvpn" 2>/dev/null

    if is_running; then
        echo "OK $(wget -T 10 -qO- http://ifconfig.me/ip 2>/dev/null)"
        exit 0
    fi

    # Clean up any leftovers from a previous run
    do_down

    # Strip Windows line endings and directives no longer valid in OpenVPN 2.6
    tr -d '\r' < "$ovpn" | grep -v -E '^[[:space:]]*(keysize|auth-user-pass)' > "$ST/cfg.ovpn"
    tr -d '\r' < "$auth" > "$ST/auth"
    chmod 600 "$ST/auth"

    ipv6_off
    wifi_keepawake
    rm -f "$LOG"

    # --ping/--ping-restart: if Wi-Fi sleeps and comes back, OpenVPN automatically
    #   rebuilds the tunnel (no manual reconnection needed).
    # --persist-tun: tun0 and the routes are preserved during reconnection.
    "$BIN/openvpn" --config "$ST/cfg.ovpn" \
        --auth-user-pass "$ST/auth" --auth-nocache \
        --pull-filter ignore "ifconfig-ipv6" \
        --pull-filter ignore "route-ipv6" \
        --ping 10 --ping-restart 60 --persist-tun --persist-key \
        --connect-retry-max 0 \
        --daemon bookfetch-ovpn --log "$LOG" --writepid "$PIDF"

    i=0
    while [ $i -lt 40 ]; do
        if grep -q "Initialization Sequence Completed" "$LOG" 2>/dev/null; then
            break
        fi
        if grep -q -E "AUTH_FAILED|Options error|Exiting due to fatal error" "$LOG" 2>/dev/null; then
            err=$(grep -E "AUTH_FAILED|Options error|fatal error" "$LOG" | tail -n 1 | cut -c21-)
            do_down
            fail "OpenVPN: $err"
        fi
        if [ $i -gt 3 ] && ! is_running; then
            err=$(tail -n 1 "$LOG" 2>/dev/null | cut -c21-)
            do_down
            fail "OpenVPN stopped: $err"
        fi
        sleep 1
        i=$((i + 1))
    done
    if [ $i -ge 40 ]; then
        do_down
        fail "Timed out (40 s) – no connection to the VPN server"
    fi

    # VPN server address (OpenVPN adds this route itself)
    server=$(grep -o 'net_route_v4_add: [0-9.]*/32 via' "$LOG" | tail -n 1 | awk '{print $2}' | cut -d/ -f1)
    # Local network (e.g. 10.0.0.0/24) – keep SSH access from the computer working
    lan=$(ip route 2>/dev/null | awk '/dev wlan0/ && /scope link/ {print $1; exit}')
    if [ -z "$lan" ]; then
        # Fallback if the "ip" command is unavailable: route -n (network + netmask)
        lan=$(route -n 2>/dev/null | awk '$8=="wlan0" && $2=="0.0.0.0" && $1!="0.0.0.0" {print $1"/"$3; exit}')
    fi
    # VPN server port and protocol from the configuration
    rport=$(awk '/^[[:space:]]*remote[[:space:]]/ && $3 != "" {print $3; exit}' "$ST/cfg.ovpn")
    [ -n "$rport" ] || rport=$(awk '/^[[:space:]]*port[[:space:]]/ {print $2; exit}' "$ST/cfg.ovpn")
    [ -n "$rport" ] || rport=1194
    rproto=$(awk '/^[[:space:]]*proto[[:space:]]/ {print $2; exit}' "$ST/cfg.ovpn")
    case "$rproto" in tcp*) rproto=tcp ;; *) rproto=udp ;; esac
    # DNS provided by the VPN
    dns=$(grep -o 'dhcp-option DNS [0-9.]*' "$LOG" | tail -n 1 | awk '{print $3}')
    [ -n "$dns" ] || dns=$FALLBACK_DNS

    fw_up "$server" "$lan" "$rproto" "$rport"
    dns_set "$dns"

    ip=$(wget -T 10 -qO- http://ifconfig.me/ip 2>/dev/null)
    [ -n "$ip" ] || ip="(could not retrieve the IP address)"
    echo "OK $ip"
}

do_status() {
    if is_running && [ -e /sys/class/net/tun0 ] && grep -q "Initialization Sequence Completed" "$LOG" 2>/dev/null; then
        echo "OK BE $(wget -T 10 -qO- http://ifconfig.me/ip 2>/dev/null)"
    else
        echo "OK KI"
    fi
}

# Self-healing: if the VPN is NOT running but a stuck kill switch or locked/static
# resolv.conf remains from a previous (interrupted) run, clean up to restore internet access.
do_heal() {
    is_running && return 0
    fw_down 2>/dev/null
    # Always unlock resolv.conf (the immutable flag survives a reboot!)
    chattr -i /etc/resolv.conf 2>/dev/null
    dns_restore
    ipv6_restore 2>/dev/null
    wifi_restore 2>/dev/null
}

case "$1" in
    up)     do_up "$2" "$3" ;;
    down)   do_down; echo "OK" ;;
    heal)   do_heal; echo "OK" ;;
    status) do_status ;;
    *)      fail "Usage: vpn.sh up <ovpn> <auth> | down | heal | status" ;;
esac
