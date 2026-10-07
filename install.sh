#!/bin/sh
# Publr installer: a folder holding the publr binary for your OS and CPU, and your sites, each
# a folder beside it (`./publr new <name>`). Nothing goes on your PATH.
#   curl -fsSL https://publr.dev/install.sh | sh
#
#   sites/
#     publr          the binary every site here runs
#     blog/          publr.zon, apps/, plugins/, data/
#
# Optional:
#   PUBLR_HOME=<folder>       where, without asking (empty asks; "." is here)
#   PUBLR_FIRST_SITE=<name>   the first site, without asking ("-" for none)
#   PUBLR_VERSION=v0.2.0      a release (default: latest)
#   PUBLR_BINARY=<file>       a publr you built, copied instead of downloaded
# Run again in the same folder to update the binary; the sites stay as they are.
#
# Trust: this script is only as trustworthy as where you got it. The README publishes its SHA-256 and a
# tag-pinned GitHub URL; verify before running if that matters to you. The binary's own checksum is
# checked below against the .sha256 published with the release.
set -eu

repo="https://github.com/publr-org/publr/releases"
version="${PUBLR_VERSION:-latest}"

# Asked on the terminal, so it works when this script itself comes through a pipe.
ask() {
    if [ -r /dev/tty ]; then
        printf '%s' "$1" > /dev/tty
        read -r answer < /dev/tty || answer=""
    else
        answer=""
    fi
    printf '%s' "$answer"
}

home="${PUBLR_HOME:-}"
if [ -z "$home" ]; then
    home="$(ask "Folder for Publr and your sites (empty: here): ")"
fi
[ -z "$home" ] && home="."
mkdir -p "$home"
cd "$home"

download() {
    case "$(uname -s)" in
        Darwin) os="macos" ;;
        Linux)  os="linux" ;;
        *) echo "publr: unsupported OS '$(uname -s)'; download a build from $repo" >&2; exit 1 ;;
    esac

    case "$(uname -m)" in
        arm64|aarch64) arch="aarch64" ;;
        x86_64|amd64)  arch="x86_64" ;;
        *) echo "publr: unsupported CPU '$(uname -m)'; download a build from $repo" >&2; exit 1 ;;
    esac

    file="publr-$os-$arch"
    if [ "$version" = "latest" ]; then
        url="$repo/latest/download/$file"
    else
        url="$repo/download/$version/$file"
    fi

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    echo "publr: downloading $url"
    if ! curl -fsSL "$url" -o "$tmp/publr" || ! curl -fsSL "$url.sha256" -o "$tmp/publr.sha256"; then
        echo "publr: no $file at $repo ($version); build one (zig build) and run this with" >&2
        echo "       PUBLR_BINARY=<path to zig-out/bin/publr>" >&2
        exit 1
    fi

    expected="$(cut -d' ' -f1 < "$tmp/publr.sha256")"
    if command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum "$tmp/publr" | cut -d' ' -f1)"
    else
        actual="$(shasum -a 256 "$tmp/publr" | cut -d' ' -f1)"
    fi
    if [ "$expected" != "$actual" ]; then
        echo "publr: checksum mismatch, refusing to install" >&2
        exit 1
    fi

    install -m 755 "$tmp/publr" ./publr
}

if [ -n "${PUBLR_BINARY:-}" ]; then
    install -m 755 "$PUBLR_BINARY" ./publr
else
    download
fi

echo "publr: $(./publr --version) in $(pwd)/publr"

site="${PUBLR_FIRST_SITE:-}"
if [ -z "$site" ]; then
    site="$(ask "Name of your first site (empty: none yet): ")"
fi
if [ -n "$site" ] && [ "$site" != "-" ] && [ ! -e "$site" ]; then
    ./publr new "$site"
else
    echo
    echo "Next:"
    echo "  cd $(pwd)"
    echo "  ./publr new <name>        # a site: a folder beside the binary"
fi
