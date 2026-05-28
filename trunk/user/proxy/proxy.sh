#!/bin/sh
#
# proxy.sh — chinadns-ng + dns2tcp + ipt2socks 智能分流服务管理
#
# Config:  nvram set socks5_proxy="IP:PORT"
#          nvram set proxy_enable=1
#          nvram commit
# Startup: echo '[ "$(nvram get proxy_enable)" = "1" ] && /usr/bin/proxy.sh start' \
#               >> /etc/storage/started_script.sh
#
# firewall hook (解决 WAN 重连后规则丢失):
#   echo '/usr/bin/proxy.sh fix_iptables' >> /etc/storage/post_iptables_script.sh

# ---- 配置区域 ----
SOCKS5="${socks5_proxy:-$(nvram get socks5_proxy)}"
SOCKS5="${SOCKS5:-192.168.9.250:7890}"
SOCKS5_IP="${SOCKS5%:*}"
SOCKS5_PORT="${SOCKS5#*:}"

CHNROUTE_TXT="/etc/storage/chinadns/chnroute.txt"
CHNROUTE_BZ2="/etc_ro/chnroute.bz2"
DNSMASQ_CONF="/etc/storage/dnsmasq/dnsmasq.conf"
PROXY_CHAIN="PROXY"
TAG="chinadns-proxy"

# ---- 工具函数 ----
log()  { logger -t "proxy" "$@"; echo "$(date '+%H:%M:%S') $@"; }
warn() { logger -t "proxy" -p warn "$@"; echo "$(date '+%H:%M:%S') WARN: $@"; }
die()  { log "FATAL: $@"; exit 1; }

pid_alive() { pidof "$1" >/dev/null 2>&1; }

# ======================== 预检 ========================
prereq_check() {
    local _missing=""
    local _bin

    # 必须的二进制
    for _bin in chinadns-ng dns2tcp ipt2socks ipset iptables; do
        if ! type "$_bin" >/dev/null 2>&1; then
            _missing="$_missing $_bin"
        fi
    done

    if [ -n "$_missing" ]; then
        die "missing binaries:$_missing"
    fi

    # 内核模块
    modprobe ip_set 2>/dev/null || true
    modprobe ip_set_hash_net 2>/dev/null || true
    modprobe xt_set 2>/dev/null || true

    # ipset 功能是否可用
    if ! ipset list -n >/dev/null 2>&1; then
        die "ipset kernel modules not loaded"
    fi
}

# ======================== chnroute ========================
load_chnroute() {
    local _n

    # 已存在且非空 → 复用
    if ipset list chnroute >/dev/null 2>&1; then
        _n=$(ipset list chnroute 2>/dev/null | grep -c '^[0-9]')
        if [ "$_n" -gt 100 ]; then
            log "chnroute ipset: $_n CIDRs (reuse)"
            return 0
        fi
        # 异常：条目太少，重建
        warn "chnroute ipset has only $_n entries, reloading..."
        ipset destroy chnroute 2>/dev/null
    fi

    # 数据源：优先 /etc/storage 的 txt（可能是运行时更新的），
    # 其次从 ROM 的 bz2 解压
    if [ ! -f "$CHNROUTE_TXT" ]; then
        if [ -f "$CHNROUTE_BZ2" ]; then
            log "Extracting $CHNROUTE_BZ2 ..."
            mkdir -p /etc/storage/chinadns
            bzcat "$CHNROUTE_BZ2" > "$CHNROUTE_TXT" 2>/dev/null || true
        fi
    fi

    if [ ! -f "$CHNROUTE_TXT" ]; then
        die "$CHNROUTE_TXT not found. Run: update_chnroute.sh force"
    fi

    # 格式验证：至少有 100 行 x.x.x.x/xx 格式
    _n=$(grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$CHNROUTE_TXT" 2>/dev/null || echo 0)
    if [ "$_n" -lt 100 ]; then
        die "$CHNROUTE_TXT has only $_n valid CIDRs (file corrupt?)"
    fi

    log "Loading $_n CIDRs into chnroute ipset..."

    # 尝试快速路径: ipset restore
    if {
        echo "create chnroute hash:net"
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$CHNROUTE_TXT" | \
            sed 's/^/add chnroute /'
    } | ipset restore 2>/dev/null; then
        log "  ipset restore OK"
    else
        # 慢速回退: 逐个 ipset add（busybox ipset restore 可能不完善）
        log "  restore unavailable, using ipset add (slower)..."
        ipset create chnroute hash:net 2>/dev/null || true
        local _count=0 _cidr
        while IFS= read -r _cidr; do
            [ -z "$_cidr" ] && continue
            ipset add chnroute "$_cidr" 2>/dev/null && _count=$((_count + 1))
        done < "$CHNROUTE_TXT"
        log "  added $_count entries via loop"
    fi

    _n=$(ipset list chnroute 2>/dev/null | grep -c '^[0-9]')
    if [ "$_n" -lt 100 ]; then
        die "ipset restore failed: only $_n entries loaded"
    fi
    log "  chnroute ipset: $_n CIDRs loaded"
}

# ======================== 守护进程 ========================
start_daemons() {
    local _i _max _pid

    # 1. ipt2socks — REDIRECT → SOCKS5
    log "Starting ipt2socks ($SOCKS5_IP:$SOCKS5_PORT → 0.0.0.0:1088)"
    killall ipt2socks 2>/dev/null || true
    ipt2socks -s "$SOCKS5_IP" -p "$SOCKS5_PORT" \
        -b 0.0.0.0 -l 1088 -T -4 -R \
        >/dev/null 2>&1 &

    _max=5
    usleep 300000
    for _i in $(seq 1 $_max); do
        pid_alive ipt2socks && break
        usleep 200000
    done
    if ! pid_alive ipt2socks; then
        log "  ipt2socks FAILED to start"
        return 1
    fi
    log "  ipt2socks pid=$(pidof ipt2socks)"

    # 2. dns2tcp — TCP DNS 隧道
    log "Starting dns2tcp (127.0.0.1#5354 → 8.8.8.8#53)"
    killall dns2tcp 2>/dev/null || true
    dns2tcp -L 127.0.0.1#5354 -R 8.8.8.8#53 \
        >/dev/null 2>&1 &

    _max=5
    usleep 300000
    for _i in $(seq 1 $_max); do
        pid_alive dns2tcp && break
        usleep 200000
    done
    if ! pid_alive dns2tcp; then
        log "  dns2tcp FAILED to start"
        return 1
    fi
    log "  dns2tcp pid=$(pidof dns2tcp)"

    # 3. chinadns-ng — DNS 分流
    #    -4 chnroute: 用 ipset 做 IP 归属判断
    log "Starting chinadns-ng (0.0.0.0:5353)"
    killall chinadns-ng 2>/dev/null || true
    chinadns-ng -b 0.0.0.0 -l 5353 \
        -c 223.5.5.5 \
        -t 127.0.0.1#5354 \
        -4 chnroute \
        >/dev/null 2>&1 &

    _max=5
    usleep 500000
    for _i in $(seq 1 $_max); do
        pid_alive chinadns-ng && break
        usleep 200000
    done
    if ! pid_alive chinadns-ng; then
        log "  chinadns-ng FAILED to start"
        return 1
    fi
    log "  chinadns-ng pid=$(pidof chinadns-ng)"

    return 0
}

# ======================== iptables ========================
flush_iptables() {
    iptables -t nat -D PREROUTING -j "$PROXY_CHAIN" 2>/dev/null || true
    iptables -t nat -D OUTPUT -j "$PROXY_CHAIN" 2>/dev/null || true
    iptables -t nat -F "$PROXY_CHAIN" 2>/dev/null || true
    iptables -t nat -X "$PROXY_CHAIN" 2>/dev/null || true
    iptables -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports 1088 2>/dev/null || true
}

setup_iptables() {
    flush_iptables

    log "Setting up iptables..."

    # 规则0: dns2tcp → 8.8.8.8:53 TCP → ipt2socks
    if ! iptables -t nat -I OUTPUT 1 -p tcp --dport 53 -j REDIRECT --to-ports 1088; then
        die "iptables RULE0 failed"
    fi

    # PROXY 链
    iptables -t nat -N "$PROXY_CHAIN"

    # 私有/保留地址 → RETURN
    for net in \
        0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 \
        127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 \
        192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
        iptables -t nat -A "$PROXY_CHAIN" -d "$net" -j RETURN
    done

    # SOCKS5 服务器 → RETURN (防环路)
    iptables -t nat -A "$PROXY_CHAIN" -d "$SOCKS5_IP" -j RETURN

    # chnroute → RETURN, 其余 → ipt2socks
    iptables -t nat -A "$PROXY_CHAIN" -p tcp \
        -m set --match-set chnroute dst -j RETURN
    iptables -t nat -A "$PROXY_CHAIN" -p tcp \
        -j REDIRECT --to-ports 1088

    # 挂入主链（PREROUTING 最先，OUTPUT 在 DNS 规则之后）
    iptables -t nat -I PREROUTING 1 -j "$PROXY_CHAIN"
    iptables -t nat -I OUTPUT 2 -j "$PROXY_CHAIN"

    log "  iptables done"
}

# 仅修 iptables（post_iptables_script.sh 调用，不重启守护进程）
fix_iptables() {
    if ! pid_alive ipt2socks; then
        return 0  # 代理没跑，不必修
    fi
    log "Fixing iptables after firewall restart..."
    flush_iptables
    setup_iptables
}

# ======================== dnsmasq ========================
setup_dnsmasq() {
    if grep -q "server=127.0.0.1#5353" "$DNSMASQ_CONF" 2>/dev/null; then
        log "dnsmasq: already forwarding to chinadns-ng"
        # 校验 dnsmasq 是否在跑
        if pid_alive dnsmasq; then
            return 0
        fi
        warn "dnsmasq config ok but process dead, restarting..."
    else
        log "dnsmasq: adding server=127.0.0.1#5353"
        echo "# $TAG" >> "$DNSMASQ_CONF"
        echo "server=127.0.0.1#5353" >> "$DNSMASQ_CONF"
    fi

    killall dnsmasq 2>/dev/null || true
    usleep 300000
    dnsmasq

    if ! pid_alive dnsmasq; then
        die "dnsmasq failed to restart"
    fi
    log "  dnsmasq restarted"
}

# ======================== public ========================
start() {
    log "=== Starting proxy ($SOCKS5_IP:$SOCKS5_PORT) ==="

    prereq_check
    load_chnroute

    # 如果已经完整在跑，跳过
    if pid_alive ipt2socks && pid_alive dns2tcp && pid_alive chinadns-ng; then
        if iptables -t nat -L "$PROXY_CHAIN" -n >/dev/null 2>&1; then
            log "Already running. Use restart to reload."
            log "  chinadns-ng: $(pidof chinadns-ng)"
            log "  dns2tcp:     $(pidof dns2tcp)"
            log "  ipt2socks:   $(pidof ipt2socks)"
            return 0
        fi
        warn "Daemons running but iptables missing, fixing..."
    fi

    start_daemons || die "daemon startup failed"
    setup_iptables
    setup_dnsmasq

    log "=== Started OK ==="
    log "  chinadns-ng: $(pidof chinadns-ng 2>/dev/null || echo DEAD)"
    log "  dns2tcp:     $(pidof dns2tcp 2>/dev/null || echo DEAD)"
    log "  ipt2socks:   $(pidof ipt2socks 2>/dev/null || echo DEAD)"
    return 0
}

stop() {
    log "=== Stopping proxy ==="

    # iptables（全部忽略错误，保证幂等）
    iptables -t nat -D PREROUTING -j "$PROXY_CHAIN" 2>/dev/null || true
    iptables -t nat -D OUTPUT -j "$PROXY_CHAIN" 2>/dev/null || true
    iptables -t nat -F "$PROXY_CHAIN" 2>/dev/null || true
    iptables -t nat -X "$PROXY_CHAIN" 2>/dev/null || true
    iptables -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports 1088 2>/dev/null || true

    # 进程
    killall chinadns-ng dns2tcp ipt2socks 2>/dev/null || true
    usleep 200000

    # 确认已杀干净
    for _p in chinadns-ng dns2tcp ipt2socks; do
        if pid_alive "$_p"; then
            warn "$_p still alive, kill -9..."
            killall -9 "$_p" 2>/dev/null || true
        fi
    done

    # ipset（不删除 — 下次 start 可直接复用，省 30 秒）
    # ipset destroy chnroute 2>/dev/null || true

    # dnsmasq 恢复
    if grep -Fq "$TAG" "$DNSMASQ_CONF" 2>/dev/null; then
        log "dnsmasq: removing forwarding rule"
        sed -i "/$TAG/d ; /server=127.0.0.1#5353/d" "$DNSMASQ_CONF"
        killall dnsmasq 2>/dev/null || true
        dnsmasq
    fi

    log "=== Stopped ==="
}

health() {
    local _ok _fail _n _p _pid _dns_result
    _ok=0
    _fail=0

    echo "=== health check ==="
    echo ""

    # 进程
    for _p in ipt2socks dns2tcp chinadns-ng; do
        if pid_alive "$_p"; then
            echo "  [OK] $_p (pid $(pidof $_p))"
            _ok=$((_ok + 1))
        else
            echo "  [FAIL] $_p not running"
            _fail=$((_fail + 1))
        fi
    done

    # ipset
    _n=$(ipset list chnroute 2>/dev/null | grep -c '^[0-9]')
    if [ "$_n" -gt 100 ]; then
        echo "  [OK] chnroute ipset: $_n entries"
        _ok=$((_ok + 1))
    else
        echo "  [FAIL] chnroute ipset: $_n entries (<100)"
        _fail=$((_fail + 1))
    fi

    # iptables
    if iptables -t nat -L "$PROXY_CHAIN" -n >/dev/null 2>&1; then
        echo "  [OK] iptables PROXY chain exists"
        _ok=$((_ok + 1))
    else
        echo "  [WARN] iptables PROXY chain missing (WAN reconnect? Run: proxy.sh fix_iptables)"
    fi

    # DNS: 从本地 chinadns-ng 查一个国内域名
    _dns_result=$(nslookup baidu.com 127.0.0.1:5353 2>/dev/null \
        | grep -A1 "Name:" | tail -1 | awk '{print $NF}')
    if echo "$_dns_result" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo "  [OK] DNS baidu.com → $_dns_result"
        _ok=$((_ok + 1))
    else
        echo "  [FAIL] DNS lookup failed"
        _fail=$((_fail + 1))
    fi

    echo ""
    echo "  Result: $_ok OK, $_fail FAIL"
    return $_fail
}

status() {
    local _p _pid _n
    echo "=== proxy status ==="
    echo "SOCKS5: $SOCKS5_IP:$SOCKS5_PORT"
    echo ""

    for _p in chinadns-ng dns2tcp ipt2socks; do
        _pid=$(pidof "$_p" 2>/dev/null)
        if [ -n "$_pid" ]; then
            echo "  $_p: RUNNING (pid $_pid)"
        else
            echo "  $_p: STOPPED"
        fi
    done

    echo ""
    _n=$(ipset list chnroute 2>/dev/null | grep -c '^[0-9]')
    echo "chnroute ipset: $_n entries"
    _n=$(iptables -t nat -L PROXY -n 2>/dev/null | wc -l)
    echo "PROXY chain: $_n rules"
    _n=$(grep -c 'server=127.0.0.1#5353' "$DNSMASQ_CONF" 2>/dev/null || echo 0)
    echo "DNS fwd: $_n"
}

# ======================== 入口 ========================
case "$1" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        stop
        sleep 1
        start
        ;;
    status)
        status
        ;;
    health)
        health
        ;;
    fix_iptables)
        fix_iptables
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|health|fix_iptables}"
        exit 1
        ;;
esac
