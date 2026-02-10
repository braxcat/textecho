# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Session — 2026-02-11]

### Removed
- Legacy Linux files: GNOME_EXTENSION_NOTES.md, MIGRATION_PLAN.md, install_extension.sh,
  install_llm_backends.sh, export_quantized_whisper.sh, CLAUDE.md.archive
- Intel NPU driver .asc files
- Stray directories (hello-world/, bb/, btw/, expl/, infra/)
- Linux-specific .gitignore entries

### Changed
- CLAUDE.md: replaced Linux migration section with macOS-only platform info
- README.md: added Documentation section

### Added
- claude_docs/ scaffolded with 8 standard doc files
- Documentation Index in CLAUDE.md

### Fixed
- Committed previously uncommitted Swift native app improvements (setup wizard,
  build caching, overlay, settings)
