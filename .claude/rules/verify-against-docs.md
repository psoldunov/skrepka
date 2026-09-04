# Verify Against Docs

## Never Trust Training Data

Training data is a memory of some past version of a library, not a description of
the one installed here. It is stale by default, it is confidently wrong about
renamed parameters and removed options, and it cannot tell you which of two APIs
the installed version actually ships.

So: **do not write code against a remembered API.** Confirm the signature, the
option name, the config key, the CLI flag, and the return shape against
documentation for the installed version *before* the code is written — not after
a test fails.

"I am sure about this one" is exactly the case this rule exists for. Familiarity
is not verification, and a well-known library is the easiest one to be wrong
about, because the memory is vivid and years old.

## What Must Be Confirmed

Confirm before writing, every time:

- A function, method, class, or component's parameters, options, and return value
- A config file key and its accepted values
- A CLI command, subcommand and flag
- Anything deprecated, renamed, or moved between major versions
- Framework conventions — file names, directory layout, symbols a framework
  looks for by name, required entitlements or manifest entries
- Error and edge-case behaviour you are relying on: what a call throws, what it
  returns when empty, what it does on cancellation

No confirmation needed for language built-ins, or for a module in this repo —
read that module.

## Source Order

### 1. The installed package

Docs and interface files shipped inside the resolved dependency describe the
exact version in use here and outrank everything else. Failing prose docs, read
the type or interface definitions, then the source. An installed type definition
is ground truth.

Where dependencies land, by ecosystem:

| Ecosystem | Resolved source | Version check |
|---|---|---|
| Node | `node_modules/<pkg>/` | `cat package.json`; `npm ls <pkg>` / `bun pm ls` |
| Swift / SwiftPM | `.build/checkouts/`, `Package.resolved` | `swift package show-dependencies` |
| Apple SDK frameworks | Xcode SDK headers, `.swiftinterface` | `xcodebuild -version`, deployment target |
| Python | `site-packages/<pkg>/`, `.pyi` stubs | `pip show <pkg>` / `uv pip list` |
| Rust | `~/.cargo/registry/`, `Cargo.lock` | `cargo tree -p <crate>` |
| Go | module cache, `go.sum` | `go list -m <module>` |
| Ruby | installed gem path | `bundle info <gem>` |

**Check the installed version before reading anything**, so that you read docs
for that version. A lockfile beats a manifest: the manifest states a range, the
lockfile states what actually resolved.

For a platform SDK there is no lockfile — the deployment target and the SDK
version are the equivalent, and an API's availability annotation is the thing to
confirm.

### 2. Context7 MCP

Preferred for everything else. `resolve-library-id` with the library name and the
question, then `query-docs` with the full question. Unsatisfying answer: call
`query-docs` again with `researchMode: true` before giving up.

### 3. Web search

Only when Context7 has no coverage or is unavailable. Prefer the vendor's own
docs over blog posts and answer sites, and check the version the page is written
for. A highly-ranked answer written against a major version you are not on is
worse than no answer, because it reads as authoritative.

## When Docs And Reality Disagree

Installed types win. If the documentation describes a parameter the installed
interface does not declare, believe the interface — that is version drift, not a
typing bug. Say so in the commit message or pull request description rather than
casting or force-unwrapping to push the documented shape through.

If nothing authoritative answers the question, say that plainly and write the
smallest experiment that settles it — a scratch script, a single test, a one-line
probe. Never fill the gap with a guess presented as fact.

Some things documentation genuinely cannot settle: undocumented platform
behaviour, timing, how two frameworks interact. Those are not licence to guess.
They are the cases that must be *labelled* unverified and prototyped first.

## No Guessing In Prose Either

The rule covers answers, not just code. Do not tell the user how an API behaves
from memory: verify first, then answer. An unverified claim about a library is as
costly as an unverified line of code, and harder for a reviewer to spot, because
prose carries no type checker.

Note the source when it is not obvious — a bare reference in the commit message
or pull request description. Source URLs do not go in source files.

When a claim could not be verified, mark it as unverified where the claim lives.
A reader cannot distinguish a checked statement from a confident guess unless you
tell them which it is.

## Checklist

- [ ] Installed version checked before reading any docs
- [ ] Every external API, config key and CLI flag confirmed against docs for that
      version
- [ ] Context7 tried before web search; vendor docs preferred over third-party
      posts
- [ ] Installed interface definitions believed over documentation when they
      conflict
- [ ] Anything unverifiable labelled as such, not smoothed over
- [ ] Nothing written from memory alone — including prose answers to the user
