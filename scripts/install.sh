#!/bin/bash
set -euo pipefail

readonly TAG="v0.1.0-beta.5"
readonly ARCHIVE_NAME="Watchdog-0.1.0-macos.zip"
readonly ARCHIVE_URL="https://github.com/justn-hyeok/watchdog/releases/download/${TAG}/${ARCHIVE_NAME}"
readonly EXPECTED_SHA256="44b198ae0aa19137706f2e39f0cc01eb23687e59515c00b2b1e45377229256bb"

install_dir="${WATCHDOG_INSTALL_DIR:-$HOME/Applications}"
launch_after_install=true

usage() {
  cat <<'EOF'
Install the official Watchdog public beta into ~/Applications.

Usage: scripts/install.sh [options]

Options:
  --install-dir PATH  Install into PATH instead of ~/Applications
  --no-launch         Install without launching Watchdog
  -h, --help          Show this help

The installer downloads only from the official GitHub release, verifies its
SHA-256 checksum and code signature, and never disables or removes Gatekeeper.
EOF
}

while (($#)); do
  case "$1" in
    --install-dir)
      [[ $# -ge 2 ]] || { echo "Missing value for --install-dir" >&2; exit 2; }
      install_dir="$2"
      shift 2
      ;;
    --no-launch)
      launch_after_install=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || {
  echo "Watchdog requires macOS." >&2
  exit 1
}

for command in curl shasum ditto codesign lsof pgrep; do
  command -v "$command" >/dev/null || {
    echo "Required command not found: $command" >&2
    exit 1
  }
done

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/watchdog-install.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
archive="$tmp_dir/$ARCHIVE_NAME"
unpack_dir="$tmp_dir/unpack"
staged_app="$tmp_dir/Watchdog.app"
target_app="$install_dir/Watchdog.app"
backup_app="$install_dir/.Watchdog.app.backup.$$"

printf 'Downloading %s…\n' "$TAG"
curl --fail --location --silent --show-error \
  --proto '=https' --tlsv1.2 \
  --output "$archive" \
  "$ARCHIVE_URL"

actual_sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"
if [[ "$actual_sha256" != "$EXPECTED_SHA256" ]]; then
  printf 'Checksum mismatch.\nExpected: %s\nActual:   %s\n' \
    "$EXPECTED_SHA256" "$actual_sha256" >&2
  exit 1
fi
printf 'Checksum verified: %s\n' "$actual_sha256"

mkdir -p "$unpack_dir"
ditto -x -k "$archive" "$unpack_dir"
[[ -d "$unpack_dir/Watchdog.app" ]] || {
  echo "Release archive does not contain Watchdog.app." >&2
  exit 1
}
ditto "$unpack_dir/Watchdog.app" "$staged_app"
codesign --verify --deep --strict --verbose=2 "$staged_app"

mkdir -p "$install_dir"
install_dir="$(cd "$install_dir" && pwd -P)"
target_app="$install_dir/Watchdog.app"
backup_app="$install_dir/.Watchdog.app.backup.$$"

if [[ -d "$target_app" ]]; then
  target_executable="$target_app/Contents/MacOS/Watchdog"
  is_installed_process() {
    local pid="$1"
    local line
    while IFS= read -r line; do
      [[ "$line" == n* ]] || continue
      [[ "${line#n}" == "$target_executable" ]] && return 0
    done < <(lsof -a -p "$pid" -d txt -Fn 2>/dev/null || true)
    return 1
  }

  running_pids=()
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    is_installed_process "$pid" || continue
    running_pids+=("$pid")
  done < <(pgrep -x Watchdog || true)

  if ((${#running_pids[@]})); then
    echo "Stopping the installed Watchdog gracefully…"
    for pid in "${running_pids[@]}"; do
      is_installed_process "$pid" || continue
      /bin/kill -TERM "$pid"
    done
    for _ in 1 2 3 4 5; do
      still_running=false
      for pid in "${running_pids[@]}"; do
        if is_installed_process "$pid"; then
          still_running=true
          break
        fi
      done
      $still_running || break
      sleep 1
    done
    if $still_running; then
      echo "Watchdog is still running. Quit it manually and rerun the installer." >&2
      exit 1
    fi
  fi
  mv "$target_app" "$backup_app"
fi

if mv "$staged_app" "$target_app"; then
  rm -rf "$backup_app"
else
  [[ ! -d "$backup_app" ]] || mv "$backup_app" "$target_app"
  echo "Installation failed; the previous app was restored." >&2
  exit 1
fi

launch_services="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
[[ ! -x "$launch_services" ]] || "$launch_services" -f "$target_app"

version="$(defaults read "$target_app/Contents/Info" CFBundleShortVersionString)"
build="$(defaults read "$target_app/Contents/Info" CFBundleVersion)"
printf 'Installed Watchdog %s (%s) at %s\n' "$version" "$build" "$target_app"

if $launch_after_install; then
  open "$target_app"
  cat <<'EOF'
Launch requested. If macOS blocks this unnotarized beta, right-click Watchdog in
Finder and choose Open, or use System Settings → Privacy & Security → Open Anyway.
EOF
fi
