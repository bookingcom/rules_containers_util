"""Module extension fetching prebuilt dockerfile_parser distributions or building from source."""

load("//containers/private:platforms.bzl", "PLATFORMS")
load("//containers/private:repositories.bzl", "dockerfile_parser_dist_repository", "dockerfile_parser_toolchains_repository")
load("//containers/private:versions.bzl", "DEFAULT_VERSION", "RELEASE_URL_TEMPLATE", "VERSIONS")

_toolchains = tag_class(
    doc = "Declares dockerfile_parser toolchains.",
    attrs = {
        "name": attr.string(
            default = "dockerfile_parser",
            doc = "Base name of generated repositories.",
        ),
        "version": attr.string(
            default = DEFAULT_VERSION,
            doc = "dockerfile_parser version.",
        ),
        "from_source": attr.bool(
            default = False,
            doc = "Whether to build dockerfile_parser from source (opt-in). Requires rules_go.",
        ),
    },
)

def _containers_extension_impl(mctx):
    local_dir = mctx.getenv("DOCKERFILE_PARSER_DIST_DIR")
    seen = {}
    for mod in mctx.modules:
        for tag in mod.tags.toolchains:
            if tag.name in seen:
                continue
            seen[tag.name] = tag.version
            if tag.from_source:
                dockerfile_parser_toolchains_repository(
                    name = tag.name + "_toolchains",
                    from_source = True,
                    platforms = [],
                    dist_repos = {},
                )
                continue

            release = VERSIONS.get(tag.version, {})
            dist_repos = {}
            for platform in PLATFORMS:
                repo = "%s_%s" % (tag.name, platform)
                if local_dir:
                    urls = ["file://%s/dockerfile_parser-%s-%s.tar.gz" % (local_dir, tag.version, platform)]
                    integrity = ""
                else:
                    tag_name = release.get("tag", "v" + tag.version)
                    urls = [RELEASE_URL_TEMPLATE.format(
                        tag = tag_name,
                        version = tag.version,
                        platform = platform,
                    )]
                    integrity = release.get("integrity", {}).get(platform, "")
                dockerfile_parser_dist_repository(
                    name = repo,
                    urls = urls,
                    integrity = integrity,
                    version = tag.version,
                )
                dist_repos[platform] = repo
            dockerfile_parser_toolchains_repository(
                name = tag.name + "_toolchains",
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
