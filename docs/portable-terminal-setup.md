# Portable terminal setup

In awesoMux, open **Settings → Advanced** to find the active `config.toml`.
The installed app uses `~/.config/awesomux/config.toml`. Development profiles
have their own directories.

1. Save private backups of the source and destination configs before editing.
   Quit awesoMux on the destination Mac, then merge the settings you want into
   its existing files. Edit keys under existing TOML headers and append only
   missing tables. Keep one definition per key.
2. Copy the visual preferences you want from `[appearance]`, such as
   `theme`, `accent`, `mono_font`, and `font_size`. Install any custom fonts
   on the destination. Copy your app shortcut overrides from
   `[keyboard.shortcuts.<id>]`. Use **Settings → Keys** to check the bindings
   against the destination's keyboard layout and other shortcuts.
3. Transfer any Ghostty theme separately using the steps below. Start awesoMux
   and verify the appearance and shortcuts. To undo the transfer, quit the
   destination app and restore the backed-up settings, including the Ghostty
   theme selection. If you created a Ghostty config for the transfer, move
   it out of the config directory. A theme added under a new name can stay unused.

Leave session snapshots, running sessions and sockets, app preferences and
Keychain credentials on the original Mac. Keep local paths, remote hosts,
agent integrations, permissions and trust settings out of the transfer.
Copy only settings you recognize from each file. Keep unsupported settings
in the original backup so you can recover them later.

A save can preserve ordinary unknown keys inside `[appearance]` and
`[terminal]` and plain unknown top-level TOML tables. Those values have no
effect. Unknown keys in other sections may be dropped. Arrays of tables
(`[[table]]`) can interfere with saving nearby settings. Keep source arrays
in the backup. After a save, compare existing destination arrays and nearby
settings with the backup.

## Use a Ghostty theme

Choose **Settings → Appearance → Terminal background → Ghostty**
(`terminal_background_mode = "ghostty"` in TOML). VoiceOver calls the picker
**Terminal background source**. awesoMux loads the Ghostty configuration
through libghostty. A custom named theme goes in
`$XDG_CONFIG_HOME/ghostty/themes/` (normally `~/.config/ghostty/themes/`) and
is selected with `theme = Theme Name` in `ghostty/config.ghostty`. Check for a
file with that name on the destination before copying. Reuse it if the contents
match. If they differ, save the incoming theme under an unused name and use
that name on the destination's `theme` line. Back up the destination Ghostty
config before editing it. Transfer the theme values you need and leave
source-specific paths and includes behind.

libghostty also reads legacy `ghostty/config` and the Ghostty configuration
under `~/Library/Application Support/com.mitchellh.ghostty/`. Check these
files for conflicting settings. Standalone Ghostty and awesoMux on the same
Mac can share these files. awesoMux applies its own terminal font and size
settings. For awesoMux's bundled Catppuccin or Selenized colors, choose
**Theme** in the same control. Use **Settings → Keys** for
[awesoMux app shortcuts](shortcuts.md).
Ghostty `keybind` entries for app and workspace commands do not migrate those
commands.

## Verify in two disposable profiles

Use two fresh macOS test accounts or two disposable VM profiles with separate
home directories. Install the same awesoMux build in each and confirm the
active TOML path in **Settings → Advanced**. Keep the production profile out
of this check.

1. Start the destination once with its defaults. Confirm that **New
   Workspace** uses Command-N, then quit.
2. With the source app closed, merge this fixture into its TOML. If a
   section already exists, update its keys under the existing header:

   ```toml
   [appearance]
   theme = "dark"
   font_size = 15.0
   terminal_background_mode = "ghostty"
   future_color = "violet"

   [keyboard.shortcuts.newWorkspace]
   key = "n"
   modifiers = ["control", "shift", "command"]

   [migration_example]
   note = "Keep this table"
   ```

3. In the source's isolated Ghostty directory, put `theme = awesoMux Migration`
   in `config.ghostty` and save the following as `themes/awesoMux Migration`:

   ```text
   background = #17324d
   foreground = #f4e7c5
   palette = 1=#ff7070
   ```

4. Launch the source and check that a terminal shows the blue background and
   light text. Run `printf '\033[31mANSI red\033[0m\n'` to check the red sample.
   Press Control-Shift-Command-N and confirm it opens a workspace. Quit, then
   merge the example TOML keys under the existing destination headers and
   append only missing tables. Transfer the theme selection and theme file.
   Start the destination and repeat the checks.
5. In the destination, change the font size from 15 to 16 in
   **Settings → Appearance**. Reopen the TOML and confirm `font_size` was
   updated. Check that `future_color = "violet"` remains under `[appearance]`
   and `note = "Keep this table"` remains under `[migration_example]`.
   Keep both profiles' test files and record the build, observed colors, and
   shortcut behavior. If you cannot inspect the rendered colors, record
   that check as unverified.
