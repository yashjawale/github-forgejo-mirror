# GitHub → Forgejo mirror

Mirrors your personal and organization GitHub repositories as pull mirrors in a
Forgejo instance. Designed to run unattended from cron.

## Requirements

- `curl` and `jq`
- A GitHub personal access token with `repo` scope (needed for private repos)
- A Forgejo access token with permission to create repos and orgs

### GitHub token scopes

For a **classic** personal access token (GitHub → Settings → Developer settings →
Personal access tokens):

- `repo` — required to list and clone private repos (personal and org).
  Public-only mirroring works without it.
- `read:org` — recommended so org membership and repos are fully visible.
- If an org enforces **SAML SSO**, the token must be authorized for that org
  (click "Configure SSO" → "Authorize" next to the token, then authorize for
  each org).

For a **fine-grained** token (no expiry option / fine-grained PAT):

- Repository access: the orgs or repos you want to mirror.
- Permissions: `Metadata: Read` (mandatory) and `Contents: Read`.

## Setup

1. Copy `.env.example` to `.env` and fill in your values:

   ```sh
   cp .env.example .env
   ```

   Then edit `.env`:

   ```sh
   export GH_USER="yourgithubuser"
   export GH_TOKEN="ghp_xxxxxxxxxxxxxxxxx"
   export FORGEJO_URL="https://git.example.com"
   export FORGEJO_USER="yourforgejouser"
   export FORGEJO_TOKEN="xxxxxxxxxxxxx"
   ```

2. Run it:

   ```sh
   ./mirror.sh
   ```

## Configuration

| Variable          | Default     | Description                                          |
| ----------------- | ----------- | ---------------------------------------------------- |
| `GH_USER`         | —           | Your GitHub username. Required.                      |
| `GH_TOKEN`        | —           | GitHub personal access token. Required.              |
| `FORGEJO_URL`     | —           | Base URL of your Forgejo instance. Required.         |
| `FORGEJO_TOKEN`   | —           | Forgejo access token. Required.                      |
| `FORGEJO_USER`    | `GH_USER`   | Forgejo user repos are mirrored under.               |
| `MIRROR_PRIVATE`  | `false`     | Mirror private repos (as private in Forgejo).        |
| `MIRROR_INTERVAL` | `480m`      | Pull-mirror sync interval.                           |
| `ORG_VISIBILITY`  | `public`    | Visibility (`public`/`limited`/`private`) for orgs created in Forgejo. |
| `ORG_WHITELIST`   | *(all)*     | Comma-separated list of GitHub orgs to mirror; empty means all orgs.    |

## Behavior

- Personal repos are mirrored under `FORGEJO_USER`.
- Organization repos are mirrored under the same org in Forgejo; the org is
  created automatically if it doesn't exist. Set `ORG_WHITELIST` to limit which
  orgs are mirrored (e.g. `ORG_WHITELIST="acme,labs"`).
- Repos already present in Forgejo are skipped, so the script is safe to run
  repeatedly.
- If a mirrored repo's visibility changes on GitHub (public ↔ private), the
  Forgejo mirror is patched to match. Non-mirror repos sharing the same name
  are left untouched.
- Existing mirrors are not re-imported; update `MIRROR_INTERVAL` in Forgejo's
  repo settings if you want to change the sync frequency later.

## Cron

Add a line to your crontab, e.g. every 8 hours:

```sh
0 */8 * * * /path/to/forgejo/mirror.sh >> /var/log/forgejo-mirror.log 2>&1
```

Make sure `curl` and `jq` are on the `PATH` used by cron. The script logs
timestamped output, so check the log file to confirm it runs cleanly.

---

<a href="https://yashjawale.github.io/" target="_blank"><img style="height: 22px;" src="https://raw.githubusercontent.com/yashjawale/.github/main/docs/logo.svg" alt="Yash Jawale"/></a>