# Contributing

Thanks for helping. A few ground rules keep this small project tidy.

## Workflow

- `main` is protected. Work on a branch and open a **pull request**; direct pushes and force pushes to `main` are blocked.
- The `check` workflow must pass. Run it locally first:

  ```bash
  scripts/check.sh
  ```
- Pull requests are squash-merged, so keep the PR title a good commit message.

## Trying your changes

Clone the repo straight into the plugin folder. Omarchy reloads plugin code when you save a file.

```bash
git clone https://github.com/<you>/omarchy-conduit.git ~/.config/omarchy/plugins/conduit.vpn
omarchy plugin enable conduit.vpn
omarchy plugin validate ~/.config/omarchy/plugins/conduit.vpn
```

If a change does not show up, run `omarchy-shell shell rescanPlugins`, or `omarchy restart shell`.

## Please never commit

VPN profiles (`.ovpn`, `.conf`), certificates, keys, logs from your VPN, or hostnames and addresses of a private network. `scripts/check.sh` rejects the obvious cases, but you are the last line of defence. Redact before you paste anything into an issue.

## Style

- Keep the popup plain and quiet: short labels, one line of help at most, destructive actions kept apart from the main ones.
- Address VPNs by UUID, never by name.
- Anything that touches credentials passes them through the environment or a `0600` temp file, never a command line you control.

## Translations

Every user-visible string lives in `i18n/<language>.json` and follows Omarchy's Setup > Language. `en.json` is the reference.

1. Copy `i18n/en.json` to `i18n/<code>.json`. The code is an Omarchy language code such as `de`, `pt-BR` or `id` (see `$OMARCHY_PATH/default/i18n/locales.json`).
2. Translate the values. Keep the keys, and keep `%1`, `%2` placeholders: they are filled in at runtime and may move in the sentence.
3. Run `scripts/check.sh`. It fails on invalid JSON, keys that do not exist in `en.json`, and strings used in code but missing from `en.json`.

A string missing from your file falls back to English, so a partial translation is fine.
