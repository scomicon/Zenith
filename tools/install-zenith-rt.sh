#!/usr/bin/env sh
set -eu

PACK="rt"
TAG="latest"
INSTANCE=""
TARGET_DIR=""
LOCAL_MODE="0"
REPO="scomicon/Zenith"

usage() {
    cat <<'EOF'
Install Zenith RT (and/or Zenith) for Horizon Shader API 0.2.

Usage:
  install-zenith-rt.sh [options]

Options:
  --pack <rt|raster|both>   Which pack(s) to install (default: rt)
  --tag <tag|latest>        GitHub release tag to download (default: latest)
  --instance <id>           Horizon launcher instance id (optional)
  --dir <path>              Explicit Horizon shaderpacks directory override
  --local                   Install/build from local repository instead of GitHub
  --repo <owner/name>       GitHub repository (default: scomicon/Zenith)
  -h, --help                Show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --pack)
            PACK="${2:-}"
            shift 2
            ;;
        --tag)
            TAG="${2:-}"
            shift 2
            ;;
        --instance)
            INSTANCE="${2:-}"
            shift 2
            ;;
        --dir)
            TARGET_DIR="${2:-}"
            shift 2
            ;;
        --local)
            LOCAL_MODE="1"
            shift 1
            ;;
        --repo)
            REPO="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

case "$PACK" in
    rt|raster|both) ;;
    *)
        echo "Invalid --pack value '$PACK' (expected rt, raster, or both)." >&2
        exit 1
        ;;
esac

resolve_horizon_dir() {
    case "$(uname -s)" in
        Darwin)
            printf '%s\n' "$HOME/Library/Application Support/horizon"
            ;;
        *)
            printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/horizon"
            ;;
    esac
}

HORIZON_DIR="$(resolve_horizon_dir)"
if [ -n "$TARGET_DIR" ]; then
    SHADERPACKS_DIR="$TARGET_DIR"
elif [ -n "$INSTANCE" ] && [ "$INSTANCE" != "horizon" ]; then
    SHADERPACKS_DIR="$HORIZON_DIR/instances/$INSTANCE/shaderpacks"
else
    SHADERPACKS_DIR="$HORIZON_DIR/shaderpacks"
fi

SCRIPT_DIR=""
if [ -n "${0:-}" ] && [ -f "$0" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

LOCAL_REPO=""
for candidate in "$(dirname "${SCRIPT_DIR:-/nonexistent}")" "$(pwd)"; do
    if [ -n "$candidate" ] && [ -f "$candidate/pack/zenith/horizon-shaders.toml" ] && [ -d "$candidate/variants/zenith-rt" ]; then
        LOCAL_REPO="$candidate"
        break
    fi
done

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$HORIZON_DIR/.zenith-install-backups/$TIMESTAMP"
TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t zenith-install)"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

mkdir -p "$SHADERPACKS_DIR"

fetch_text() {
    url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -H "User-Agent: Zenith-Quick-Installer/1.0" -H "Accept: application/vnd.github+json" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --header="User-Agent: Zenith-Quick-Installer/1.0" --header="Accept: application/vnd.github+json" "$url"
    else
        echo "Error: neither curl nor wget is installed." >&2
        return 1
    fi
}

download_file() {
    url="$1"
    out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -H "User-Agent: Zenith-Quick-Installer/1.0" -o "$out" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --header="User-Agent: Zenith-Quick-Installer/1.0" -O "$out" "$url"
    else
        echo "Error: neither curl nor wget is installed." >&2
        return 1
    fi
}

compute_sha256() {
    file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print tolower($1)}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print tolower($1)}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$file" | awk '{print tolower($NF)}'
    else
        printf '%s\n' ""
    fi
}

move_to_backup() {
    src="$1"
    [ -e "$src" ] || return 0
    mkdir -p "$BACKUP_DIR"
    base="$(basename "$src")"
    dst="$BACKUP_DIR/$base"
    idx=1
    while [ -e "$dst" ]; do
        dst="$BACKUP_DIR/$base.$idx"
        idx=$((idx + 1))
    done
    mv "$src" "$dst"
    printf '  %s -> %s\n' "$src" "$dst" >> "$TMP_DIR/backups.log"
}

find_release_asset() {
    json_file="$1"
    mode="$2" # rt or raster
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$json_file" "$mode" <<'PY'
import json, re, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
pattern = r"^zenith_rt-.*\.hshader$" if sys.argv[2] == "rt" else r"^zenith-[0-9].*\.hshader$"
for asset in data.get("assets", []):
    name = asset.get("name", "")
    if re.match(pattern, name):
        digest = asset.get("digest") or ""
        if digest.startswith("sha256:"):
            digest = digest[len("sha256:"):]
        print(f"{name}\t{asset.get('browser_download_url', '')}\t{digest}\t{data.get('tag_name', '')}")
        sys.exit(0)
sys.exit(1)
PY
    else
        regex="$( [ "$mode" = "rt" ] && printf 'zenith_rt-[^"]*\.hshader' || printf 'zenith-[0-9][^"]*\.hshader' )"
        url="$(grep -oE "https://github\.com/[^\"]*/$regex" "$json_file" | head -n 1 || true)"
        [ -n "$url" ] || return 1
        name="$(basename "$url")"
        printf '%s\t%s\t\t\n' "$name" "$url"
    fi
}

install_remote_asset() {
    json_file="$1"
    mode="$2"
    label="$3"
    info="$(find_release_asset "$json_file" "$mode")" || {
        echo "No release asset found for $label in $REPO ($TAG)." >&2
        return 1
    }
    asset_name="$(printf '%s' "$info" | awk -F '\t' '{print $1}')"
    asset_url="$(printf '%s' "$info" | awk -F '\t' '{print $2}')"
    expected_sha="$(printf '%s' "$info" | awk -F '\t' '{print tolower($3)}')"

    tmp_pkg="$TMP_DIR/$asset_name"
    echo "Downloading $asset_name..."
    download_file "$asset_url" "$tmp_pkg"

    actual_sha="$(compute_sha256 "$tmp_pkg")"
    if [ -n "$expected_sha" ] && [ -n "$actual_sha" ] && [ "$expected_sha" != "$actual_sha" ]; then
        echo "SHA-256 mismatch for $asset_name: expected $expected_sha, got $actual_sha" >&2
        return 1
    fi

    printf '%s\tfile\t%s\t%s\n' "$label" "$asset_name" "$actual_sha" >> "$TMP_DIR/staged.list"
}

stage_local_pack() {
    mode="$1"
    if [ "$mode" = "raster" ]; then
        [ -f "$LOCAL_REPO/pack/zenith/horizon-shaders.toml" ] || return 1
        cp -R "$LOCAL_REPO/pack/zenith" "$TMP_DIR/zenith"
        printf 'Zenith\tdir\tzenith\t\n' >> "$TMP_DIR/staged.list"
        return 0
    fi

    if command -v node >/dev/null 2>&1; then
        build_rel=".tmp-zenith-rt-install-$$"
        build_dir="$LOCAL_REPO/outputs/$build_rel"
        mkdir -p "$build_dir"
        echo "Building Zenith RT locally with Node.js..."
        if node "$LOCAL_REPO/tools/build-zenith-rt.mjs" "$build_dir/zenith_rt" >/dev/null && [ -f "$build_dir/zenith_rt/horizon-shaders.toml" ]; then
            cp -R "$build_dir/zenith_rt" "$TMP_DIR/zenith_rt"
            rm -rf "$build_dir"
        else
            rm -rf "$build_dir"
            return 1
        fi
    elif [ -f "$LOCAL_REPO/outputs/zenith-rt/zenith_rt/horizon-shaders.toml" ]; then
        echo "Using existing local build at $LOCAL_REPO/outputs/zenith-rt/zenith_rt..."
        cp -R "$LOCAL_REPO/outputs/zenith-rt/zenith_rt" "$TMP_DIR/zenith_rt"
    else
        echo "Cannot build Zenith RT locally: Node.js was not found and no prebuilt zenith_rt directory exists." >&2
        return 1
    fi
    printf 'Zenith RT\tdir\tzenith_rt\t\n' >> "$TMP_DIR/staged.list"
}

WANT_RT="0"
WANT_RASTER="0"
[ "$PACK" = "rt" ] || [ "$PACK" = "both" ] && WANT_RT="1"
[ "$PACK" = "raster" ] || [ "$PACK" = "both" ] && WANT_RASTER="1"

USE_LOCAL="$LOCAL_MODE"
if [ "$USE_LOCAL" = "0" ]; then
    API_URL="https://api.github.com/repos/$REPO/releases/latest"
    [ "$TAG" != "latest" ] && API_URL="https://api.github.com/repos/$REPO/releases/tags/$TAG"
    if fetch_text "$API_URL" > "$TMP_DIR/release.json" 2>/dev/null; then
        if [ "$WANT_RT" = "1" ]; then
            if ! install_remote_asset "$TMP_DIR/release.json" "rt" "Zenith RT"; then
                if [ -n "$LOCAL_REPO" ]; then
                    echo "Remote asset unavailable; falling back to local repository at $LOCAL_REPO." >&2
                    : > "$TMP_DIR/staged.list"
                    USE_LOCAL="1"
                else
                    exit 1
                fi
            fi
        fi
        if [ "$USE_LOCAL" = "0" ] && [ "$WANT_RASTER" = "1" ]; then
            if ! install_remote_asset "$TMP_DIR/release.json" "raster" "Zenith"; then
                if [ -n "$LOCAL_REPO" ]; then
                    echo "Remote asset unavailable; falling back to local repository at $LOCAL_REPO." >&2
                    : > "$TMP_DIR/staged.list"
                    USE_LOCAL="1"
                else
                    exit 1
                fi
            fi
        fi
    elif [ -n "$LOCAL_REPO" ]; then
        echo "GitHub release lookup failed; falling back to local repository at $LOCAL_REPO." >&2
        USE_LOCAL="1"
    else
        echo "Failed to fetch release metadata from $API_URL." >&2
        exit 1
    fi
fi

if [ "$USE_LOCAL" = "1" ]; then
    [ -n "$LOCAL_REPO" ] || {
        echo "Local mode requested, but no Zenith repository was found." >&2
        exit 1
    }
    [ "$WANT_RT" = "1" ] && stage_local_pack "rt"
    [ "$WANT_RASTER" = "1" ] && stage_local_pack "raster"
fi

# Clean misplaced repo archives inside shaderpacks/
for d in "$SHADERPACKS_DIR"/*; do
    [ -d "$d" ] || continue
    if [ ! -f "$d/horizon-shaders.toml" ] && [ -f "$d/pack/zenith/horizon-shaders.toml" ]; then
        move_to_backup "$d"
    fi
done

: > "$TMP_DIR/installed.log"
while IFS="$(printf '\t')" read -r label kind name sha; do
    [ -n "$name" ] || continue
    if [ "$label" = "Zenith RT" ]; then
        move_to_backup "$SHADERPACKS_DIR/zenith_rt"
        for old_pkg in "$SHADERPACKS_DIR"/zenith_rt*.hshader; do
            [ -e "$old_pkg" ] && move_to_backup "$old_pkg"
        done
    else
        move_to_backup "$SHADERPACKS_DIR/zenith"
        for old_pkg in "$SHADERPACKS_DIR"/zenith-*.hshader; do
            [ -e "$old_pkg" ] && move_to_backup "$old_pkg"
        done
    fi

    dest="$SHADERPACKS_DIR/$name"
    if [ "$kind" = "file" ]; then
        cp -f "$TMP_DIR/$name" "$dest"
    else
        cp -R "$TMP_DIR/$name" "$dest"
    fi
    printf '%s\t%s\t%s\n' "$label" "$dest" "$sha" >> "$TMP_DIR/installed.log"
done < "$TMP_DIR/staged.list"

echo ""
echo "Installation complete!"
echo "Target directory: $SHADERPACKS_DIR"
while IFS="$(printf '\t')" read -r label dest sha; do
    if [ -n "$sha" ]; then
        printf '  - %s: %s (sha256: %.12s...)\n' "$label" "$dest" "$sha"
    else
        printf '  - %s: %s\n' "$label" "$dest"
    fi
done < "$TMP_DIR/installed.log"

if [ -s "$TMP_DIR/backups.log" ]; then
    echo ""
    echo "Previous files / misplaced source folders moved to backup:"
    cat "$TMP_DIR/backups.log"
fi

echo ""
echo "Next steps in Horizon:"
echo "  1. Open Shader Packs and select Zenith RT (or Zenith)."
if [ "$WANT_RT" = "1" ]; then
    echo "  2. Restart Horizon after selecting Zenith RT so hardware ray queries are enabled."
    echo "  3. Adjust RT quality under Effects -> Ray Tracing (Reflections / Reflections + Shadows / Full RT)."
fi
