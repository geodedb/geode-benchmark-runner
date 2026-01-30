#!/bin/bash
# Fix all bufferedReader calls
for f in src/*.zig; do
    sed -i 's/std\.io\.bufferedReader(\([^)]*\)\.reader())/std.io.bufferedReader(\1)/g' "$f"
done
