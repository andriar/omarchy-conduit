# Conduit design language

Conduit is a small family of Omarchy bar widgets (VPN today, SSH tunnels next). This page is what makes them look and behave like one thing. Follow it in every Conduit plugin.

## Principles

1. **Quiet.** Short labels. At most one line of help under a control, never a paragraph.
2. **Theme-native.** Colors, fonts and radii come from Omarchy only. Never write a hex color.
3. **One main action per view.** It is the only filled button.
4. **Destructive actions live apart** from everyday ones, behind a divider and a two-step confirm.
5. **Say what went wrong and what to do**, not just "failed".

## Theme: tokens only

| Need | Use |
|---|---|
| Text | `bar.foreground` (fallback `Commons.Color.foreground`) |
| Dim text | `Qt.darker(foreground, 1.55)` |
| Accent (active, primary) | `Commons.Color.accent` |
| Errors, danger | `bar.urgent` (fallback `Commons.Color.urgent`) |
| Corners, spacing, type sizes | `Style.cornerRadius`, `Style.space(n)`, `Style.font.*` |

Because nothing is hard-coded, every Conduit plugin follows whatever Omarchy theme is active.

## Shared components (UI kit)

The kit is the `Conduit*.qml` files next to `Panel.qml`. The source of truth is [`omarchy-conduit-vpn`](https://github.com/andriar/omarchy-conduit-vpn); other plugins carry a verified copy (see "Sharing the kit").

| Component | Use it for |
|---|---|
| `ConduitSwitch` | On/off. ON fills the track with the accent, so state is readable at a glance. `checked`, `busy`, `toggled()`. |
| `ConduitButton` | Actions. `primary` = filled accent (one per view), default = outlined, `danger` = outlined in the urgent color. |
| `ConduitToggleRow` | A setting: title, one dim line of explanation, a switch. |

## Patterns

**Popup views.** A popup has a *list* view and drill-down views (*settings*, *add*, and any one-off prompt). Drill-down views start with a back arrow and the item's name. Esc goes back.

**List row** (52 px): name on the first line (bold when active), a dim subtitle on the second, controls on the right. Order of controls: extras (key, ...), gear, switch.

- Subtitle for an active item: `Connected · <address> · <time online>`. Otherwise `<kind> · <state>`.
- An active row has a 3 px accent bar on its left edge and a faint accent tint.
- Items that share a name are told apart by the start of their id.

**Settings view.** Fields first, then switches, then the buttons: the primary (`Save & Connect`) and one secondary (`Save`). Below a thin divider: "Delete this …" with a `danger` button that asks "Sure? Click again".

**Status and errors.** One line at the top of the list, in the urgent color for errors. Notifications repeat important failures.

**Empty state.** One sentence that points at the `+` button.

**Bar icon.** One glyph. Full accent when something is active, 70 % opacity when idle, 50 % while busy. Tooltip starts with `Conduit · `.

| Plugin | Glyph |
|---|---|
| VPN | `` (shield) |
| Tunnel | `` (arrows) |
| Shared actions | add ``, back ``, settings ``, key `` |

## Copy

- Sentence case. No trailing period on labels and buttons.
- Ellipsis (`...`) only for actions that open another step or are in progress.
- Every string is in `i18n/<language>.json` (reference: `en.json`), keys named `area.name`, placeholders `%1`. Never glue translated fragments into a sentence.

## Security rules

- Secrets travel through the environment or a `0600` temp file, never through an argument you control, and are deleted right after use.
- Never commit profiles, hostnames, addresses, keys or logs. Screenshots use made-up data.
- Network access only to what the user configured. No telemetry.

## A Conduit plugin

```
manifest.json        id: conduit.<name>, author: andriar, license: MIT
Panel.qml            the widget and its popup
Conduit*.qml         the shared UI kit (a verified copy)
ui.lock              version and SHA-256 of the kit files
i18n/en.json, id.json
scripts/check.sh     manifest, translations, kit lock, secret scan
docs/                screenshots (made-up data only)
README.md            same sections as the VPN plugin: features, requirements, install, using it,
                     security and privacy, troubleshooting, roadmap, contributing, license
```

Repos are named `omarchy-conduit-<name>` and tagged with the topics `omarchy` and `omarchy-conduit`. `main` is protected and the `check` workflow is required.

## Sharing the kit

`omarchy plugin add` clones a repository without submodules, so the kit cannot be a submodule. Instead each plugin carries a copy that is **pinned and verified**:

```bash
scripts/sync-ui.sh          # copy the kit from main (or: scripts/sync-ui.sh <tag>)
```

`sync-ui.sh` downloads `ui.lock` and the components, checks every SHA-256, and only then writes the files. `scripts/check.sh` fails if a local `Conduit*.qml` no longer matches `ui.lock`, so copies cannot drift unnoticed.

To change a component: open a pull request in `omarchy-conduit-vpn`, run `scripts/ui-lock.sh <new version>`, merge, then run `scripts/sync-ui.sh` in the other plugins.
