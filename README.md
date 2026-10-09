# Meticulous agent traces

Uploads traces of coding-agent sessions to Meticulous from cloud agents:

- **Devin** (cloud sessions, the Devin CLI and Devin Desktop), as a
  [Devin plugin](https://docs.devin.ai/product-guides/plugins). See
  [Devin](#devin).
- **Claude Code on the web**, **Cursor Cloud Agents** and **Conductor** cloud
  workspaces, through hooks committed to your repository. See
  [Other cloud agents](#other-cloud-agents).

On developers' Macs, the Meticulous agent traces uploader installed through
MDM uploads Claude Code, Cursor, OpenCode, Pi, Codex and Devin sessions
itself, so nothing here is needed there.

You'll need an agent traces ingest token (`atit-…`) from Meticulous. It can
only upload traces for your organization.

## Devin

### What it captures

The plugin registers [lifecycle hooks](https://docs.devin.ai/cli/extensibility/hooks/lifecycle-hooks)
and records, for each session:

- every prompt you send (`UserPromptSubmit`)
- every tool call Devin makes, with its input and output (`PostToolUse`)
- Devin's final message at the end of each turn (`Stop`)
- context compaction summaries (`PostCompaction`)
- the project directory, its git remote (with any credentials stripped),
  current branch and your git `user.email`, plus the machine's hostname,
  OS user and time zone

Devin's hooks don't expose the model, token usage, or Devin's messages and
reasoning within a turn, so traces don't include them.

Each hook writes its event to `~/.meticulous/agent-traces/devin/` and returns
immediately. At the end of each turn, the plugin uploads the session in the
background with the `meticulous-agent-traces` uploader. The plugin downloads
the uploader on first use from `snippet.meticulous.ai` and checks it against
the sha256 checksum recorded in `bin/release.txt`.

Supported on macOS and Linux (x64 and arm64), which need `sh` and `curl` or
`wget`. On other platforms the hooks do nothing. The same applies to the
hooks in [Other cloud agents](#other-cloud-agents).

### Setup

#### 1. Store the token as a Devin secret

Add an organization secret named `METICULOUS_AGENT_TRACES_TOKEN` in Devin
(Settings → Secrets).

#### 2. Install the plugin

**Individually (for a test group).** In Devin, open Customize → Plugins →
Add plugin → From repository, and enter `alwaysmeticulous/agent-traces-plugin`
at the Personal scope. Or, from the Devin CLI:

```sh
devin plugins install alwaysmeticulous/agent-traces-plugin
```

Then pass the token to the plugin's hooks in cloud sessions. In Customize →
Plugins → Plugin settings → Edit manifest, add an `env` block to the plugin's
entry:

```json
{
  "optionalPlugins": [
    {
      "source": "github",
      "repo": "alwaysmeticulous/agent-traces-plugin",
      "env": {
        "METICULOUS_AGENT_TRACES_TOKEN": "secret:org:METICULOUS_AGENT_TRACES_TOKEN",
        "METICULOUS_AGENT_TRACES_ENVIRONMENT": "devin-cloud"
      }
    }
  ]
}
```

(`METICULOUS_AGENT_TRACES_ENVIRONMENT` marks these traces as coming from
Devin's cloud, which Devin doesn't otherwise reveal.)

**For the whole organization.** An org admin adds the plugin to the
organization's managed manifest as a required plugin:

```json
{
  "requiredPlugins": [
    {
      "source": "github",
      "repo": "alwaysmeticulous/agent-traces-plugin",
      "env": {
        "METICULOUS_AGENT_TRACES_TOKEN": "secret:org:METICULOUS_AGENT_TRACES_TOKEN",
        "METICULOUS_AGENT_TRACES_ENVIRONMENT": "devin-cloud"
      }
    }
  ]
}
```

Either way, the plugin tracks this repo's default branch, so each session
picks up the latest release when it starts.

#### 3. Local sessions (Devin CLI and Desktop)

The manifest's `env` block only applies to cloud sessions. On each machine
that runs Devin locally, save the token in the uploader's config file:

```sh
mkdir -p ~/.meticulous/agent-traces
printf '{"token": "%s"}\n' "atit-…" > ~/.meticulous/agent-traces/config.json
chmod 600 ~/.meticulous/agent-traces/config.json
```

Exporting `METICULOUS_AGENT_TRACES_TOKEN` in the environment Devin runs in
works too. Macs that already have the Meticulous agent traces uploader
installed through MDM need nothing more.

## Other cloud agents

Claude Code on the web, Cursor Cloud Agents and Conductor don't install
plugins, but they do run hooks committed to the repository they work in.

### 1. Add the hooks to your repository

From the repository's root, on macOS or Linux:

```sh
curl -fsSL https://snippet.meticulous.ai/agent-traces/v1/latest/run-uploader.sh | sh -s -- install-repo-hooks
```

This adds `.meticulous/agent-traces/bin/` (the same two scripts as this
repo's `bin/`) and registers them, alongside any hooks you already have, in:

- `.claude/settings.json`: uploads at the end of each Claude Code turn, and
  downloads the uploader in the background when a session starts.
- `.cursor/hooks.json`: records each Cursor turn's prompts, responses, tool
  calls and their outputs, and uploads at the end of the turn.
- `.conductor/settings.toml`: an archive script that uploads every agent's
  sessions when a Conductor workspace is archived. If you already have an
  archive script, the command prints the line to add to it.

Pass `--only claude-code,cursor,conductor` (any subset) to limit it. Commit
the result.

You never need to update them: on each machine, the scripts download the
latest uploader release when they first need it (checking it against its
published sha256 checksums), together with that release's copy of the hook
scripts, which the committed ones then hand over to. Re-run the command only
to pick up hooks for newly supported events.

The hooks also run on developers' own machines, but there they only upload
when `METICULOUS_AGENT_TRACES_TOKEN` is set in the environment, leaving
uploads to the uploader installed through MDM.

### 2. Give the cloud agent the token

Set `METICULOUS_AGENT_TRACES_TOKEN` to your ingest token as a secret:

- **Claude Code on the web**: as an environment variable of the cloud
  environment, or org-wide in server-managed settings (`env`) on Team and
  Enterprise plans. Also set the environment's network access to **Custom**
  and allow `snippet.meticulous.ai`, `app.meticulous.ai` and
  `*.amazonaws.com` (traces go straight to S3), since the default Trusted
  access blocks them.
- **Cursor Cloud Agents**: in the Cursor dashboard's secrets. Cursor runs the
  repository's hooks in cloud agents; the token reaches them as an
  environment variable.
- **Conductor**: as a cloud environment variable in your Conductor
  organization's settings, rather than committed `[environment_variables]`.

If uploads from a cloud agent don't arrive, it may be stopping background
processes when a turn ends. Set `METICULOUS_AGENT_TRACES_FOREGROUND_UPLOAD=1`
there too, so each turn's upload finishes before the hook returns.

## Opting out

To stop recording and uploading your own sessions without uninstalling the
plugin, create `~/.meticulous/traces-config.json`:

```json
{ "enabled": false }
```

To upload only sessions in some repositories, set `allowedRepoRegex` to a
regular expression matched against each session's git repository, written
as `host/owner/repo` (for example `github.com/acme/shop`):

```json
{ "allowedRepoRegex": "^github\\.com/acme/" }
```

Sessions outside a git repository, or in one the regex doesn't match, are
skipped and not reconsidered unless they change. After changing the regex,
run `sh <plugin root>/bin/run-uploader.sh upload --force` to reconsider
them (this also re-sends sessions already uploaded). An invalid regex stops
all uploads.

## Troubleshooting

- `~/.meticulous/agent-traces/<agent>/last-upload.log` (`devin`,
  `claude-code`, `cursor` or `conductor`) has the output of the most recent
  upload attempt, including download errors.
- `~/.meticulous/agent-traces/agent-traces.log` (`~/Library/Logs/Meticulous/agent-traces.log`
  on macOS) is the uploader's log.
- `sh <plugin root>/bin/run-uploader.sh status` shows the token in use and
  upload state.
- If uploads from Devin cloud sessions don't arrive, the session may be
  stopping background processes when a turn ends. Add
  `"METICULOUS_AGENT_TRACES_FOREGROUND_UPLOAD": "1"` to the plugin's `env`
  so each turn's upload finishes before the hook returns.

Agents run hooks on a best-effort basis: a hook that fails never affects the
session, and the next turn's upload includes anything a failed upload
missed. Anything in a session that looks like a credential (API keys,
tokens, passwords in URLs, private keys) is redacted before it's uploaded.
