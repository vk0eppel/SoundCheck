# Domain Documentation Consumer Rules

This document outlines how other domain-aware skills (e.g., `improve-codebase-architecture`, `diagnosing-bugs`, `tdd`) should consume project documentation when operating within this repository structure.

## Context Consumption Policy
Since this is configured for a **Single-Context** layout, all specialized skills will rely on the following files to understand the project's domain language and architectural history:

1.  **`CONTEXT.md`**: Used by skills to learn the ubiquitous language, key concepts, and high-level design philosophy of the codebase.
2.  **`docs/adr/`**: Archival directory containing Architectural Decision Records (ADRs) that explain significant past design choices.

## Consumption Guidelines
*   **`CONTEXT.md` Interpretation**: Skills should parse this file to identify core terminology, system boundaries, and non-obvious constraints of the project domain. This context is essential for accurate suggestions or diagnoses.
*   **`docs/adr/` Interpretation**: When a skill needs context on *why* something is designed a certain way (e.g., why a specific module dependency exists), it will consult the ADRs to understand historical trade-offs and architectural intent.

## Agent Interaction
When performing tasks related to domain improvement or debugging, skills must prioritize reading `CONTEXT.md` first for intent before consulting granular details in the ADR directory.