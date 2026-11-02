# rules_containers_util

A set of rules to operate on container images, such as extracting files or directories from a container image and making them available to Bazel actions.

## Installation

Add to your `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_containers_util", version = "0.0.1")

# Register dockerfile_parser toolchains (prebuilt by default)
containers = use_extension("@rules_containers_util//containers:extensions.bzl", "containers")
containers.toolchains()
use_repo(containers, "dockerfile_parser_toolchains")

register_toolchains("@dockerfile_parser_toolchains//:all")
```

Users who want to build the tool from source instead can opt in via `containers.toolchains(from_source = True)` (requires `rules_go`).

> [!NOTE]
> Until a new release of `rules_img` containing `flatten-image` is published to the Bazel Central Registry (BCR), configure the `rules_img` pre-release registry in your `.bazelrc`:
>
> ```text
> common --registry=https://bazel-contrib.github.io/rules_img --registry=https://bcr.bazel.build
> ```

## Usage

### Extract a file or directory

```starlark
load("@rules_containers_util//containers:defs.bzl", "image_extract")

# Extract a single file
image_extract(
    name = "extracted_tool",
    file = "/usr/local/bin/tool",
    image = ":my_image",
)

# Extract a directory
image_extract(
    name = "extracted_data",
    directory = "/opt/data",
    image = ":my_image",
)

# Extract multiple files
image_extract(
    name = "extracted_files",
    files = {
        "/etc/app/config.txt": "config.txt",
        "/usr/local/bin/helper": "helper",
    },
    image = ":my_image",
)
```
