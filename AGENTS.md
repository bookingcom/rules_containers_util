# Agent Guidelines

## Git & Branch Management Protocol

- **Never push directly to `main`**: Even if admin/owner rights or permissions allow bypassing branch protection rules, **never push directly to `main`**.
- **Always use Pull Requests**:
  1. Create a descriptive feature/chore/fix branch (e.g. `feat/...`, `fix/...`, `chore/...`).
  2. Commit changes to that branch.
  3. Push the branch to `origin`.
  4. Open a Pull Request against `main`.

## CI & BuildBuddy Protocol

- **All tests in CI must run with BuildBuddy enabled.** Any test execution in CI (including unit/smoke tests in root and e2e tests in `e2e/*`) must use `.github/actions/setup-bazel` with BuildBuddy endpoints and API keys so remote cache, remote execution (RBE), and BES invocation streaming are always active.
- **Do not delete or overwrite `.bazelrc.user`**: it is git-ignored and holds the user's remote execution credentials. Never print it either.
