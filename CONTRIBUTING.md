# Contributing to awesoMux

Thanks for wanting to help with awesoMux!! This project is still early in its development, and the
maintainers are careful about scope because every review takes time and energy, and every feature adds technical debt.

Small, focused changes are **much** easier to review and much more likely to be merged.

## AI-assisted contributions

AI tools are welcome here. awesoMux is built for people who work with coding
agents, and we expect contributors to use the tools that help them think, test,
and build well.

Our rule is: a human must own and be involved with every contribution.

If you use AI while preparing a pull request:

- Read and understand what the code, docs, tests, and commands you submit actually do
- Be ready to explain what changed and why without sending reviewers back to an AI transcript
- Personally verify the behavior you claim is fixed or added
- Disclose substantial AI assistance in the pull request body
- Review AI-drafted summaries, test plans, comments, and replies before posting them
- If an AI agent drafts the pull request body, it should ask the contributor how
  much assistance to disclose after they have reviewed and revised the work:
  `none`, `light`, `moderate`, or `substantial`

Knowing AI was used gives us context when reviewing PRs. It is not a mark against a pull request. The same quality
bar applies either way: the change should be clear, tested where practical, and
small enough for a maintainer to review with confidence.

Do not use AI or machine translation as the sole way to translate text.
Human-authored translation pull requests are welcome; see
[`docs/localization.md`](docs/localization.md) for the locale, review, and
validation requirements. AI and other tools may still help with mechanical work
such as catalog extraction, formatting, and placeholder validation.

If you can translate awesoMux but are not comfortable editing code or string
catalogs, reach out to
[contact@interactivebuffoonery.com](mailto:contact@interactivebuffoonery.com).
We would be happy to take a reviewed list of English phrases and their
translations and help turn it into app resources and a pull request.

Do not let an autonomous agent open pull requests, push commits, post review
comments, or reply to maintainers **without direct human approval and ownership of
the result.** If a pull request looks like unreviewed generated work, maintainers
may close it without reviewing. We want humans, not anonymous clankers. :)

## Pull requests

Before opening a pull request:

- Search existing issues, pull requests, and docs so you do not duplicate work.
- Keep the change focused on one problem or one slice of a larger plan.
- Link any issues or prior discussion when one exists.
- Include screenshots or a short video for visible UI changes.
- List the commands or manual checks you actually ran.

Large features or changes that affect product direction should start with
discussion before code. A draft pull request is fine for showing work in
progress, but it should still explain the intended shape and what feedback you
need.

## Local validation

For app changes, the normal local gate is:

```sh
./script/preflight.sh
```

For docs-only changes, a lighter check such as `git diff --check` is usually
enough. If you cannot run the expected validation, say what blocked you in the
pull request.

Any other questions? Reach out to [contact@interactivebuffoonery.com](mailto:contact@interactivebuffoonery.com) or open a GitHub issue.
