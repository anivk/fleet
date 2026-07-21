#!/bin/sh
# Install the fleet binary (macOS + Linux, amd64 + arm64).
#
#   curl -fsSL https://raw.githubusercontent.com/anivk/fleet/main/get.sh | sh
#
# Works whether the repo is public or private:
#   public  — a plain anonymous download.
#   private — needs auth on this box: either `gh` (logged in) or a GITHUB_TOKEN env
#             var with repo read access. (A fresh box with neither can't pull a
#             private binary — make the repo public, or scp the binary over.)
#
# Env: FLEET_INSTALL_DIR (default /usr/local/bin), FLEET_VERSION (default latest).
set -eu
REPO="anivk/fleet"

os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
case "$arch" in
  x86_64|amd64) arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) echo "get: unsupported arch: $arch" >&2; exit 1 ;;
esac
case "$os" in
  darwin|linux) ;;
  *) echo "get: unsupported OS: $os (macOS + Linux only)" >&2; exit 1 ;;
esac

asset="fleet-${os}-${arch}"
ver="${FLEET_VERSION:-latest}"
dest="${FLEET_INSTALL_DIR:-/usr/local/bin}"
tmp=$(mktemp)

# 1. anonymous (public repo)
if [ "$ver" = latest ]; then
  url="https://github.com/$REPO/releases/latest/download/$asset"
else
  url="https://github.com/$REPO/releases/download/$ver/$asset"
fi
echo "get: downloading $asset ($ver)…"
if ! curl -fSL --progress-bar "$url" -o "$tmp" 2>/dev/null; then
  # 2. gh (private repo, logged in)
  if command -v gh >/dev/null 2>&1; then
    tag="$ver"; [ "$tag" = latest ] && tag=$(gh release view -R "$REPO" --json tagName -q .tagName 2>/dev/null)
    echo "get: (private repo) fetching via gh release download…"
    gh release download "$tag" -R "$REPO" -p "$asset" -O "$tmp" --clobber 2>/dev/null || { echo "get: gh download failed" >&2; rm -f "$tmp"; exit 1; }
  # 3. GITHUB_TOKEN + API (private repo, no gh)
  elif [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "get: (private repo) fetching via API token…"
    rel="latest"; [ "$ver" != latest ] && rel="tags/$ver"
    aid=$(curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" \
      "https://api.github.com/repos/$REPO/releases/$rel" \
      | tr ',{' '\n\n' | grep -A2 "\"name\": *\"$asset\"" | grep '"id"' | head -1 | grep -o '[0-9]\+') || true
    [ -n "${aid:-}" ] || { echo "get: could not resolve asset id for $asset" >&2; rm -f "$tmp"; exit 1; }
    curl -fSL --progress-bar -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/octet-stream" \
      "https://api.github.com/repos/$REPO/releases/assets/$aid" -o "$tmp" || { echo "get: token download failed" >&2; rm -f "$tmp"; exit 1; }
  else
    echo "get: download failed — $REPO is private and this box has no auth." >&2
    echo "     install 'gh' and 'gh auth login', or set GITHUB_TOKEN, then re-run." >&2
    rm -f "$tmp"; exit 1
  fi
fi

chmod +x "$tmp"
if [ -w "$dest" ]; then
  mv "$tmp" "$dest/fleet"
else
  echo "get: $dest not writable — using sudo"
  sudo mv "$tmp" "$dest/fleet"
fi

echo "get: installed $dest/fleet"
"$dest/fleet" --version 2>/dev/null || true
echo
echo "next:"
echo "  fleet init server   # provision this box (deps + claude) AND wire config/hooks"
echo "  fleet init client   # laptop that only watches remotes (skips provisioning)"
