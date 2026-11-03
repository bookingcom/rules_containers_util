"""Module extension fetching prebuilt dockerfile_parser distributions or building from source."""

load("//containers/private:platforms.bzl", "PLATFORMS")
load("//containers/private:repositories.bzl", "dockerfile_parser_dist_repository", "dockerfile_parser_toolchains_repository")
load("//containers/private:versions.bzl", "INTEGRITY", "RELEASE_URL_TEMPLATE", "VERSION")

_toolchains = tag_class(
    doc = "Declares dockerfile_parser toolchains.",
    attrs = {
        "name": attr.string(
            default = "dockerfile_parser",
            doc = "Base name of generated repositories.",
        ),
        "from_source": attr.bool(
            default = False,
            doc = "Whether to build dockerfile_parser from source (opt-in). Requires rules_go.",
        ),
    },
)

def _containers_extension_impl(mctx):
    local_dir = mctx.getenv("DOCKERFILE_PARSER_DIST_DIR")
    from_source = False
    name = "dockerfile_parser"

    for mod in mctx.modules:
        for tag in mod.tags.toolchains:
            if tag.name:
                name = tag.name

            # Only honor from_source if declared by root module
            if mod.is_root and tag.from_source:
                from_source = True

    if from_source:
        dockerfile_parser_toolchains_repository(
            name = name + "_toolchains",
            from_source = True,
            platforms = [],
            dist_repos = {},
        )
        return mctx.extension_metadata(reproducible = True)

    dist_repos = {}
    for platform in PLATFORMS:
        repo = "%s_%s" % (name, platform)
        if local_dir:
            urls = ["file://%s/dockerfile_parser-%s-%s.tar.gz" % (local_dir, VERSION, platform)]
            integrity = ""
        else:
            urls = [RELEASE_URL_TEMPLATE.format(
                version = VERSION,
                platform = platform,
            )]
            integrity = INTEGRITY.get(platform, "")
        dockerfile_parser_dist_repository(
            name = repo,
            urls = urls,
            integrity = integrity,
            version = VERSION,
        )
        dist_repos[platform] = repo

    dockerfile_parser_toolchains_repository(
        name = name + "_toolchains",
        dist_repos = dist_repos,
        platforms = PLATFORMS.keys(),
        from_source = False,
    )
    return mctx.extension_metadata(reproducible = not local_dir)

containers = module_extension(
    implementation = _containers_extension_impl,
    doc = "Configures dockerfile_parser toolchains.",
    tag_classes = {"toolchains": _toolchains},
    environ = ["DOCKERFILE_PARSER_DIST_DIR"],
)
