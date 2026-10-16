#!/bin/sh
# Publr installer: the publr command for your OS and CPU, on your PATH.
#   curl -fsSL https://publr.dev/install.sh | sh
#
# With `sites`, also a folder for sites on this computer, the first one made:
#   curl -fsSL https://publr.dev/install.sh | sh -s sites
#
#   sites/
#     publr          the binary every site here runs, so an update elsewhere never changes them
#     blog/          publr.zon, apps/, plugins/, data/
#
# The command's folder goes on your PATH through your shell's profile (~/.zshrc, ~/.bashrc).
#
# Optional:
#   PUBLR_BIN_DIR=<folder>    where the command goes (default: ~/.local/bin)
#   PUBLR_HOME=<folder>       sites: where, without asking (empty asks; "." is here)
#   PUBLR_FIRST_SITE=<name>   sites: the first site, without asking ("-" for none)
#   PUBLR_VERSION=v0.2.0      a release (default: latest)
#   PUBLR_BINARY=<file>       a publr you built, copied instead of downloaded
# Run again to update the command; a sites folder's binary and its sites stay as they are.
#
# Trust: this script is only as trustworthy as where you got it. The README publishes its SHA-256 and a
# tag-pinned GitHub URL; verify before running if that matters to you. The binary's own checksum is
# checked below against the .sha256 published with the release.
set -eu

repo="https://github.com/publr-org/publr/releases"
version="${PUBLR_VERSION:-latest}"
bin_dir="${PUBLR_BIN_DIR:-$HOME/.local/bin}"

case "${1:-}" in
    "") sites=false ;;
    sites) sites=true ;;
    *) echo "publr: unknown '$1'; run with nothing for the command, or 'sites' for a sites folder too" >&2; exit 2 ;;
esac

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

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

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
}

if [ -n "${PUBLR_BINARY:-}" ]; then
    cp "$PUBLR_BINARY" "$tmp/publr"
else
    download
fi

mkdir -p "$bin_dir"
install -m 755 "$tmp/publr" "$bin_dir/publr"
echo "publr: $("$bin_dir/publr" --version) in $bin_dir/publr"

# On the PATH from the next terminal on: the line added to the shell's profile once, as
# other installers do. This terminal is told how to use it now.
case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *)
        case "${SHELL:-}" in
            */zsh)  profile="$HOME/.zshrc" ;;
            */bash) profile="$HOME/.bashrc" ;;
            *)      profile="" ;;
        esac
        line="export PATH=\"$bin_dir:\$PATH\""
        if [ -n "$profile" ]; then
            if ! grep -qsF "$line" "$profile"; then
                printf '\n# publr\n%s\n' "$line" >> "$profile"
                echo "publr: added $bin_dir to your PATH in $profile"
            fi
        else
            echo "publr: add this line to your shell's profile to use publr anywhere:"
            echo "  $line"
        fi
        ;;
esac

if [ "$sites" = false ]; then
    exit 0
fi

home="${PUBLR_HOME:-}"
if [ -z "$home" ]; then
    home="$(ask "Folder for your sites (empty: here): ")"
fi
[ -z "$home" ] && home="."
mkdir -p "$home"
cd "$home"

if [ ! -e ./publr ]; then
    install -m 755 "$tmp/publr" ./publr
fi

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
