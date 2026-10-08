# Meticulous agent traces for Devin

A [Devin plugin](https://docs.devin.ai/product-guides/plugins) that uploads
traces of your Devin sessions to Meticulous. It works in Devin cloud
sessions, the Devin CLI and Devin Desktop.

## What it captures

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
`wget`. On other platforms the hooks do nothing.

## Setup

You'll need an agent traces ingest token (`atit-…`) from Meticulous. It can
only upload traces for your organization.

### 1. Store the token as a Devin secret

Add an organization secret named `METICULOUS_AGENT_TRACES_TOKEN` in Devin
(Settings → Secrets).

### 2. Install the plugin

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
        "METICULOUS_AGENT_TRACES_TOKEN": "secret:org:METICULOUS_AGENT_TRACES_TOKEN"
      }
    }
  ]
}
```

**For the whole organization.** An org admin adds the plugin to the
organization's managed manifest as a required plugin:

```json
{
  "requiredPlugins": [
    {
      "source": "github",
      "repo": "alwaysmeticulous/agent-traces-plugin",
      "env": {
        "METICULOUS_AGENT_TRACES_TOKEN": "secret:org:METICULOUS_AGENT_TRACES_TOKEN"
      }
    }
  ]
}
```

Either way, the plugin tracks this repo's default branch, so each session
picks up the latest release when it starts.

### 3. Local sessions (Devin CLI and Desktop)

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

## Opting out

To stop recording and uploading your own sessions without uninstalling the
plugin, create `~/.meticulous/traces-config.json`:

```json
{ "enabled": false }
```

## Troubleshooting

- `~/.meticulous/agent-traces/devin/last-upload.log` has the output of the
  most recent upload attempt, including download errors.
- `~/.meticulous/agent-traces/agent-traces.log` (`~/Library/Logs/Meticulous/agent-traces.log`
  on macOS) is the uploader's log.
- `sh <plugin root>/bin/run-uploader.sh status` shows the token in use and
  upload state.
- If uploads from cloud sessions don't arrive, the session may be stopping
  background processes when a turn ends. Add
  `"METICULOUS_AGENT_TRACES_FOREGROUND_UPLOAD": "1"` to the plugin's `env`
  so each turn's upload finishes before the hook returns.

Devin runs plugin hooks on a best-effort basis: a hook that fails never
affects the session, and the next turn's upload includes anything a failed
upload missed.
