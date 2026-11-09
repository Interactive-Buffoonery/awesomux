# Annotation keyboard fixture

Build with `./script/annotation-keyboard-e2e/run.sh`, then open the printed app path. The fixture has its own bundle ID and does not use an awesoMux profile. It compiles the production comment, document-note, and rich-input views with the real core/design-system dependencies. Only the app-shell announcement adapter is replaced with a native accessibility announcement. Save/Copy callbacks record disposable text on screen; they do not write a document, copy a prompt, or stage terminal input.

Choose Comment to check reply and Edit; Compose for a new annotation; Document note for its multiline editor; Rich input for the copy composer. Reset clears the recorded submissions and remounts the editor. Enabled and Fail save exercise disabled input and draft recovery.

Check Command-Return and Command-keypad-Enter, plain Return, Shift/Option-Return, held/repeated keys, and IME candidate confirmation. Multiline annotation/note fields retain plain-Return newlines. Reply stays single-line. Rich input retains Return submission and Shift/Option-Return newlines. IME confirmation must not create a submission; a later intentional accept chord may submit committed text.

Automated hosted route:

```sh
AWESOMUX_APPKIT_TEST_HOST=1 ./script/swift-test.sh --filter AnnotationKeyboardHostedTests
```

These tests mount the actual production views in a real AppKit window, focus the mounted editor or reply field editor, insert text through AppKit, and enter through the window key-equivalent route before normal event delivery. They include synthetic marked text and SwiftUI button fallbacks. They do not establish physical keypad or hardware IME behavior; keep native evidence separate.

For the reply/rich-input delegates' current-event checks, run:

```sh
./script/annotation-keyboard-e2e/run.sh --self-check
```

This starts only the disposable fixture, posts events to its real application loop, and exits with a JSON proof record and status 0 on success. Forwarding probes verify that repeated Return and keypad Enter actually reach the production delegates with the corresponding `NSApp.currentEvent`. Failed-save callbacks keep the normal submission gates open, so those gates cannot mask a missing repeat check. The self-check also covers Command modifier rejection, rich-input Shift/Option newlines, and a successful ordinary Return control. It uses injected events, not physical hardware or a live IME candidate session.
