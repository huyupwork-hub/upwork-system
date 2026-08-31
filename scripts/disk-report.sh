#!/usr/bin/env bash
#
# Read-only disk report for the service box. Deletes nothing, changes nothing.
#
# Companion to db-verify.sh, whose preflight fails when Docker's filesystem is
# short and tells you to go find the space. This is how you find it.
#
# Usage:  ./scripts/disk-report.sh
#
# sudo is used only for the system-wide sweep and is optional — without it that
# one section is skipped and everything else still runs.

set -uo pipefail

bold()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
dim()   { printf '\033[2m%s\033[0m\n' "$1"; }
human() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"; }

TOP=${TOP:-15}

# GNU du (Linux, the service box) spells it --max-depth; BSD du (macOS) spells
# it -d. Detect once so the script is useful on either.
if du --max-depth=0 . >/dev/null 2>&1; then
  depth() { printf -- '--max-depth=%s' "$1"; }
else
  depth() { printf -- '-d %s' "$1"; }
fi

# ---------------------------------------------------------------- filesystems

bold 'Filesystem'
df -h / 2>/dev/null

docker_root=''
if command -v docker >/dev/null 2>&1; then
  docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)
  [ -n "$docker_root" ] && [ -d "$docker_root" ] || docker_root=/var/lib/docker
  if [ -d "$docker_root" ] && ! df -P / "$docker_root" 2>/dev/null |
       awk 'NR>1{print $1}' | sort -u | { [ "$(wc -l)" -eq 1 ]; }; then
    printf '\n'
    dim "Docker lives on a different filesystem:"
    df -h "$docker_root"
  fi
fi

# ---------------------------------------------------------------- system-wide

bold "Largest directories under / (top $TOP, one filesystem)"
if [ "$(id -u)" -eq 0 ]; then
  du -xh $(depth 2) / 2>/dev/null | sort -h | tail -"$TOP"
elif sudo -n true 2>/dev/null; then
  sudo du -xh $(depth 2) / 2>/dev/null | sort -h | tail -"$TOP"
else
  dim "skipped — needs root. Re-run with: sudo -v && ./scripts/disk-report.sh"
fi

# ---------------------------------------------------------------- home

bold "Largest directories under $HOME (top $TOP)"
du -xh $(depth 3) "$HOME" 2>/dev/null | sort -h | tail -"$TOP"

bold 'Known caches'
for d in "$HOME/.pub-cache" "$HOME/.gradle" "$HOME/.cache" \
         "$HOME/.npm" "$HOME/Android" "$HOME/.android"; do
  [ -e "$d" ] && du -sh "$d" 2>/dev/null
done
# The self-hosted runner's toolcache: Flutter and the JDK land here.
for d in "$(dirname "$0")"/../actions-runner/_work/_tool/* \
         "$HOME"/actions-runner/_work/_tool/*; do
  [ -e "$d" ] && du -sh "$d" 2>/dev/null
done | sort -h -u

# ---------------------------------------------------------------- docker

if ! command -v docker >/dev/null 2>&1; then
  bold 'Docker'
  dim 'not installed'
  exit 0
fi

if ! docker info >/dev/null 2>&1; then
  bold 'Docker'
  dim 'daemon not reachable (permission, or not running)'
  exit 0
fi

bold 'Docker totals'
docker system df 2>/dev/null

# Which images are referenced by a container, running or stopped? An image with
# no container is a candidate for removal; one with a container is not, and
# `docker image prune -a` after stopping that container would take it too.
used=$(docker ps -aq 2>/dev/null | xargs -r docker inspect --format '{{.Image}}' 2>/dev/null | sort -u)

bold 'Images (UNUSED = no container references it)'
printf '%-46s %-12s %s\n' 'REPOSITORY:TAG' 'SIZE' 'STATUS'
reclaimable=0
while IFS=$'\t' read -r ref id size bytes; do
  [ -z "${ref:-}" ] && continue
  if printf '%s\n' "$used" | grep -qF "$id"; then
    status='in use'
  else
    status='UNUSED'
    reclaimable=$((reclaimable + ${bytes:-0}))
  fi
  printf '%-46s %-12s %s\n' "$ref" "$size" "$status"
done < <(docker images --no-trunc --format '{{.Repository}}:{{.Tag}}	{{.ID}}	{{.Size}}	{{.VirtualSize}}' 2>/dev/null | sort -t'	' -k4 -rn)

bold 'Volumes'
docker volume ls --format '{{.Name}}' 2>/dev/null | while read -r v; do
  [ -z "$v" ] && continue
  sz=$(docker system df -v 2>/dev/null | awk -v v="$v" '$1==v {print $NF}')
  printf '%-40s %s\n' "$v" "${sz:-?}"
done

bold 'Reclaimable right now'
printf 'unused images: %s\n' "$(human "$reclaimable")"
cat <<'EOF'

Remove unused images BY NAME, from the list above:

    docker image rm <repository:tag> [...]

Do NOT run `docker image prune -a` after stopping a stack. Prune treats an image
as unreferenced the moment its last container goes away, so stopping first and
pruning second deletes images you still want — supabase/postgres is ~3 GB and
would have to be pulled again.

Safe order, least destructive first:

    docker image rm <unused ones listed above>
    docker image prune -f            # dangling layers only, no -a
    docker builder prune -f
    npx supabase stop --no-backup    # only after the removals above
    sudo journalctl --vacuum-size=100M
    sudo apt-get clean
EOF
