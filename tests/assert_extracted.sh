#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="$1"
TOOL_SCRIPT="$2"
EXTRACTED_DIR="$3"

echo "Checking extracted config file: $CONFIG_FILE"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: config file $CONFIG_FILE not found" >&2
  exit 1
fi

CONTENT=$(cat "$CONFIG_FILE")
echo "Config content: $CONTENT"
if [[ "$CONTENT" != *"version=2"* ]]; then
  echo "Error: expected config to have 'version=2' from layer 2, got '$CONTENT'" >&2
  exit 1
fi

echo "Checking extracted tool script: $TOOL_SCRIPT"
if [[ ! -f "$TOOL_SCRIPT" ]]; then
  echo "Error: tool script $TOOL_SCRIPT not found" >&2
  exit 1
fi

TOOL_OUTPUT=$("$TOOL_SCRIPT")
echo "Tool output: $TOOL_OUTPUT"
if [[ "$TOOL_OUTPUT" != *"tool-output-success"* ]]; then
  echo "Error: unexpected tool output '$TOOL_OUTPUT'" >&2
  exit 1
fi

echo "Checking extracted directory: $EXTRACTED_DIR"
if [[ ! -d "$EXTRACTED_DIR" ]]; then
  echo "Error: directory $EXTRACTED_DIR not found" >&2
  exit 1
fi

if [[ ! -f "$EXTRACTED_DIR/first.txt" ]]; then
  echo "Error: $EXTRACTED_DIR/first.txt not found" >&2
  exit 1
fi

if [[ ! -f "$EXTRACTED_DIR/second.txt" ]]; then
  echo "Error: $EXTRACTED_DIR/second.txt not found" >&2
  exit 1
fi

if [[ -f "$EXTRACTED_DIR/deleted.txt" ]]; then
  echo "Error: $EXTRACTED_DIR/deleted.txt was not deleted by whiteout" >&2
  exit 1
fi

if [[ -f "$EXTRACTED_DIR/.wh.deleted.txt" ]]; then
  echo "Error: whiteout file $EXTRACTED_DIR/.wh.deleted.txt was not cleaned up" >&2
  exit 1
fi

echo "All extract tests passed successfully!"
