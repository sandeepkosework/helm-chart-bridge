# Releasing the chart

Every tenant is pinned to one **released chart version**. Argo CD installs that exact
Git tag for the tenant, so merging to `main` changes nothing for running tenants. A tenant
only gets a newer chart when it is deliberately moved to a newer tag.

## How the pieces fit

| Thing | Role |
|---|---|
| `main` | Working branch. **No tenant follows it.** Merge freely. |
| tag `vX.Y.Z` | An immutable release. Each tenant's Argo CD Application reads the chart from the tag named in that tenant's `chartVersion`. |
| `chartVersion` | A field in the tenant's `tenants/<slug>.yaml` (in `k8s-infra-setup`). Written by the tenant-operator. |
| `HELM_CHART_VERSION` | Operator setting: the version **new** tenants are created on. |
| `version:` in `Chart.yaml` | Kept equal to the tag so the two never disagree. Argo CD reads the tag, not this number. |

The first release is `v0.1.0`. It is the chart exactly as the existing tenants run it today.

## Cutting a release

1. Merge the change to `main` and update your clone: `git checkout main && git pull`.
2. From the repo root, with a clean working tree:

   ```bash
   scripts/release.sh 0.1.1
   ```

   This sets `version: 0.1.1` in `Chart.yaml`, commits it, and creates the tag `v0.1.1`
   on that commit. It does **not** push.
3. Push the commit and the tag to each server the cluster reads from (tags are not pushed
   together with branches unless you name them):

   ```bash
   git push <remote> main v0.1.1
   ```

   Argo CD reads the tenant chart from Gitea, so Gitea must have the tag. Pushing to the other
   remote as well keeps both copies the same.
4. Nothing changes for any existing tenant yet. To put **new** tenants on the release,
   set the operator's `HELM_CHART_VERSION` to `v0.1.1`.
5. To move an **existing** tenant, update it through the operator with
   `chartVersion: v0.1.1` (`PUT /api/v1/tenant/{id}`). That rewrites only that tenant's file,
   and Argo CD syncs only that tenant.

## Rules

- **Never move, delete or reuse a released tag.** A moved tag silently changes the chart for every
  tenant pinned to it. In Gitea, protect the pattern `v*`
  (repository Settings, Tags, Protected Tags) so only the people you allow can create tags and
  nobody can force-move them.
- A tag name is `v` plus `MAJOR.MINOR.PATCH`, equal to `Chart.yaml`'s `version:`.
- `release.sh` refuses to run off `main`, with uncommitted changes, or if the tag already exists.
- Keep the operator's rendered values compatible with the **oldest chart still in use**: extra keys
  are harmless, but renaming or removing a key the old chart reads would break an old tenant the
  next time its file is rewritten.
