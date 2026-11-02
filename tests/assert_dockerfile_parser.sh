#!/usr/bin/env bash
set -euo pipefail

PARSER_BIN="$1"
DOCKERFILE="$2"
EXPECTED_OUTPUT="output.json"

"$PARSER_BIN" --dockerfile "$DOCKERFILE" --output "$EXPECTED_OUTPUT"

# Verify output exists and is non-empty
if [ ! -s "$EXPECTED_OUTPUT" ]; then
    echo "Error: expected output $EXPECTED_OUTPUT is empty or does not exist" >&2
    exit 1
fi

# Verify JSON contains expected fields using python3 json
python3 -c '
import json, sys
data = json.load(open("output.json"))
if not isinstance(data, list):
    sys.exit("Error: Expected top-level JSON to be an array of layers")

if len(data) != 4:
    sys.exit(f"Error: Expected 4 layers, got {len(data)}")

# Verify first layer is FROM
if data[0]["command"] != "FROM":
    sys.exit(f"Error: Layer 0 command expected FROM, got {data[0]['command']}")

# Verify second layer is RUN and has shell_ast
if data[1]["command"] != "RUN":
    sys.exit(f"Error: Layer 1 command expected RUN, got {data[1]['command']}")

ast = data[1].get("shell_ast")
if not ast:
    sys.exit("Error: Layer 1 missing shell_ast")

if ast.get("type") != "Script":
    sys.exit(f"Error: AST type expected Script, got {ast.get('type')}")

print("Dockerfile parser assertion passed successfully!")
'
