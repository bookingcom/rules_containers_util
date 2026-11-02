"""Dockerfile parser toolchain definitions."""

DockerfileParserInfo = provider(
    doc = "Dockerfile parser distribution.",
    fields = {
        "dockerfile_parser": "File: the dockerfile_parser executable to run in actions.",
        "files": "depset of File: all files of the distribution.",
        "version": "string: version.",
    },
)

def _dockerfile_parser_toolchain_impl(ctx):
    all_files = ctx.files.files + [ctx.file.dockerfile_parser]
    files = depset(all_files)
    info = DockerfileParserInfo(
        dockerfile_parser = ctx.file.dockerfile_parser,
        files = files,
        version = ctx.attr.version,
    )
    return [
        platform_common.ToolchainInfo(dockerfile_parser_info = info),
        DefaultInfo(files = files),
    ]

dockerfile_parser_toolchain = rule(
    implementation = _dockerfile_parser_toolchain_impl,
    doc = "Defines a dockerfile_parser toolchain.",
    attrs = {
        "dockerfile_parser": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The dockerfile_parser executable.",
        ),
        "files": attr.label_list(
            allow_files = True,
            doc = "All files of the distribution.",
        ),
        "version": attr.string(
            default = "",
            doc = "Version of the tool.",
        ),
    },
)

def _current_dockerfile_parser_toolchain_impl(ctx):
    info = ctx.toolchains[Label("//containers:dockerfile_parser_toolchain_type")].dockerfile_parser_info
    exe = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(
        output = exe,
        target_file = info.dockerfile_parser,
        is_executable = True,
    )
    make_vars = {"DOCKERFILE_PARSER": exe.path}
    return [
        info,
        DefaultInfo(
            executable = exe,
            files = depset([exe]),
            runfiles = ctx.runfiles(transitive_files = info.files).merge(ctx.runfiles([exe])),
        ),
        platform_common.TemplateVariableInfo(make_vars),
    ]

current_dockerfile_parser_toolchain = rule(
    implementation = _current_dockerfile_parser_toolchain_impl,
    doc = "Exposes the resolved dockerfile_parser binary.",
    executable = True,
    toolchains = ["//containers:dockerfile_parser_toolchain_type"],
)
