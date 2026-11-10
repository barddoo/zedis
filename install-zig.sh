#!/usr/bin/env bash
# Install Zig from the community mirrors, falling back to ziglang.org.
# Follows https://ziglang.org/download/community-mirrors/: every tarball is verified against
# the ZSF minisign key and the signature's trusted-comment "file" field must match the name
# we asked for (downgrade protection). A mirror that fails any step is skipped.
#
# usage: install-zig.sh VERSION MINISIGN_PUBKEY [DEST]
set -euo pipefail

version=${1:?zig version required}
pubkey=${2:?minisign public key required}
dest=${3:-/usr/local}

case "$(uname -m)" in
  x86_64) arch=x86_64 ;;
  aarch64 | arm64) arch=aarch64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

name="zig-${arch}-linux-${version}.tar.xz"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mirror_list=https://ziglang.org/download/community-mirrors.txt
mirrors=$(curl -fsSL --retry 3 "$mirror_list" | shuf || true)
if [ -z "$mirrors" ]; then
  echo "could not fetch $mirror_list; using ziglang.org only" >&2
fi

# Official site last; its tarballs live under /download/<version>/.
for base in $mirrors "https://ziglang.org/download/${version}"; do
  echo "trying $base" >&2
  curl -fsSL --retry 2 -o "$work/$name" "$base/$name?source=zedis-docker" || continue
  curl -fsSL --retry 2 -o "$work/$name.minisig" "$base/$name.minisig?source=zedis-docker" || continue

  minisign -Vm "$work/$name" -x "$work/$name.minisig" -P "$pubkey" >/dev/null || {
    echo "signature check failed for $base" >&2
    continue
  }

  signed_name=$(grep '^trusted comment:' "$work/$name.minisig" | grep -o 'file:[^[:space:]]*' | head -n1 | cut -d: -f2-)
  if [ "$signed_name" != "$name" ]; then
    echo "signature is for '$signed_name', expected '$name' ($base)" >&2
    continue
  fi

  tar -xJf "$work/$name" -C "$dest"
  ln -sf "$dest/zig-${arch}-linux-${version}/zig" /usr/local/bin/zig
  echo "installed zig ${version} (${arch}) from $base" >&2
  exit 0
done

echo "failed to install zig ${version} from any mirror" >&2
exit 1
