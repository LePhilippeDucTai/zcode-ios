# Localization plan

The app's interface is currently French-only: strings are written inline in SwiftUI views (`App/`) and in the label
helpers of `ZCodeAppCore` (`*Labels.swift`, `Host.swift`, models' error messages). Roughly 450 user-visible strings,
plus accessibility labels and values. This plan moves the app to **English as the development language** with French
kept as a full translation, and makes adding further languages a translation-only job.

## Goals

- English UI by default, French preserved, any other language added with a String Catalog file only.
- No behaviour change: the protocol layers (`ZCodeWire`, `ZCodeRPC`, `ZCodeV4`, `ZCodeClient`) are not touched.
- Tests stay locale-independent.

## Step 1 — String Catalogs and English base

1. Set `developmentLanguage: en` in `project.yml` and add `knownRegions: [en, fr]`.
2. Add `App/Localizable.xcstrings` (app target) and
   `Packages/ZCodeKit/Sources/ZCodeAppCore/Resources/Localizable.xcstrings` (declare `resources: [.process("Resources")]`
   and `defaultLocalization: "en"` in `Package.swift`).
3. Views (`App/`): literal `Text("…")`, `Button("…")`, `Label("…")`, `.navigationTitle("…")` are already
   `LocalizedStringKey`s: rewrite each literal in English and add its French translation to the catalog. Strings built
   at runtime (`Text(variable)`) need `LocalizedStringResource` / `String(localized:)` at the source.
4. `ZCodeAppCore` labels return `String`: switch them to `String(localized: "…", bundle: .module, comment: "…")` so
   they resolve against the package catalog. Pluralised strings (« N sessions », « N fichiers modifiés »,
   « et N autres sessions en cours ») become catalog plural variants instead of hand-written `count == 1 ? … : …`.
5. Accessibility labels and values (`accessibilityLabel`, `accessibilityValue`) are localized too. Accessibility
   **identifiers** never change.

## Step 2 — Dates, numbers and units

- `TimeLabels` defaults to `Locale(identifier: "fr_FR")` and verbatim formats: use `Locale.autoupdatingCurrent` by
  default and locale-aware styles (`Date.FormatStyle`, `RelativeDateTimeFormatter`, `Duration.UnitsFormatStyle`),
  keeping injection for tests.
- Percentages, credits and byte sizes through `FormatStyle` (`.percent`, `.number`, `ByteCountFormatStyle`) instead of
  hand-built « 61 % » strings (French uses a narrow no-break space before `%`).

## Step 3 — Tests

- Unit tests that assert French strings: inject `Locale(identifier: "fr")` explicitly (or assert the English source)
  so they don't depend on the machine's language. Add a small test that every key of both catalogs has a translation.
- UI tests find elements by accessibility identifier wherever possible; the few that match visible text (« Nouvelle
  session », « Autonome », « Archiver la conversation », « Ajouter un projet », « Retirer », « Supprimer »…) either get
  an identifier or run with `-AppleLanguages (fr)` in `launchArguments` until migrated.

## Step 4 — Host-provided text

Some text comes from the ZCode server (option labels, error messages, model names). Keep the current approach: known
English server strings are mapped to localized labels, unknown ones are shown as received.

## Step 5 — Code comments (optional)

Comments are French. Translating them is independent from the UI and can happen file by file; new code should be
commented in English.

## Suggested order of work

1. Infrastructure (Step 1.1–1.2) and one screen end to end (host list) to validate the pipeline.
2. `ZCodeAppCore` labels (largest share, fully unit-tested).
3. Remaining views, screen by screen (Chat, Composer, Project, Extensions, Usage).
4. Dates and numbers, then tests.
5. Additional languages: add a column to the catalogs (e.g. `de`, `es`, `ja`, `zh-Hans`); no code change needed.
