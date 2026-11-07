# rules_containers_util

A set of rules to operate on container images, such as extracting files or directories from a container image and making them available to Bazel actions.

## Installation

Add to your `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_containers_util", version = "0.0.1")
```

The prebuilt `dockerfile_parser` toolchains are registered automatically. Users who want to build the tool from source instead can opt in via:

```starlark
containers = use_extension("@rules_containers_util//containers:extensions.bzl", "containers")
containers.toolchains(from_source = True)
```

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
