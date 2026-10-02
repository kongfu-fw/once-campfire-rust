# once-campfire-rust

Campfire in Rust. It started as a port that had to be indistinguishable from the Rails app in
`reference/` (a submodule pinned to the SHA it was matched against), and that parity is done: see
`README.md` and `plans/rust-conversion.md`. The app may now diverge from Rails where that makes it
faster or better.

- The Rails app is still the reference for anything not deliberately changed: when in doubt about
  existing behavior, read the Ruby.
- Stay compatible with existing installs unless told otherwise: the SQLite schema, the storage
  layout, and signed/encrypted cookies (so people stay signed in across an upgrade).
- List every deliberate divergence under "Known differences" in `README.md`, and update the tests
  and parity masks it affects.
- Port-owned frontend changes go in `crates/assets/overrides/`, which shadows the reference's assets
  by logical path. Don't edit `reference/`.

## Layout

| Path | Package | What |
|---|---|---|
| `crates/ruby` | `ruby_compat` | Ruby's own string behaviour the other crates share (ERB escaping, `String#to_i`/`#to_f`/`#strip`, `Float#to_s`, `CGI.escape`, `ERB::Util.url_encode`, Active Record's integer binding, Rack's byte ranges), checked against Ruby by `vectors/ruby_core.json`; no dependencies |
| `crates/rails_compat` | `rails_compat` | Rails signing/encryption/serialization contracts and the Rails formats several crates write (`ActiveSupport::JSON`, `Content-Disposition`), verified by `vectors/`, and the app's `Clock` (`Time.current`, and time travel for tests) |
| `crates/kit` | `campfire_kit` | Axum adapter, `Ctx`, params, cookies, session, forgery protection, flash, formats, responses, gzip, and the front server (TLS, ACME, HTTP/2, response cache) |
| `crates/routes` | `campfire_routes` | Path helpers mirroring `config/routes.rb` |
| `crates/db` | `campfire_db` | rusqlite over the existing schema, models, queries, fixtures loader |
| `crates/richtext` | `campfire_richtext` | Action Text content pipeline: sanitize, attachments, autolink, plain text |
| `crates/storage` | `campfire_storage` | Active Storage-compatible blobs, disk service, variants (libvips), previews (ffmpeg) |
| `crates/cable` | `campfire_cable` | Action Cable protocol server, its WebSocket implementation, and in-process pub/sub |
| `crates/assets` | `campfire_assets` | Propshaft-compatible digesting, importmap, vendored JS/CSS, port-owned overrides |
| `crates/views` | `campfire_views` | Askama templates (at the ERB file's relative path) and view helpers |
| `crates/campfire` | `campfire` (bin) | Controllers, router wiring, channels, jobs, integrations |
| `parity/` | — | Playwright parity harness, screen inventory, reference Docker setup |
| `reference-tools/` | — | Ruby scripts run inside the reference container to produce `vectors/` |
| `bench/` | — | Load generator, benchmark scripts and recorded results |

## Working rules

- Rust comes from mise if it isn't on the PATH: `mise exec rust@1.98.1 -- cargo ...` (the version
  in `Dockerfile`). The `reference/` submodule must be checked out for `crates/assets` to build.
- `cargo test --workspace --exclude html5ever` runs everything. The app's integration tests need the
  seed data (`parity/bin/seed build`, which needs Docker); without it they pass without running,
  with only a note on stderr, so say so when reporting results. `CAMPFIRE_REQUIRE_SEED=1` makes a
  missing seed fail them instead.
- `cargo clippy --workspace --exclude html5ever --all-targets` should stay clean. (`html5ever` is a
  vendored copy with one backported fix and two small additions for Gumbo's parse limits, all
  recorded in its `Cargo.toml`, and identical to upstream otherwise.)
- Format with `cargo fmt --all` (`rustfmt.toml`) before committing, and `bench/loadgen`, a workspace
  of its own, with `cargo fmt --manifest-path bench/loadgen/Cargo.toml`; CI checks both. The
  vendored html5ever has its own `rustfmt.toml` that turns formatting off, and generated tables are
  marked `#[rustfmt::skip]`.
- CI also runs `cargo shear` for dependencies declared but not used. When it can't see a real use
  (a build script's `#[path]` modules, a self dev-dependency), list the crate under
  `[package.metadata.cargo-shear] ignored` in that manifest, with the reason.
- Put shared dependency versions in the root `[workspace.dependencies]`, and reference them with
  `foo.workspace = true`.
- When matching existing behavior, read the reference's source. When it depends on Rails or gem
  internals, read the gem source inside the reference image
  (`docker run --rm campfire-reference bundle show <gem>`), not docs or memory.
- Write code that reads like the surrounding code: small, clearly named functions, and comments
  only where the behavior is non-obvious. Cite the reference file (`reference/app/...`) when
  matching Rails, and say why when deliberately diverging from it.
- Tests live beside the code. Golden-vector tests read `vectors/*.json`.
- Performance changes come with before-and-after measurements, recorded under `bench/results/`.

## Reference container

`parity/` builds the reference image as `campfire-reference` from `reference/Dockerfile` and runs it
in production mode with a fixed `SECRET_KEY_BASE` (see `parity/.env.reference`) so that golden
vectors, seeds and screenshots are reproducible. Those keys are for tests only.

## Docker and development workflow

See [DEVELOPMENT.md](DEVELOPMENT.md) for full development notes.
- **Do NOT push images to Docker Hub during routine development.** Only build and test locally (`docker compose up -d`). Push images to Docker Hub only when merging into `main` or upon explicit user request.
- **Image repository**: `dogming/once-campfire-rust`. Tags: `latest`, version, date (e.g. `20261001`).
- **Local port**: default `3000:80` (port 8080 may conflict with other local services).
- **Line endings**: keep `core.autocrlf=false` in both repo and `reference/` so asset hashes remain accurate.
- **Frontend changes**: place in `crates/assets/overrides/` and record in `crates/assets/OVERRIDES.md`. Do not edit `reference/`.
- **Changelog**: document user-facing additions and changes in `CHANGELOG.md`.

## ASD-STE100 Writing Rules

ASD-STE100 (Simplified Technical English) is an international specification for technical documentation designed to maximize clarity, eliminate ambiguity, and make text easy to understand—especially for non-native English speakers and automated translation tools.

### Core Principles
- **Part 1 (Writing Rules)**: 9 rule sections governing grammar, syntax, and document structure.
- **Part 2 (Dictionary)**: Controlled vocabulary where each approved word has one designated meaning and one approved part of speech.

### Key Rules and Guidelines

#### 1. Words and Vocabulary
- **Use approved words only**: Rely on the STE dictionary or authorized Technical Names (TN) and Technical Verbs (TV).
- **One word, one meaning, one part of speech**: Do not use words interchangeably across parts of speech (e.g., *close* is only a verb, never an adjective; use *shut* or *near* instead).
- **No synonyms or colloquialisms**: Avoid jargon, slang, idioms, and figurative language.
- **Standard affixes only**: Use only approved prefixes and suffixes from the specification.

#### 2. Noun Clusters
- **Limit noun clusters to maximum 3 nouns**: Do not string four or more nouns together.
  - *Non-STE*: "engine oil pressure indicator switch bracket"
  - *STE*: "bracket for the engine-oil pressure indicator switch"
- Use hyphens between related modifying words to clarify relationships.

#### 3. Verbs and Tenses
- **Restricted tenses**:
  - Simple Present (e.g., "The valve opens...")
  - Simple Past (e.g., "The technician installed the pump.")
  - Simple Future using *will* (e.g., "The indicator will flash.")
  - Imperative (for commands) (e.g., "Remove the cover.")
- **Avoid continuous/progressive forms**: Do not use *-ing* verb forms (gerunds/present participles) unless explicitly authorized as technical names or adjectives.
- **Strict modal auxiliary usage**: Use *can* for capability; avoid *may*, *might*, *could*, *should*, and *would*. Use *must* only for mandatory requirements when an imperative cannot be used.
- **Active voice**: Use active voice primarily. Reserve passive voice for descriptive explanations where the actor is unknown or unimportant.

#### 4. Sentence Structure and Word Count Limits
- **Procedural sentences (instructions)**: Maximum 20 words per sentence.
- **Descriptive sentences (explanations)**: Maximum 25 words per sentence.
- **One thought / one instruction per sentence**: Do not combine multiple actions into one sentence unless they happen at the same time or in immediate sequence.
- **Paragraph length**: Maximum 6 sentences per paragraph in descriptive text. Never write multi-sentence paragraphs in procedural steps.

#### 5. Procedural Writing
- Start action steps with an imperative verb (e.g., "Loosen the screws.", "Open the valve.").
- Use vertical numbered lists for chronological steps.
- State conditions before the action: "When the LED turns green, press the button." (not: "Press the button when the LED turns green.").

#### 6. Descriptive Writing
- Keep descriptions functional, direct, and factual.
- Clearly separate descriptive explanations from procedural instructions.
- Provide high-level context before introducing low-level details.

#### 7. Safety Messages (Warnings, Cautions, and Notes)
- Place warnings and cautions **before** the related procedural action, never after.
- Include three essential elements:
  1. The specific hazard.
  2. The consequence of ignoring it (injury, equipment damage).
  3. The action required to avoid it.
- Follow standardized alert levels:
  - **WARNING**: Risk of injury or loss of life.
  - **CAUTION**: Risk of damage to equipment, software, or data.
  - **NOTE**: Clarifying or non-safety contextual guidance.

#### 8. Punctuation and Formatting
- Keep punctuation simple: periods, commas, colons, hyphens, and parentheses.
- Do not use semicolons (`;`) or exclamation points (`!`).
- Use vertical bulleted or tabular lists for complex conditions, options, or parameters.

#### 9. Precision and Measurable Values
- Avoid vague qualifiers such as *properly*, *carefully*, *sufficiently*, *frequently*, *as required*, or *approximately*.
- Provide concrete values, tolerances, and explicit thresholds (e.g., "Torque the bolt to 25 N·m", not "Tighten the bolt firmly").

