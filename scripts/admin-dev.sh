#!/usr/bin/env bash
#
# Configure and start the admin review console locally.
#
# Prompts for the two public Supabase values, validates that the key is
# publishable BEFORE writing it, and stores them in apps/admin/.env.local
# (gitignored, mode 600). The key is never echoed to the terminal and never
# appears in shell history, because it is read rather than passed as an
# argument.
set -euo pipefail

cd "$(dirname "$0")/.."
ENV_FILE="apps/admin/.env.local"

if [ -f "$ENV_FILE" ]; then
  echo "$ENV_FILE already exists."
  read -r -p "Overwrite it? [y/N] " reply
  case "$reply" in [yY]*) ;; *) echo "Keeping the existing file."; exit 0 ;; esac
fi

# Values may come from the environment, which is what makes this usable when
# stdin is not a terminal. Only prompt when there is a terminal to prompt on —
# otherwise read returns EOF instantly and the script would appear to do
# nothing at all, which is exactly how it failed the first time.
SUPABASE_URL="${SUPABASE_URL:-}"
SUPABASE_KEY="${SUPABASE_ANON_KEY:-}"

if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_KEY" ]; then
  if [ ! -t 0 ]; then
    cat >&2 <<'USAGE'
This script needs a terminal to prompt for the two values, and stdin is not one.

Either run it from a normal terminal window:

    ./scripts/admin-dev.sh

or pass the values in, which works anywhere:

    SUPABASE_URL=https://<ref>.supabase.co \
    SUPABASE_ANON_KEY=<anon-key> \
    ./scripts/admin-dev.sh

Note the second form puts the key in your shell history. The anon key is
published to every client anyway, so that is a tidiness question rather than a
secrets one -- but a privileged key would be a real problem, and this script
refuses one either way.
USAGE
    exit 1
  fi

  [ -n "$SUPABASE_URL" ] || read -r -p "Supabase project URL (https://<ref>.supabase.co): " SUPABASE_URL
  if [ -z "$SUPABASE_KEY" ]; then
    read -r -s -p "Supabase anon / publishable key (input hidden): " SUPABASE_KEY
    echo
  fi
fi

if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_KEY" ]; then
  echo "Both values are required." >&2
  exit 1
fi

# The same allowlist the app enforces at startup (apps/admin/src/lib/env.ts):
# the key must be positively identifiable as publishable. Checked here too so a
# privileged key is refused before it is ever written to disk.
SUPABASE_KEY="$SUPABASE_KEY" node -e '
const key = process.env.SUPABASE_KEY;
if (key.startsWith("sb_publishable_")) process.exit(0);
const parts = key.split(".");
if (parts.length === 3) {
  try {
    const role = JSON.parse(Buffer.from(parts[1], "base64").toString("utf8")).role;
    if (role === "anon") process.exit(0);
    console.error(`Refused: that key carries role "${role}".`);
    process.exit(1);
  } catch { /* fall through */ }
}
console.error("Refused: not recognisable as an anon or publishable key.");
process.exit(1);
' || {
  echo
  echo "Nothing was written. The console must only ever hold a publishable key:" >&2
  echo "it runs in the browser, and RLS is the only thing between a reviewer and" >&2
  echo "every inspector's drafts." >&2
  exit 1
}

umask 077
cat > "$ENV_FILE" <<EOF
NEXT_PUBLIC_SUPABASE_URL=$SUPABASE_URL
NEXT_PUBLIC_SUPABASE_ANON_KEY=$SUPABASE_KEY
EOF
chmod 600 "$ENV_FILE"

echo "Wrote $ENV_FILE (mode 600, gitignored). Key accepted as publishable."
git check-ignore -q "$ENV_FILE" && echo "Confirmed: git ignores it." \
  || echo "WARNING: git does NOT ignore $ENV_FILE — do not commit." >&2

cd apps/admin
[ -d node_modules ] || npm ci
echo
echo "Starting the console on http://localhost:3000 — Ctrl-C to stop."
npm run dev
