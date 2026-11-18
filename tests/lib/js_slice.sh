#!/bin/sh
# shellcheck shell=sh
# Slices one function out of a JavaScript file, so a test runs the view's own
# code rather than a copy of it. Source it, then:
#
#   js_slice <file> <name> [indent]
#
# prints from the line "<indent>function <name>(" through the first line that
# starts with "<indent>}". Without an indent that is a top-level declaration,
# closed in column 1; a function nested in render() passes its leading tabs
# ("$(printf '\t\t')"). Nothing is printed when the function is not there:
# check the slice before trusting the assertions built on it.
#
# String tests (index, substr), never a regex: CI runs mawk, macOS has BSD awk,
# and neither has to agree with the other on escapes inside a dynamic regex.

js_slice() {
    awk -v fn="$2" -v ind="${3:-}" '
        !inside && index($0, ind "function " fn "(") == 1 { inside = 1 }
        inside { print }
        inside && substr($0, 1, length(ind) + 1) == ind "}" { exit }
    ' "$1"
}
