#!/usr/bin/env bash
set -euo pipefail

# Expand param file (@path) if provided
if [[ $# -eq 1 && "$1" == @* ]]; then
  PARAM_FILE="${1#@}"
  ARGS=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    ARGS+=("$line")
  done < "$PARAM_FILE"
  set -- "${ARGS[@]}"
fi

OUTPUT_TAR=""
BSDTAR=""
IMG=""
MANIFEST=""
CONFIG=""
declare -a LAYERS=()
declare -a FILES=()
declare -a DIRS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output_tar)
      OUTPUT_TAR="$2"
      shift 2
      ;;
    --bsdtar)
      BSDTAR="$2"
      shift 2
      ;;
    --img)
      IMG="$2"
      shift 2
      ;;
    --manifest)
      MANIFEST="$2"
      shift 2
      ;;
    --config)
      CONFIG="$2"
      shift 2
      ;;
    --layer)
      LAYERS+=("$2")
      shift 2
      ;;
    --file)
      FILES+=("$2" "$3")
      shift 3
      ;;
    --dir)
      DIRS+=("$2" "$3")
      shift 3
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$OUTPUT_TAR" ]]; then
  echo "Error: --output_tar is required" >&2
  exit 1
fi

if [[ -z "$BSDTAR" ]]; then
  echo "Error: --bsdtar is required" >&2
  exit 1
fi

if [[ -z "$IMG" || -z "$MANIFEST" || -z "$CONFIG" ]]; then
  echo "Error: --img, --manifest, and --config are required" >&2
  exit 1
fi

# Flatten image using rules_img flatten-image
FLATTEN_ARGS=(
  flatten-image
  --source-manifest "$MANIFEST"
  --source-config "$CONFIG"
  --format none
  --history=
  --manifest manifest_flattened.json
  --config config_flattened.json
  --descriptor descriptor_flattened.json
  --digest digest_flattened
  --layer-blob "$OUTPUT_TAR"
  --layer-metadata meta_flattened.json
)
for layer in "${LAYERS[@]}"; do
  FLATTEN_ARGS+=(--layer "$layer")
done

"$IMG" "${FLATTEN_ARGS[@]}"

# Extract requested targets into sandbox rootfs without unpacking the entire image
ROOTFS="./_rootfs"
mkdir -p "$ROOTFS"

TARGETS=()
EXTRACT_ALL=0

for ((i=0; i<${#FILES[@]}; i+=2)); do
  cpath="${FILES[i]}"
  cpath="${cpath#/}"
  cpath="${cpath#./}"
  TARGETS+=("$cpath")
done

for ((i=0; i<${#DIRS[@]}; i+=2)); do
  cpath="${DIRS[i]}"
  cpath="${cpath#/}"
  cpath="${cpath#./}"
  cpath="${cpath%/}"
  if [[ -z "$cpath" || "$cpath" == "." ]]; then
    EXTRACT_ALL=1
    break
  fi
  TARGETS+=("$cpath")
done

if [[ $EXTRACT_ALL -eq 1 || ${#TARGETS[@]} -eq 0 ]]; then
  "$BSDTAR" -xf "$OUTPUT_TAR" -C "$ROOTFS"
else
  "$BSDTAR" -xf "$OUTPUT_TAR" -C "$ROOTFS" "${TARGETS[@]}"
fi

# Process files
for ((i=0; i<${#FILES[@]}; i+=2)); do
  cpath="${FILES[i]}"
  out="${FILES[i+1]}"
  norm_cpath="${cpath#/}"
  norm_cpath="${norm_cpath#./}"
  src="$ROOTFS/$norm_cpath"
  if [[ ! -e "$src" && ! -L "$src" ]]; then
    echo "Error: file '$cpath' not found in container image" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$out")"
  rm -f "$out"
  cp -a "$src" "$out"
done

# Process directories
for ((i=0; i<${#DIRS[@]}; i+=2)); do
  cpath="${DIRS[i]}"
  out="${DIRS[i+1]}"
  norm_cpath="${cpath#/}"
  norm_cpath="${norm_cpath#./}"
  norm_cpath="${norm_cpath%/}"
  mkdir -p "$out"
  if [[ -z "$norm_cpath" || "$norm_cpath" == "." ]]; then
    cp -a "$ROOTFS"/. "$out"/
  else
    src="$ROOTFS/$norm_cpath"
    if [[ ! -d "$src" ]]; then
      echo "Error: directory '$cpath' not found in container image" >&2
      exit 1
    fi
    cp -a "$src"/. "$out"/
  fi
done
