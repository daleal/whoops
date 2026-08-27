#!/bin/sh
set -eu

DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
FRAMEWORKS="$DEVELOPER_DIR/Library/Developer/Frameworks"
TEST_LIBS="$DEVELOPER_DIR/Library/Developer/usr/lib"

if [ -d "$FRAMEWORKS/Testing.framework" ]; then
  swift test \
    -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
    -Xlinker -F -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$TEST_LIBS"
else
  swift test
fi
