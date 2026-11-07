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
- List the models you used after `Models:` in the pull request's Notes, or write
  `None`
- Write pull request text and merge risk updates in simple English or ASD-STE100
  (Simplified Technical English)
- Review AI-drafted summaries, test plans, comments, and replies before posting them

Knowing AI was used gives us context when reviewing PRs. It is not a mark against a pull request. The same quality
bar applies either way: the change should be clear, tested where practical, and
small enough for a maintainer to review with confidence.

AI-assisted first drafts are permitted when a person proficient in the language
substantively reviews and corrects them. Do not use AI or machine translation as
the sole way to translate text. Human-reviewed translation pull requests are
welcome; see
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

In a headless session, run `./script/preflight.sh --checks-only` for all guards
and tests. It omits only the final staged-app build, signing, and launch
verification, so the full native gate remains pending until
`./script/preflight.sh` can run.

If you work with a coding agent, run the
[`merge-risk`](.agents/skills/merge-risk/SKILL.md) skill after preflight and add
its one-line result to the pull request's Notes. This is optional.

For docs-only changes, a lighter check such as `git diff --check` is usually
enough.

Any other questions? Reach out to [contact@interactivebuffoonery.com](mailto:contact@interactivebuffoonery.com) or open a GitHub issue.
