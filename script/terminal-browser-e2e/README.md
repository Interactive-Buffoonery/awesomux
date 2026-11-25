# Terminal Browser smoke test

Stage a worktree-local build with `./script/build_and_run.sh --stage-local-api-e2e`.
Configure the isolated profile as described in [Terminal Browser setup](../../docs/terminal-browser.md).

1. Start the app and create a disposable local workspace with background sessions disabled.
2. In the source shell, change into this checkout and run:

   ```sh
   terminal-browser open "$PWD/script/terminal-browser-e2e/fixture.html" --split right
   ```

3. Confirm the fixture opens in a new right pane. Click the disclosure, type into the input, and scroll to the bottom.
4. Resize the split. Confirm the page redraws and that input follows focus. Run a shell command in the original pane and check that the prompt has no leftover escape-sequence text.
5. Quit Terminal Browser with Control-Q and dismiss the exited terminal. Confirm the original pane is still usable.
6. Repeat with `--split left` and confirm explicitly rejecting it leaves the original layout intact.
7. Enable background sessions in the isolated profile. A newly opened amx-backed shell should have no `TERMINAL_BROWSER_TERMINAL_SOCKET`.
8. Turn background sessions off, remove the executable setting, and relaunch. Confirm a fresh local shell has neither `ZMX_SESSION` nor `TERMINAL_BROWSER_TERMINAL_SOCKET`.

Record the awesoMux and Terminal Browser versions with the results.
