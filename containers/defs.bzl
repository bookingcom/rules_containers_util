"""Public rules and definitions for containers."""

load(
    "//containers/private:image_extract.bzl",
    _ImageExtractInfo = "ImageExtractInfo",
    _image_extract_rule = "image_extract_rule",
)

ImageExtractInfo = _ImageExtractInfo
image_extract_rule = _image_extract_rule

def image_extract(
        name,
        image,
        file = None,
        directory = None,
        files = None,
        directories = None,
        out = None,
        platform = None,
        flatten_format = "none",
        **kwargs):
    """Extracts files or directories from a container image.

    This macro flattens the input rules_img container image using the rules_img
    toolchain and extracts the requested files or directories using the tar.bzl
    bsdtar toolchain.

    Args:
        name: Name of the target.
        image: Container image target (ImageManifestInfo or ImageIndexInfo).
        file: Single file path in container to extract.
        directory: Single directory path in container to extract.
        files: List of file paths or dict of {container_path: output_name}.
        directories: List of directory paths or dict of {container_path: output_name}.
        out: Output file or directory name when 'file' or 'directory' is used.
        platform: Platform specification (e.g. 'linux/amd64') for multi-platform images.
        flatten_format: Format for intermediate flattened layer ('none', 'gzip', 'zstd').
        **kwargs: Common rule attributes (e.g., visibility, tags).
    """
    file_dict = {}
    if files != None:
        if type(files) == "dict":
            file_dict.update(files)
        elif type(files) == "list":
            for p in files:
                norm = p.rstrip("/")
                out_n = norm.split("/")[-1]
                file_dict[p] = out_n
        else:
            fail("files must be a list or dict")

    dir_dict = {}
    if directories != None:
        if type(directories) == "dict":
            dir_dict.update(directories)
        elif type(directories) == "list":
            for p in directories:
                norm = p.strip("/")
                out_n = norm.split("/")[-1] if norm else name
                dir_dict[p] = out_n
        else:
            fail("directories must be a list or dict")

    _image_extract_rule(
        name = name,
        image = image,
        file = file or "",
        directory = directory or "",
        files = file_dict,
        directories = dir_dict,
        out = out or "",
        platform = platform or "",
        flatten_format = flatten_format,
        **kwargs
    )
