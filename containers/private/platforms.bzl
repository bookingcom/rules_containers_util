"""Platforms prebuilt dockerfile_parser archives are published for."""

PLATFORMS = {
    "linux_amd64": [
        "@platforms//os:linux",
        "@platforms//cpu:x86_64",
        "@platforms_contrib//os/linux/libc/glibc:available",
    ],
    "linux_arm64": [
        "@platforms//os:linux",
        "@platforms//cpu:aarch64",
        "@platforms_contrib//os/linux/libc/glibc:available",
    ],
    "osx_amd64": [
        "@platforms//os:macos",
        "@platforms//cpu:x86_64",
    ],
    "osx_arm64": [
        "@platforms//os:macos",
        "@platforms//cpu:aarch64",
    ],
}
