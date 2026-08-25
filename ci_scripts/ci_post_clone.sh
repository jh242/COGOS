#!/bin/sh
set -eu
"$(CDPATH= cd -- "$(dirname "$0")" && pwd)/trust_macros.sh" --resolve
