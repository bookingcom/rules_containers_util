#!/usr/bin/env bash
# Prepares a release: creates the source archive used by the Bazel Central Registry
# and prints the release notes.
#
# Usage: .github/workflows/release_prep.sh <tag>
set -o errexit -o nounset -o pipefail

TAG=$1
VERSION=${TAG#v}
PREFIX="rules_containers_util-${VERSION}"
ARCHIVE="rules_containers_util-${TAG}.tar.gz"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git archive --format=tar --prefix="${PREFIX}/" "${TAG}" | tar -x -C "$work"

# Stamp the module version.
sed -i.bak "0,/version = \".*\"/s//version = \"${VERSION}\"/" "$work/$PREFIX/MODULE.bazel"
rm -f "$work/$PREFIX/MODULE.bazel.bak"

tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@0" -C "$work" -cf - "$PREFIX" | gzip -n >"$ARCHIVE"

cat <<NOTES
# rules_containers_util ${VERSION}

## Using Bzlmod

Add to your \`MODULE.bazel\`:

\`\`\`starlark
bazel_dep(name = "rules_containers_util", version = "${VERSION}")
\`\`\`

> [!NOTE]
> Until a new release of \`rules_img\` is published to BCR, you must configure the \`rules_img\` pre-release registry in your \`.bazelrc\`:
>
> \`\`\`text
> common --registry=https://bazel-contrib.github.io/rules_img --registry=https://bcr.bazel.build
> \`\`\`

### Example

\`\`\`starlark
load("@rules_containers_util//containers:defs.bzl", "image_extract")

image_extract(
    name = "extracted_tool",
    image = ":my_image",
    file = "/usr/local/bin/my_tool",
)
\`\`\`
NOTES
