#!/bin/sh
# Download all remote sources for vendored Kominka packages.
# Run once to populate tests/fixtures/sources/.
set -e

cd "$(dirname "$0")"

REPO=fixtures/repo
SOURCES=fixtures/sources

mkdir -p "$SOURCES"

for pkg_dir in "$REPO"/*/; do
    pkg=$(basename "$pkg_dir")
    [ -f "$pkg_dir/sources" ] || continue
    [ -f "$pkg_dir/version" ] || continue

    read -r ver rel < "$pkg_dir/version"

    # Split version into components (MAJOR.MINOR.PATCH).
    IFS=.+-_ read -r major minor patch ident <<EOF
$ver
EOF

    echo "==> $pkg ($ver-$rel)"

    mkdir -p "$SOURCES/$pkg"

    # Read each source line, download remote URLs.
    while read -r src dest; do
        case "$src" in
            \#*|"") continue ;;
            http*|ftp*)
                # Resolve placeholders.
                url="$src"
                url=$(echo "$url" | sed "s|VERSION|$ver|g")
                url=$(echo "$url" | sed "s|MAJOR|$major|g")
                url=$(echo "$url" | sed "s|MINOR|$minor|g")
                url=$(echo "$url" | sed "s|PATCH|$patch|g")
                url=$(echo "$url" | sed "s|IDENT|$ident|g")
                url=$(echo "$url" | sed "s|RELEASE|$rel|g")
                url=$(echo "$url" | sed "s|PACKAGE|$pkg|g")

                filename="${url##*/}"
                outfile="$SOURCES/$pkg/$filename"

                if [ -f "$outfile" ]; then
                    echo "    [cached] $filename"
                else
                    echo "    [fetch]  $url"
                    curl -fL --retry 3 -o "$outfile" "$url" || {
                        echo "    [FAIL]   $url"
                        rm -f "$outfile"
                    }
                fi
                ;;
        esac
    done < "$pkg_dir/sources"
done

echo ""
echo "Done. Total size:"
du -sh "$SOURCES"
