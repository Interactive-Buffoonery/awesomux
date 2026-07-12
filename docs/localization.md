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

INT-612 establishes the English catalog and test-only alternate-locale fixtures.
It does not adopt a translation vendor or add new shipped translations. Existing
Polish and Russian plural resources remain in place until a separately reviewed
translation workflow covers the complete catalog.
