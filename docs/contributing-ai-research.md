# AI contribution standards research

awesoMux should be openly pro-AI while protecting maintainer time. The useful
line is not "AI or no AI"; it is whether a human understands, verifies, and owns
the contribution.

## Projects worth modeling

### T3 Code

Source: https://github.com/pingdotgg/t3code

T3 Code has the cleanest pull request metadata pattern:

- `size:XS` through `size:XXL` labels show review size at a glance.
- `vouch:trusted`, `vouch:unvouched`, and `vouch:denounced` labels show whether
  the author is trusted by repository permissions or the `.github/VOUCHED.td`
  list.
- Their contributor docs strongly prefer small, focused bug fixes and warn that
  large drive-by feature work may be closed quickly.

What to reuse:

- Copy the size ladder. It gives maintainers a quick way to sort review cost.
- Use trust labels as inspiration, but do not copy the hard gate yet.

What to avoid for awesoMux v1:

- Do not make the first version automatically close unverified contributors.
- Do not use sharp wording that makes AI use itself feel unwelcome.

### Ghostty

Sources:

- https://github.com/ghostty-org/ghostty/blob/main/AI_POLICY.md
- https://github.com/ghostty-org/ghostty/blob/main/CONTRIBUTING.md

Ghostty is explicit that AI is welcome as a tool, but every contribution needs a
human in the loop. Contributors must disclose AI use, understand their changes,
and avoid submitting work they cannot explain. First-time contributors use a
vouch request before opening pull requests.

What to reuse:

- "You must understand your code" is the strongest rule.
- AI disclosure helps reviewers understand risk without treating AI use as bad.
- A vouch system is a possible future answer if review volume becomes noisy.

What to avoid for awesoMux v1:

- Public denouncement language is stronger than awesoMux needs right now.
- A hard first-time-contributor gate is probably more process than the project
  needs before there is real PR volume.

### Selenium

Source: https://github.com/SeleniumHQ/selenium/blob/trunk/CONTRIBUTING.md

Selenium has the closest tone match for awesoMux. Their policy allows AI tools,
states that the human is the author, asks for disclosure when substantial parts
of a PR are AI-assisted, and says disclosure is for reviewer context rather than
judgment.

What to reuse:

- "You are the author" is clear and warm.
- Disclosure belongs in the PR body, not commit authorship metadata.
- Autonomous agents should not act without direct human approval.

### Directus

Source: https://github.com/directus/directus/blob/main/ai_policy.md

Directus keeps the policy short: AI is welcome, but not a substitute for
understanding or accountability. It also calls out AI-written communication and
asks that comments and pull request text ultimately be the contributor's own.

What to reuse:

- Keep the policy readable and human.
- Include issue comments, PR descriptions, and review replies, not only code.

### SlateDB

Source: https://github.com/slatedb/slatedb/blob/main/CONTRIBUTING.md

SlateDB accepts largely AI-generated pull requests if the contributor discloses
AI use, names the tool and model, understands the change, reviews it, and follows
the PR template. It also asks contributors to run a local AI review before
submitting.

What to reuse:

- A concise checklist works well in the PR template.
- "Understand, review, and verify" is enough for v1; awesoMux does not need to
  require a local AI review command yet.

## Recommended awesoMux stance

Use a welcoming gate:

- AI tools are welcome.
- Humans own the contribution.
- Substantial AI help should be disclosed in the pull request body.
- If an AI agent writes the PR body, it should ask the contributor to choose the
  assistance level (`none`, `light`, `moderate`, or `substantial`) after they
  review and revise the work.
- Pull request summaries, test plans, and review replies must be checked by the
  human contributor before posting.
- Maintainers may close low-effort generated work, oversized PRs, untested
  changes, or changes the contributor cannot explain.

This keeps the project aligned with how awesoMux is built, while still making it
clear that maintainers are not the first human review pass.

## Labels and automation

Add GitHub PR size labels now:

| Label | Effective changed lines |
| --- | ---: |
| `size:XS` | 0-9 |
| `size:S` | 10-29 |
| `size:M` | 30-99 |
| `size:L` | 100-499 |
| `size:XL` | 500-999 |
| `size:XXL` | 1,000+ |

Use "effective changed lines" so test-only PRs still get a size, while mixed
code-and-test PRs are sized by non-test changes.

Do not automate trust labels in v1. If the project later needs them, prefer
human-language labels:

- `human:verified` means a maintainer trusts the contributor to own and explain
  their changes.
- `human:needs-verification` means the contributor is new or not yet known.
- `human:blocked` is reserved for repeated low-effort or bad-faith submissions.

Those labels should describe human accountability, not whether AI was used.
