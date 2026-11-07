# End-to-End Dockerfile Parsing, Image Extraction, and RPM Lock Resolution

This document describes the end-to-end integration between **`rules_containers_util`**, **`dnf5-prebuilt`**, and **`rules_img`** for parsing container Dockerfiles, extracting runtime environments from base container images, and resolving hermetic package lockfiles.

---

## 1. Overview & Objectives

In containerized build workflows, Dockerfiles often install packages via commands like:
```dockerfile
FROM oraclelinux:10-slim
RUN dnf install -y curl git
```

To reproduce this hermetically in Bazel without running Docker daemons or executing non-hermetic scripts in sandboxes, the workflow is split into four distinct steps:
1. **Dockerfile Parsing**: Parse the Dockerfile into a structured Abstract Syntax Tree (AST) using `dockerfile_parser`.
2. **Command Analysis**: Extract the base image reference and identify target packages (`curl`, `git`) from the AST arguments.
3. **Container Environment Extraction**: Extract the RPM package database (`rpmdb.sqlite`) and repository configurations (`.repo` files) from the base container image using `image_extract`.
4. **Hermetic Dependency Resolution**: Solve the dependency graph using hermetic `dnf5` and generate a reproducible lockfile containing SRI hashes and package URLs.

---

## 2. Architecture & Submodule Isolation

To prevent circular dependencies between `rules_containers_util` and `dnf5-prebuilt` (which itself consumes `rules_containers_util`), the e2e flow is hosted in an isolated submodule workspace at `e2e/dnf-hermetic-lock/`.

The root module ignores `e2e/**` in [`REPO.bazel`](file:///home/manuel/workspace/github/rules_containers_util/.worktrees/master/REPO.bazel) and [`.bazelignore`](file:///home/manuel/workspace/github/rules_containers_util/.worktrees/master/.bazelignore). In turn, `e2e/dnf-hermetic-lock` declares its own [`MODULE.bazel`](file:///home/manuel/workspace/github/rules_containers_util/.worktrees/master/e2e/dnf-hermetic-lock/MODULE.bazel) linking back to the root repository via `local_path_override`:

```starlark
bazel_dep(name = "rules_containers_util", version = "0.0.1")
local_path_override(
    module_name = "rules_containers_util",
    path = "../..",
)

bazel_dep(name = "dnf5-prebuilt", version = "5.4.6.0.bcr.4")
```

| Component | Repository / Module | Purpose |
| :--- | :--- | :--- |
| **`dockerfile_parser`** | `rules_containers_util` (`//containers:dockerfile_parser`) | Go binary utilizing BuildKit's frontend parser to produce JSON AST representing instructions, flags, arguments, and shell continuation commands. |
| **`image_extract`** | `rules_containers_util` (`//containers:defs.bzl`) | Starlark macro/rule that flattens `rules_img` container images and extracts specified files or directory trees via `bsdtar`. |
| **`dnf5-prebuilt`** | `bookingcom/dnf5-prebuilt` | Hermetically built `dnf5` binaries and Starlark rules (`dnf_config`, `rpm_lock`, `rpm_mark`, `rpm_layer`). |
| **`rules_img`** | `bazel-contrib/rules_img` | OCI container pulling and image manipulation. |

---

## 3. Step-by-Step Pipeline

### Step 3.1: Defining the Dockerfile

Test fixture located at [`e2e/dnf-hermetic-lock/Dockerfile.ol10`](file:///home/manuel/workspace/github/rules_containers_util/.worktrees/master/e2e/dnf-hermetic-lock/Dockerfile.ol10):
```dockerfile
FROM oraclelinux:10-slim
RUN dnf install -y curl git
```

### Step 3.2: Parsing Dockerfile with `dockerfile_parser`

The `dockerfile_parser` tool parses the input Dockerfile and writes `dockerfile_ast.json`. Each instruction produces a JSON layer record:
```json
[
  {
    "index": 0,
    "stage": 0,
    "command": "FROM",
    "args": ["oraclelinux:10-slim"],
    "value": "oraclelinux:10-slim",
    "start_line": 1,
    "end_line": 1
  },
  {
    "index": 1,
    "stage": 0,
    "command": "RUN",
    "args": ["dnf", "install", "-y", "curl", "git"],
    "value": "dnf install -y curl git",
    "start_line": 2,
    "end_line": 2,
    "shell_ast": {
      "type": "Script",
      "children": [...]
    }
  }
]
```

The test inspects the `RUN` command tokens, discards flags (e.g. `-y`), and extracts `['curl', 'git']`.

### Step 3.3: Extracting RPM Environment from the Base Image

For Oracle Linux 10, the files of interest inside the image are:
- **RPM Database**: `/usr/lib/sysimage/rpm/rpmdb.sqlite` (Note: Oracle Linux 9 uses `/var/lib/rpm/rpmdb.sqlite`).
- **YUM/DNF Repository Configuration**: `/etc/yum.repos.d/oracle-linux-ol10.repo`.

Extraction targets in [`e2e/dnf-hermetic-lock/BUILD.bazel`](file:///home/manuel/workspace/github/rules_containers_util/.worktrees/master/e2e/dnf-hermetic-lock/BUILD.bazel):
```starlark
image_extract(
    name = "ol10_rpmdb",
    file = "/usr/lib/sysimage/rpm/rpmdb.sqlite",
    image = "@oraclelinux_10_slim//:image",
    out = "ol10_rpmdb.sqlite",
    platform = "linux/amd64",
)

image_extract(
    name = "ol10_repo",
    file = "/etc/yum.repos.d/oracle-linux-ol10.repo",
    image = "@oraclelinux_10_slim//:image",
    out = "oracle-linux-ol10.repo",
    platform = "linux/amd64",
)
```

### Step 3.4: Configuring DNF and Generating the Lockfile

The extracted `.repo` file contains variable placeholders (`$ociregion`, `$ocidomain`). We configure them via `dnf_config`, then invoke `rpm_lock`:

```starlark
dnf_config(
    name = "ol10_dnf_config",
    install_weak_deps = False,
    releasever = "10",
    repo_configs = [":ol10_repo"],
    vars = {
        "ocidomain": "oracle.com",
        "ociregion": "",
    },
)

rpm_lock(
    name = "ol10_curl_git_lock",
    base_rpmdb = ":ol10_rpmdb",
    config = ":ol10_dnf_config",
    packages = [
        "curl",
        "git",
    ],
)
```

The `rpm_lock` action:
1. Copies the extracted `ol10_rpmdb.sqlite` into the solver's temporary installroot.
2. Invokes hermetic `dnf5 lock` against Oracle Linux 10 repository endpoints.
3. Computes topological `install_order`, SRI integrity hashes (`sha256-...`), and package metadata records.
4. Produces `ol10_curl_git_lock.lock.json`.

---

## 4. End-to-End Test Execution

The test is implemented in [`e2e/dnf-hermetic-lock/e2e_ol10_test.py`](file:///home/manuel/workspace/github/rules_containers_util/.worktrees/master/e2e/dnf-hermetic-lock/e2e_ol10_test.py) and registered as a `py_test` (`//:e2e_ol10_test`):

```bash
cd e2e/dnf-hermetic-lock
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel test --invocation_id=${INVOCATION_ID} //... --test_output=all
```

The test validates:
- [x] `dockerfile_parser` correctly parses `Dockerfile.ol10` into AST JSON.
- [x] Package targets `['curl', 'git']` are identified from the AST arguments.
- [x] Extracted `rpmdb.sqlite` is a valid SQLite 3 database with preinstalled base packages.
- [x] Extracted `oracle-linux-ol10.repo` contains required repo sections (`ol10_baseos_latest`, `ol10_appstream`).
- [x] Resolved lockfile contains `curl`, `git`, and all 89 transitive dependencies in topological `install_order` with valid URLs and SRI integrity hashes.

---

## 5. Capturing JSON Artifacts in CI

All JSON files are automatically captured:
- **During test runs**: `tests/e2e_ol10_test.py` saves `dockerfile_ast.json`, `ol10_curl_git_lock.lock.json`, and `e2e_summary.json` to both `TEST_UNDECLARED_OUTPUTS_DIR` and `artifacts/`.
- **In GitHub Actions CI**: [`.github/workflows/ci.yaml`](file:///home/manuel/workspace/github/rules_containers_util/.worktrees/master/.github/workflows/ci.yaml) uploads all `*.lock.json`, `*ast.json`, and `artifacts/**/*.json` via `actions/upload-artifact@v4` under artifact name `e2e-json-artifacts`.

---

## 6. Guidance for Future Extensions

1. **Supporting Multiple Distribution Types**:
   - For Debian/Ubuntu images, an equivalent `apt` solver can be hooked using repository metadata extracted from `/var/lib/dpkg/status` and `/etc/apt/sources.list`.
   - For Alpine images, `apk` world can be extracted from `/lib/apk/db/installed`.
2. **Multi-Stage Dockerfiles**:
   - Check `layer["stage"]` in the parsed AST. Multi-stage builds can lock different sets of packages for builder vs runtime stages.
3. **Automated Image Layer Construction**:
   - The generated `*.lock.json` can be consumed by `dnf5-prebuilt`'s `rpm_layer` rule and fed directly into `image_manifest` from `rules_img` to produce the final container image completely hermetically.
