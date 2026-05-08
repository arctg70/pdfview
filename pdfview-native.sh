#!/bin/bash
# Launch the native macOS PDF Viewer
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/PDFViewer.app"

if [ ! -d "$APP" ]; then
    echo "Building native app first..."
    cd "$DIR/native" && make bundle
fi

if [ $# -eq 0 ]; then
    open "$APP"
else
    # Open with specific file
    open -a "$APP" "$@"
fi
