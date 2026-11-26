---
name: delete-comment
description: Audit, categorize, and delete Swift code comments (tautologies, stale notes, excuses, decision records), filing issues for hacks, moving decisions to docs/adr/, and tightening the comment ratchet. Use when user invokes /delete-comment, asks to audit or remove comments, or resolves no_comments / comment-ratchet lint failures.
---

# Delete Comment

Eliminate non-directive code comments from the Ayna Swift codebase without losing architectural decisions or hiding technical debt.

## Workflow

1. **Inventory remaining comments**
   ```bash
   python3 Scripts/check-comment-ratchet.py --list
   ```
   Directives (`// swiftlint:`, `// swiftformat:`, `// swift-tools-version:`, `// sourceLocation`) are automatically exempt.

2. **Categorize every comment block**
   - **Tautology**: Repeats what the code already says (including file headers, `// MARK:`, and routine doc comments).
   - **Stale**: References obsolete behavior, dead code, old OS/Xcode versions, or contradicts current code.
   - **Excuse**: Rationalizes a hack, workaround, sleep/timing trick, skipped test, missing feature, or deferred refactor.
   - **Decision Record**: Captures a non-obvious architectural, security, concurrency, or platform invariant/trade-off.

3. **Execute the action for each category**
   - **Tautology / Stale**: Delete the comment.
   - **Excuse**: Delete the comment and file a GitHub issue describing the hack and desired fix (group closely related excuses in the same subsystem into one issue).
   - **Decision Record**: Move the rationale into an existing ADR in `docs/adr/` or create the next numbered ADR (`docs/adr/NNNN-title.md`), update `docs/adr/README.md`, then delete the comment.

4. **Tighten the ratchet and verify**
   ```bash
   python3 Scripts/check-comment-ratchet.py --update-baseline
   swiftformat .
   swiftlint lint --strict
   python3 Scripts/check-comment-ratchet.py
   swift build
   ```
   If deleting comments in batches, `--update-baseline` lowers `.comment-ratchet.json` to the new count and refuses to raise any file's budget.

## Rules

- Never delete compiler or tool directives (`swiftlint:`, `swiftformat:`, `swift-tools-version:`, `sourceLocation`).
- Never suppress `no_comments` in Swift code; fix the violation by applying the category action above.
- Always inspect surrounding code before classifying a comment as Stale, Excuse, or Decision Record.
