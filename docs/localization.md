# Localization

awesoMux uses English as its development language. `Resources/Localizable.xcstrings`
is the source catalog for ordinary user-facing strings, while count-dependent copy
stays in the locale-specific `Localizable.stringsdict` files under `Resources/`.

The staged macOS app owns localization resources through `Bundle.main`. Core and
DesignSystem code therefore use the same catalog as SwiftUI views; they do not ship
separate SwiftPM resource bundles. `script/build_and_run.sh` compiles the string
catalog and stages both resource formats into `Contents/Resources`.

Run `script/update_string_catalog.sh` after adding or removing localizable Swift
copy. The script extracts modern Foundation and SwiftUI strings from `Sources/`,
syncs the catalog, and validates the result. Review generated changes before
committing, especially merged translator comments and interpolated format strings.

Follow [ADR-0014](adr/0014-literal-as-key-localized-strings.md): ordinary strings
use the English literal as the key and include a translator comment. Plurals use a
full-sentence `.stringsdict` entry so each locale controls grammar and word order.

INT-612 establishes the English catalog and a synthetic `zz` test fixture. The
fixture deliberately uses bracketed pseudo-localized text rather than claiming
to represent a real language: it proves argument reordering, plural lookup, and
bundle delivery without presenting generated copy as a translation.

## Contributing translations

awesoMux accepts translations through community pull requests. Do not use AI or
machine translation as the sole way to translate text. Translation tools may
help with catalog extraction, formatting, placeholder checks, or a first draft,
but every submitted translation must be substantively reviewed and corrected by
one person proficient in that language.

Keep translation pull requests focused on one locale. Contributions may cover
part or all of the catalog; untranslated strings continue to fall back to
English. Depending on the phrases translated, a contribution may add:

- ordinary strings to `Resources/Localizable.xcstrings`;
- applicable plural entries to
  `Resources/<locale>.lproj/Localizable.stringsdict`; and
- targeted tests for placeholders, reordered arguments, or plural forms when
  those mechanics apply.

In the pull request, identify the language proficiency behind the translation
and confirm that a proficient person substantively reviewed and corrected the
localized text. Maintainers can verify catalog structure and runtime delivery,
but those checks do not substitute for language review.

Translators do not need coding experience. If you can translate awesoMux but are
not comfortable editing code or string catalogs, email
[contact@interactivebuffoonery.com](mailto:contact@interactivebuffoonery.com)
with a reviewed list of English phrases and their translations. A maintainer can
help turn that list into app resources and a pull request.
