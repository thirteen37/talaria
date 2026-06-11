# Profile distributions & the `distribution.yaml` schema

A Hermes **profile distribution** packages a whole agent — `SOUL.md`, `config.yaml`,
`mcp.json`, `skills/`, `cron/`, plus a `distribution.yaml` manifest — as a git repository so it
can be shared, installed, and updated in place. Talaria manages distributions from the **Profiles**
screen (`Talaria/Manage/ProfilesView.swift`).

Hermes is the source of truth for the manifest format and the `hermes profile` commands — when this
doc and Hermes disagree, Hermes wins and this doc is out of date. The schema below is verified
against the Hermes docs (Hermes `0.15.1`):

- Manifest + lifecycle: <https://hermes-agent.nousresearch.com/docs/user-guide/profile-distributions>
- Profile commands: <https://hermes-agent.nousresearch.com/docs/reference/profile-commands>

## `distribution.yaml` schema

Only `name` is required; **every other field has a sensible default**, so the smallest valid
manifest is a single `name:` line.

| Key | Type | Required | Meaning |
| --- | --- | :---: | --- |
| `name` | string | **yes** | The distribution's identifier. |
| `version` | string | no | Semantic version, e.g. `1.0.0`. |
| `description` | string | no | Human-readable summary of the agent. |
| `author` | string | no | Distribution creator. |
| `license` | string | no | License, e.g. `MIT`. |
| `hermes_requires` | string | no | Minimum Hermes version constraint, e.g. `>=0.15.0`. |
| `env_requires` | list | no | Environment variables the agent needs (see below). |
| `distribution_owned` | list of paths | no | Files the distribution **owns** — overwritten on `profile update` rather than preserved as user data. When omitted, Hermes applies sensible defaults (e.g. `SOUL.md`, `skills/`, `cron/`, `mcp.json`). |

`source` is **not** a manifest key. The git URL a distribution was installed from is recorded by the
*installer* as separate profile metadata, not authored in `distribution.yaml`. (`hermes profile info`
may still surface it for display; Talaria shows it read-only in the manifest view but never writes it.)

### `env_requires` entries

| Key | Type | Required | Meaning |
| --- | --- | :---: | --- |
| `name` | string | **yes** | The environment variable name, e.g. `OPENAI_API_KEY`. |
| `description` | string | no | What the variable is for. Shown to the installer. |
| `required` | bool | no (default `true`) | Whether the installer must supply it. |
| `default` | string | no | Fallback value used when an **optional** var isn't provided. Only meaningful when `required: false`. |

### Example

```yaml
name: telemetry-bot
version: 1.2.0
description: A research agent with web search and a nightly digest
author: Jane Doe
license: MIT
hermes_requires: ">=0.15.0"
env_requires:
  - name: OPENAI_API_KEY
    description: "OpenAI API key (for model access)"
    required: true
  - name: SERPAPI_KEY
    description: "SerpAPI key for web search"
    required: false
    default: ""
distribution_owned:
  - SOUL.md
  - skills/research/
  - cron/digest.json
```

## What's **not** in a distribution (ever)

Hermes hard-excludes the user's private data from a distribution even if an author accidentally ships
it — there is no override. Per the Hermes docs
([§ What's NOT in a distribution](https://hermes-agent.nousresearch.com/docs/user-guide/profile-distributions#whats-not-in-a-distribution-ever)):

```
auth.json            # OAuth tokens, platform credentials
.env                 # API keys, secrets
memories/            # conversation memory
sessions/            # conversation history
state.db, state.db-shm, state.db-wal   # session metadata
logs/                # agent and error logs
workspace/           # generated working files
plans/               # scratch plans
home/                # user's home mount in Docker backends
*_cache/             # image / audio / document caches
local/               # user-reserved customization namespace
```

When Talaria **publishes**, it writes these into the profile's `.gitignore` (idempotently, without
clobbering existing entries) *and* stages only an allowlist — never `git add -A` — so secrets and
private data can't reach the remote even on a fresh repo with no prior `.gitignore` (e.g. the default
`~/.hermes`). See `DistributionPublisher` in `HermesKit/Sources/HermesKit/Hermes/HermesDistribution.swift`.

## How Talaria surfaces this

All of these are **CLI-driven** — Hermes exposes no dashboard HTTP route for them, so they run through
the admin runner like the Skills Hub mutations, gated behind the `profileDistributions` capability
(`HermesKit/.../Hermes/Capabilities.swift`, floor `0.15.1`). The Profiles toolbar **Distribution** menu:

| Action | CLI | Notes |
| --- | --- | --- |
| **Install…** | `hermes profile install <git-url\|dir> [--name] [--alias] [--force] -y` | Clones a distribution into a new profile; the source is recorded so it can be updated. |
| **Update** / **Update (overwrite config)** | `hermes profile update <name> [--force-config] -y` | Re-pulls the recorded source; overwrites distribution-owned files, preserves user data. `--force-config` also overwrites `config.yaml`. |
| Manifest view (on selecting a profile) | `hermes profile info <name>` | Read-only; a non-distribution profile shows an "Author one" button. |
| **Export…** | `hermes profile export <name> -o <path>` | Writes a `.tar.gz` on the host; Talaria fetches it back for the save panel. |
| **Import…** | `hermes profile import <archive> [--name]` | Unpacks a `.tar.gz` snapshot — *not* git-tracked or updatable (contrast with Install). |
| **Edit `distribution.yaml` & Publish…** | direct file write + `git` on the host | `distribution.yaml` is authored by a direct write through `HermesFileStore` (the Memory-editor exception); Publish runs `git init/add/commit/tag/push` via the `HostShellRunning` seam, saving the in-form manifest first. |

**Install vs Import.** *Install* subscribes to a git distribution and stays updatable via `profile
update`; *Import* restores a one-shot `.tar.gz` snapshot (paired with Export) with no git link and no
update path.

Export/Import and Publish run on whichever host the profile lives on — local `/bin/sh` on macOS, or
the remote host over system-`ssh` / NIO-SSH — using the same transport selection as the rest of the
window. Code: `HermesProfiles` (`install`/`update`/`info`/`export`/`importArchive`/`profileDirectory`)
and `HermesDistribution` (`DistributionManifest`, `HostShellRunning`, `DistributionPublisher`).
