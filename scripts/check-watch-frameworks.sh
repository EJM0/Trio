#!/bin/sh
# Fails the build when the watch app loads an @rpath framework it doesn't embed, or embeds one that isn't for watchOS.
# xcodebuild test puts the products folder on the framework search path, so a missing embed only shows on launch.
app="${1:-$TARGET_BUILD_DIR/$WRAPPER_NAME}"
frameworks="$app/Frameworks"
status=0

check() {
    for dependency in $(otool -L "$1" | awk '$1 ~ /^@rpath\/.*\.framework\// { print $1 }' | sort -u); do
        name=${dependency#@rpath/}
        name=${name%%/*}
        if [ ! -d "$frameworks/$name" ]; then
            echo "error: $(basename "$1") loads $dependency, which the watch app does not embed"
            status=1
        fi
    done
}

for file in "$app"/*; do
    [ -f "$file" ] && file -b "$file" | grep -q Mach-O && check "$file"
done
for framework in "$frameworks"/*.framework; do
    [ -d "$framework" ] || continue
    binary="$framework/$(basename "$framework" .framework)"
    check "$binary"
    platform=$(otool -l "$binary" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "platform" { print $2; exit }')
    case "$platform" in
    4 | 9 | WATCHOS | WATCHOSSIMULATOR) ;;
    *)
        echo "error: $(basename "$framework") embedded in the watch app is not built for watchOS (platform $platform)"
        status=1
        ;;
    esac
done
exit $status
