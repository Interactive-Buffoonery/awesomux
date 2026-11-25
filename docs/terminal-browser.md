# Terminal Browser

Install [Terminal Browser](https://terminal-browser.com/) separately. To allow
it to open a right split, add the path of the executable it runs (absolute or starting with `~/`) to the
existing `[terminal]` section of `~/.config/awesomux/config.toml`. Development
builds use the profile-specific directory. For the
Terminal Browser installer’s default layout, use:

```toml
[terminal]
terminal_browser_executable = "~/.local/share/terminal-browser/app/bin/terminal-browser"
```

Relaunch awesoMux after adding or changing the path. In a local workspace with
**Keep sessions running in the background** turned off, run this from a directory
you own:

```sh
terminal-browser open https://example.com --split right
```

Local HTML files work too. Start with a new local workspace if the current pane
was opened with background sessions enabled. To turn off the integration, remove
the setting and relaunch awesoMux. If the command reports that it cannot find its
pane, check that the configured path points to the executable inside the
Terminal Browser installation and that the file can be executed.

awesoMux accepts Terminal Browser's pane lookup and right-split requests from
its private local socket. Split requests must use the configured executable
and match the active local pane. While enabled, a process in that pane can
request the allowed browser launch. Browser commands, updates, and browsing data
are managed by Terminal Browser. The integration currently supports right
splits at awesoMux's default size, with background sessions disabled.
