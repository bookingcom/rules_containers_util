"""Implementation of image_extract rule."""

load("@rules_img//img:providers.bzl", "ImageIndexInfo", "ImageManifestInfo")

ImageExtractInfo = provider(
    doc = "Information about extracted container image files and directories",
    fields = {
        "directories": "Dict of container_path: TreeArtifact for extracted directories",
        "files": "Dict of container_path: File for extracted files",
        "flattened_layer": "File containing the flattened tarball",
    },
)

def _select_manifest(ctx):
    if ImageManifestInfo in ctx.attr.image:
        return ctx.attr.image[ImageManifestInfo]

    if ImageIndexInfo in ctx.attr.image:
        index_info = ctx.attr.image[ImageIndexInfo]
        if ctx.attr.platform:
            for manifest in index_info.manifests:
                plat = "{}/{}".format(manifest.os, manifest.architecture)
                if manifest.variant:
                    plat_variant = "{}/{}/{}".format(manifest.os, manifest.architecture, manifest.variant)
                    if plat_variant == ctx.attr.platform:
                        return manifest
                if plat == ctx.attr.platform:
                    return manifest
            fail("No manifest in {} matched platform '{}'".format(ctx.attr.image.label, ctx.attr.platform))

        if len(index_info.manifests) == 1:
            return index_info.manifests[0]

        available = ["{}/{}".format(m.os, m.architecture) for m in index_info.manifests]
        fail("""Target '{}' provides a multi-platform ImageIndexInfo with multiple platforms ({}); please specify 'platform' attribute in image_extract (e.g. platform = 'linux/amd64').""".format(
            ctx.attr.image.label,
            ", ".join(available),
        ))

    fail("Target '{}' does not provide ImageManifestInfo or ImageIndexInfo".format(ctx.attr.image.label))

def _image_extract_impl(ctx):
    src_manifest = _select_manifest(ctx)

    flattened_tar = ctx.actions.declare_file(ctx.attr.name + "_flattened.tar")

    # 1. Prepare file and directory extraction mappings
    file_map = dict(ctx.attr.files)
    if ctx.attr.file:
        out_name = ctx.attr.out if ctx.attr.out else ctx.attr.name
        file_map[ctx.attr.file] = out_name

    dir_map = dict(ctx.attr.directories)
    if ctx.attr.directory:
        out_name = ctx.attr.out if ctx.attr.out else ctx.attr.name
        dir_map[ctx.attr.directory] = out_name

    if not file_map and not dir_map:
        # Default to extracting full rootfs as a directory tree artifact
        dir_map["/"] = ctx.attr.name

    # Validate unique output names
    declared_names = {}
    declared_files = {}
    output_files = []
    for cpath, out_name in file_map.items():
        if out_name in declared_names:
            fail("Duplicate output name '{}' in image_extract target '{}'".format(out_name, ctx.attr.name))
        declared_names[out_name] = True
        f = ctx.actions.declare_file(out_name)
        declared_files[cpath] = f
        output_files.append(f)

    declared_dirs = {}
    output_dirs = []
    for cpath, out_name in dir_map.items():
        if out_name in declared_names:
            fail("Duplicate output name '{}' in image_extract target '{}'".format(out_name, ctx.attr.name))
        declared_names[out_name] = True
        d = ctx.actions.declare_directory(out_name)
        declared_dirs[cpath] = d
        output_dirs.append(d)

    # 2. Toolchains
    img_tool = ctx.toolchains["@rules_img//img:toolchain_type"].imgtoolchaininfo.tool_exe
    tar_toolchain = ctx.toolchains["@tar.bzl//tar/toolchain:type"]
    bsdtar_bin = tar_toolchain.tarinfo.binary

    # 3. Action: Flatten image and extract files and directories
    extract_args = ctx.actions.args()
    extract_args.use_param_file("@%s", use_always = True)
    extract_args.set_param_file_format("multiline")

    extract_args.add("--output_tar", flattened_tar)
    extract_args.add("--bsdtar", bsdtar_bin)
    extract_args.add("--img", img_tool)
    extract_args.add("--manifest", src_manifest.manifest)
    extract_args.add("--config", src_manifest.config)

    direct_inputs = [img_tool, bsdtar_bin, src_manifest.manifest, src_manifest.config]

    for i, layer in enumerate(src_manifest.layers):
        if layer.blob == None:
            fail("image_extract requires all layer blobs to be available, but layer[{}] in {} has no blob.".format(i, ctx.attr.image.label))
        extract_args.add("--layer", layer.blob)
        direct_inputs.append(layer.blob)

    for cpath, f in declared_files.items():
        extract_args.add("--file")
        extract_args.add(cpath)
        extract_args.add(f.path)

    for cpath, d in declared_dirs.items():
        extract_args.add("--dir")
        extract_args.add(cpath)
        extract_args.add(d.path)

    all_extract_outputs = [flattened_tar] + output_files + output_dirs
    extract_inputs = depset(
        direct = direct_inputs,
        transitive = [tar_toolchain.default.files],
    )

    ctx.actions.run(
        inputs = extract_inputs,
        outputs = all_extract_outputs,
        executable = ctx.executable._extractor,
        arguments = [extract_args],
        mnemonic = "ImageExtract",
        progress_message = "Flattening image and extracting files for %{label}",
        env = tar_toolchain.tarinfo.default_env,
    )

    # 4. Output groups and providers
    output_groups = {
        "directories": depset(output_dirs),
        "files": depset(output_files),
        "flattened_layer": depset([flattened_tar]),
    }
    for f in output_files:
        output_groups[f.basename] = depset([f])
    for d in output_dirs:
        output_groups[d.basename] = depset([d])

    all_outputs = output_files + output_dirs

    return [
        DefaultInfo(
            files = depset(all_outputs),
            runfiles = ctx.runfiles(files = all_outputs),
        ),
        OutputGroupInfo(**output_groups),
        ImageExtractInfo(
            files = declared_files,
            directories = declared_dirs,
            flattened_layer = flattened_tar,
        ),
    ]

image_extract_rule = rule(
    implementation = _image_extract_impl,
    doc = "Extracts files or directories from a rules_img container image after flattening it.",
    attrs = {
        "directories": attr.string_dict(
            doc = "Dictionary of container_directory: output_directory_name",
            default = {},
        ),
        "directory": attr.string(
            doc = "Single directory path inside the container to extract.",
            default = "",
        ),
        "file": attr.string(
            doc = "Single file path inside the container to extract.",
            default = "",
        ),
        "files": attr.string_dict(
            doc = "Dictionary of container_file: output_file_name",
            default = {},
        ),
        "flatten_format": attr.string(
            doc = "Compression format for the intermediate flattened layer ('none', 'gzip', 'zstd').",
            default = "none",
            values = ["none", "gzip", "zstd"],
        ),
        "image": attr.label(
            doc = "The rules_img image target (ImageManifestInfo or ImageIndexInfo).",
            mandatory = True,
            providers = [[ImageManifestInfo], [ImageIndexInfo]],
        ),
        "out": attr.string(
            doc = "Output file or directory name when 'file' or 'directory' is used.",
            default = "",
        ),
        "platform": attr.string(
            doc = "Platform specification (e.g. 'linux/amd64') to select when image is an ImageIndexInfo.",
            default = "",
        ),
        "_extractor": attr.label(
            default = Label("//containers/private:extract.sh"),
            executable = True,
            cfg = "exec",
            allow_single_file = True,
        ),
    },
    toolchains = [
        "@rules_img//img:toolchain_type",
        "@tar.bzl//tar/toolchain:type",
    ],
)
