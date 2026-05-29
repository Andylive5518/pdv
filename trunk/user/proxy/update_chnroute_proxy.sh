#!/bin/sh
# update_chnroute_proxy.sh — download APNIC chnroute for proxy.sh
set -e

DST="/etc/storage/chinadns/chnroute.txt"
URL="http://ftp.apnic.net/apnic/stats/apnic/delegated-apnic-latest"

mkdir -p /etc/storage/chinadns

echo "Downloading from APNIC..."
curl -sk --connect-timeout 15 --retry 2 "$URL" | \
    awk -F'|' '/CN\|ipv4/ { printf("%s/%d\n", $4, 32-log($5)/log(2)) }' \
    > "$DST"

N=$(wc -l < "$DST")
echo "Downloaded $N CIDRs"

# Reload ipset if chnroute set exists
if ipset list chnroute >/dev/null 2>&1; then
    ipset destroy chnroute 2>/dev/null || true
    (echo "create chnroute hash:net"
     sed 's/^/add chnroute /' "$DST") | ipset restore 2>/dev/null && \
        echo "ipset reloaded: $(ipset list chnroute 2>/dev/null | grep -c '^[0-9]') entries" || \
        echo "WARNING: ipset reload failed — restart proxy to reload"
fi
