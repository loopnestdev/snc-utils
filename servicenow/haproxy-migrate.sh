#!/bin/bash
# Ad-hoc: migrate HAProxy from per-instance frontends to single :443 frontend
# Targets a VM already running SNC instances with the old 1:1 topology.
# SSL cert is assumed to already exist at /etc/haproxy/host.pem.
# Run as root.
set -euo pipefail

INSTANCES=${1:-2}
PORT_START=${2:-16001}
HAPROXY_STATPORT=14567
CFG=/etc/haproxy/haproxy.cfg
HOSTNAME_SHORT="$(hostname -s)"

die()  { echo "[ERROR] $*" >&2; exit 1; }
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

[ "$(id -u)" -eq 0 ] || die "Must be run as root."
command -v haproxy >/dev/null || die "haproxy not installed."
[ -f "${CFG}" ] || die "HAProxy config not found: ${CFG}"

# Detect SSL: cert present and old config had ssl on a bind line
SSL="false"
[ -f /etc/haproxy/host.pem ] && grep -q "ssl crt" "${CFG}" && SSL="true"

# Thread count (same logic as snow-deploy.sh)
NCPUS=$(nproc)
NBTHREAD=$(( NCPUS / 4 ))
[ "${NBTHREAD}" -lt 1 ] && NBTHREAD=1

log "Migration plan:"
log "  Instances  : ${INSTANCES} (ports ${PORT_START}–$(( PORT_START + INSTANCES - 1 )))"
log "  Frontend   : 0.0.0.0:443 (SSL=${SSL})"
log "  Balance    : leastconn + SERVERID cookie"
log "  Threads    : ${NBTHREAD}"

# Back up current config
BACKUP="${CFG}.bak.$(date '+%Y%m%d%H%M%S')"
cp "${CFG}" "${BACKUP}"
log "Old config backed up to ${BACKUP}"

# Write new config
cat > "${CFG}" <<EOF
global
  nbthread              ${NBTHREAD}
  cpu-map               auto:1/1-${NBTHREAD} 0-$(( NBTHREAD - 1 ))
  maxconn               100000
  log                   127.0.0.1 local2
  chroot                /var/empty
  user                  haproxy
  group                 haproxy
  daemon
  tune.ssl.cachesize    1000000
  tune.maxrewrite       4096
  stats                 socket 127.0.0.1:${HAPROXY_STATPORT}
EOF

if [ "${SSL}" = "true" ]; then
  cat >> "${CFG}" <<EOF
  ssl-default-bind-options force-tlsv12
  ssl-default-bind-ciphersuites TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256
  ssl-dh-param-file     /etc/haproxy/dhparam-2048.pem

EOF
fi

cat >> "${CFG}" <<'EOF'
defaults
  mode                  http
  log                   global
  option                dontlognull
  option                http-server-close
  option                redispatch
  retries               3
  timeout http-request  15s
  timeout queue         1m
  timeout connect       5s
  timeout client        60s
  timeout server        301s
  timeout http-keep-alive 120s
  timeout check         10s
  timeout tunnel        10m
  timeout client-fin    10s
  timeout server-fin    10s

frontend stats
  bind                  *:14567
  mode                  http
  stats                 enable
  stats                 hide-version
  stats                 realm HAProxy\ Statistics
  stats                 uri /stats
  stats                 refresh 30s

EOF

if [ "${SSL}" = "true" ]; then
  BIND_LINE="bind 0.0.0.0:443 ssl crt /etc/haproxy/host.pem"
else
  BIND_LINE="bind 0.0.0.0:443"
fi

cat >> "${CFG}" <<EOF
frontend snc-frontend
  ${BIND_LINE}
  option                httplog
  option                forwardfor
  option                http-server-close

  http-request          set-header X-Forwarded-Host %[req.hdr(host)]
  http-request          set-header X-Forwarded-Proto https if { ssl_fc }
  http-request          set-header X-Forwarded-Proto http if !{ ssl_fc }

  http-after-response   set-header Strict-Transport-Security "max-age=63072000; includeSubDomains;"
  http-after-response   replace-header Set-Cookie '(^((?!(?i)httponly).)*$)' '\1; HttpOnly'
  http-after-response   replace-header Set-Cookie '(^((?!(?i)secure).)*$)' '\1; Secure'

  http-response         replace-header Location ^http://(.*)$ https://\1

  default_backend       snc-backend

backend snc-backend
  mode                  http
  balance               leastconn
  option                httpchk
  http-check send       meth GET uri /stats.do
  cookie                SERVERID insert indirect nocache

EOF

for seq in $(seq 1 "${INSTANCES}"); do
  NODE="${HOSTNAME_SHORT}-$(printf "%02d" "${seq}")"
  PORT=$(( PORT_START + seq - 1 ))
  echo "  server                ${NODE} 127.0.0.1:${PORT} check cookie ${NODE}" >> "${CFG}"
done
echo "" >> "${CFG}"

log "New config written. Running syntax check..."
haproxy -c -f "${CFG}" || {
  log "Syntax check FAILED — restoring backup."
  cp "${BACKUP}" "${CFG}"
  die "Config rolled back. Fix errors and re-run."
}

log "Reloading HAProxy..."
systemctl reload haproxy || systemctl restart haproxy

log "Done. Backend pool:"
for seq in $(seq 1 "${INSTANCES}"); do
  NODE="${HOSTNAME_SHORT}-$(printf "%02d" "${seq}")"
  PORT=$(( PORT_START + seq - 1 ))
  log "  ${NODE} → 127.0.0.1:${PORT}"
done
