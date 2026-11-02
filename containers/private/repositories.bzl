"""Repository rules fetching prebuilt dockerfile_parser distributions."""

load(":platforms.bzl", "PLATFORMS")

_DIST_BUILD = """\
load("@rules_containers_util//containers:toolchain.bzl", "dockerfile_parser_toolchain")

package(default_visibility = ["//visibility:public"])

exports_files(["bin/dockerfile_parser"])

filegroup(
    name = "files",
    srcs = glob(["**"], exclude = ["BUILD.bazel", "REPO.bazel"]),
)

dockerfile_parser_toolchain(
    name = "dockerfile_parser_toolchain",
    dockerfile_parser = "bin/dockerfile_parser",
    files = [":files"],
    version = "{version}",
)
"""

def _dockerfile_parser_dist_repository_impl(rctx):
    rctx.download_and_extract(
        url = rctx.attr.urls,
        integrity = rctx.attr.integrity,
        stripPrefix = "dockerfile_parser",
    )
    rctx.file("BUILD.bazel", _DIST_BUILD.format(version = rctx.attr.version))

dockerfile_parser_dist_repository = repository_rule(
    implementation = _dockerfile_parser_dist_repository_impl,
    doc = "Downloads one prebuilt dockerfile_parser distribution archive.",
    attrs = {
        "integrity": attr.string(doc = "SRI hash of the archive; empty only for local testing."),
        "urls": attr.string_list(mandatory = True),
        "version": attr.string(mandatory = True),
    },
)

def _dockerfile_parser_toolchains_repository_impl(rctx):
    content = []
    if rctx.attr.from_source:
        content.append("""\
toolchain(
    name = "source_toolchain",
    toolchain = "@rules_containers_util//cmd/dockerfile_parser:dockerfile_parser_toolchain",
    toolchain_type = "@rules_containers_util//containers:dockerfile_parser_toolchain_type",
)
""")
    else:
        for platform in rctx.attr.platforms:
            content.append("""\
toolchain(
    name = "{platform}_toolchain",
    exec_compatible_with = {constraints},
    toolchain = "@{repo}//:dockerfile_parser_toolchain",
    toolchain_type = "@rules_containers_util//containers:dockerfile_parser_toolchain_type",
)
""".format(
                platform = platform,
                constraints = repr(PLATFORMS[platform]),
                repo = rctx.attr.dist_repos[platform],
            ))
    rctx.file("BUILD.bazel", "\n".join(content))

dockerfile_parser_toolchains_repository = repository_rule(
    implementation = _dockerfile_parser_toolchains_repository_impl,
    doc = "Declares toolchains for dockerfile_parser.",
    attrs = {
        "dist_repos": attr.string_dict(doc = "platform -> name of its dist_repository"),
        "platforms": attr.string_list(),
        "from_source": attr.bool(default = False),
    },
)
