#!/bin/sh
# Rewrite sources files to point to locally vendored tarballs.
# Run after download_sources.sh.
set -e

cd "$(dirname "$0")"

REPO=fixtures/repo
SOURCES=fixtures/sources

for pkg_dir in "$REPO"/*/; do
    pkg=$(basename "$pkg_dir")
    [ -f "$pkg_dir/sources" ] || continue
    [ -f "$pkg_dir/version" ] || continue

    read -r ver rel < "$pkg_dir/version"
    IFS=.+-_ read -r major minor patch ident <<EOF
$ver
EOF

    tmpfile="$pkg_dir/sources.new"
    changed=0

    while IFS= read -r line; do
        src="${line%% *}"
        rest="${line#"$src"}"

        case "$src" in
            \#*|"")
                printf '%s\n' "$line"
                ;;
            http*|ftp*)
                # Resolve placeholders to get the filename.
                url="$src"
                url=$(echo "$url" | sed "s|VERSION|$ver|g")
                url=$(echo "$url" | sed "s|MAJOR|$major|g")
                url=$(echo "$url" | sed "s|MINOR|$minor|g")
                url=$(echo "$url" | sed "s|PATCH|$patch|g")
                url=$(echo "$url" | sed "s|IDENT|$ident|g")
                url=$(echo "$url" | sed "s|RELEASE|$rel|g")
                url=$(echo "$url" | sed "s|PACKAGE|$pkg|g")
                filename="${url##*/}"

                if [ -f "$SOURCES/$pkg/$filename" ]; then
                    # Use absolute path that will be valid inside Docker.
                    printf '/home/kominka/sources/%s/%s%s\n' "$pkg" "$filename" "$rest"
                    changed=1
                else
                    printf '%s\n' "$line"
                    echo "WARNING: $pkg - missing source: $filename" >&2
                fi
                ;;
            *)
                printf '%s\n' "$line"
                ;;
        esac
    done < "$pkg_dir/sources" > "$tmpfile"

    if [ "$changed" = 1 ]; then
        mv -f "$tmpfile" "$pkg_dir/sources"
        echo "Localized: $pkg/sources"
    else
        rm -f "$tmpfile"
    fi
done
