# Release Checklist

Run this checklist before publishing a public package.

## Validation

```bash
mix deps.get
mix compile
mix format --check-formatted
mix test
mix docs
```

Also run:

```bash
rg -n "Phase [0-9]|phase [0-9]|roadm[a]p|TO[D]O|FI[X]ME" README.md lib guides livebooks
rg -n "/h[o]me/|/Us[e]rs/|s[k]-|anthropic_api_[k]ey|openai_api_[k]ey" README.md lib guides livebooks
```

## Package

- Confirm license and add a `LICENSE` file before publishing.
- Confirm `mix.exs` package files and links.
- Confirm changelog entry.
- Confirm security guidance.
- Confirm version tag and ExDoc `source_ref`.
- Build package locally with Hex before publishing.

## Application Trial Gates

At least one real application trial should cover:

- documentation QA
- tool execution and guard behavior
- runtime session operation
- evaluation fixtures
- trace or replay workflow
