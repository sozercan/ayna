---
description: |
  This workflow monitors unit and UI test failures across macOS 14, 15, and 26,
  investigates the root cause, and automatically creates draft PRs to fix the issues.
  
  Flow:
  1. Triggered by Test Suite workflow failure or manually/on schedule
  2. Runs validation jobs on all platforms to detect current test status
  3. Agent analyzes validation results
  4. If all tests pass, no action needed
  5. If any tests fail, agent creates a single PR to fix all failures

on:
  workflow_run:
    workflows: ["Test Suite"]
    types: [completed]
    branches:
      - main
  schedule:
    - cron: '0 6 * * *'  # Daily at 6 AM UTC
  workflow_dispatch:
    inputs:
      test_target:
        description: 'Which tests to run (aynaTests, aynaUITests, both)'
        required: false
        default: 'both'
        type: choice
        options:
          - aynaTests
          - aynaUITests
          - both

timeout-minutes: 60

permissions:
  all: read
  id-token: write

network: defaults

engine:
  id: copilot
  model: claude-opus-4.5

# Validation jobs run BEFORE the agent to detect failures
# Skip these if triggered by workflow_run (Test Suite already ran tests)
jobs:
  validate-macos-14:
    if: github.event.workflow_run.id == ''
    runs-on: macos-14
    outputs:
      result: ${{ steps.test.outcome }}
      log: ${{ steps.test.outputs.log }}
    steps:
      - name: Checkout
        uses: actions/checkout@v5

      - name: Select Xcode 16.2
        run: sudo xcode-select -s /Applications/Xcode_16.2.app/Contents/Developer

      - name: Build and Test
        id: test
        continue-on-error: true
        run: |
          set -o pipefail
          TEST_TARGET="${{ github.event.inputs.test_target || 'both' }}"
          echo "=== macOS 14 / Xcode 16.2 ===" | tee -a $GITHUB_STEP_SUMMARY
          
          # Build
          xcodebuild \
            -project ayna.xcodeproj \
            -scheme Ayna \
            -destination 'platform=macOS' \
            -derivedDataPath ./build \
            CODE_SIGN_IDENTITY="" \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGNING_ALLOWED=NO \
            build 2>&1 | tee build.log
          
          # Run unit tests
          if [[ "$TEST_TARGET" == "aynaTests" || "$TEST_TARGET" == "both" ]]; then
            echo "=== Running unit tests ===" | tee -a $GITHUB_STEP_SUMMARY
            xcodebuild \
              -project ayna.xcodeproj \
              -scheme Ayna \
              -destination 'platform=macOS' \
              -derivedDataPath ./build \
              CODE_SIGN_IDENTITY="" \
              CODE_SIGNING_REQUIRED=NO \
              CODE_SIGNING_ALLOWED=NO \
              -only-testing:aynaTests \
              test 2>&1 | tee -a test.log
          fi
          
          # Run UI tests
          if [[ "$TEST_TARGET" == "aynaUITests" || "$TEST_TARGET" == "both" ]]; then
            echo "=== Running UI tests ===" | tee -a $GITHUB_STEP_SUMMARY
            xcodebuild \
              -project ayna.xcodeproj \
              -scheme Ayna \
              -destination 'platform=macOS' \
              -derivedDataPath ./build \
              CODE_SIGN_IDENTITY="-" \
              CODE_SIGNING_REQUIRED=YES \
              CODE_SIGNING_ALLOWED=YES \
              -only-testing:aynaUITests \
              test 2>&1 | tee -a test.log
          fi

      - name: Upload logs
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: macos-14-logs
          path: |
            build.log
            test.log

  validate-macos-15:
    if: github.event.workflow_run.id == ''
    runs-on: macos-15
    outputs:
      result: ${{ steps.test.outcome }}
      log: ${{ steps.test.outputs.log }}
    steps:
      - name: Checkout
        uses: actions/checkout@v5

      - name: Select Xcode 16.4
        run: sudo xcode-select -s /Applications/Xcode_16.4.app/Contents/Developer

      - name: Build and Test
        id: test
        continue-on-error: true
        run: |
          set -o pipefail
          TEST_TARGET="${{ github.event.inputs.test_target || 'both' }}"
          echo "=== macOS 15 / Xcode 16.4 ===" | tee -a $GITHUB_STEP_SUMMARY
          
          # Build
          xcodebuild \
            -project ayna.xcodeproj \
            -scheme Ayna \
            -destination 'platform=macOS' \
            -derivedDataPath ./build \
            CODE_SIGN_IDENTITY="" \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGNING_ALLOWED=NO \
            build 2>&1 | tee build.log
          
          # Run unit tests
          if [[ "$TEST_TARGET" == "aynaTests" || "$TEST_TARGET" == "both" ]]; then
            echo "=== Running unit tests ===" | tee -a $GITHUB_STEP_SUMMARY
            xcodebuild \
              -project ayna.xcodeproj \
              -scheme Ayna \
              -destination 'platform=macOS' \
              -derivedDataPath ./build \
              CODE_SIGN_IDENTITY="" \
              CODE_SIGNING_REQUIRED=NO \
              CODE_SIGNING_ALLOWED=NO \
              -only-testing:aynaTests \
              test 2>&1 | tee -a test.log
          fi
          
          # Run UI tests
          if [[ "$TEST_TARGET" == "aynaUITests" || "$TEST_TARGET" == "both" ]]; then
            echo "=== Running UI tests ===" | tee -a $GITHUB_STEP_SUMMARY
            xcodebuild \
              -project ayna.xcodeproj \
              -scheme Ayna \
              -destination 'platform=macOS' \
              -derivedDataPath ./build \
              CODE_SIGN_IDENTITY="-" \
              CODE_SIGNING_REQUIRED=YES \
              CODE_SIGNING_ALLOWED=YES \
              -only-testing:aynaUITests \
              test 2>&1 | tee -a test.log
          fi

      - name: Upload logs
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: macos-15-logs
          path: |
            build.log
            test.log

  validate-macos-26:
    if: github.event.workflow_run.id == ''
    runs-on: macos-26
    outputs:
      result: ${{ steps.test.outcome }}
      log: ${{ steps.test.outputs.log }}
    steps:
      - name: Checkout
        uses: actions/checkout@v5

      - name: Select Xcode 26.0
        run: sudo xcode-select -s /Applications/Xcode_26.0.app/Contents/Developer

      - name: Build and Test
        id: test
        continue-on-error: true
        run: |
          set -o pipefail
          TEST_TARGET="${{ github.event.inputs.test_target || 'both' }}"
          echo "=== macOS 26 / Xcode 26.0 ===" | tee -a $GITHUB_STEP_SUMMARY
          
          # Build
          xcodebuild \
            -project ayna.xcodeproj \
            -scheme Ayna \
            -destination 'platform=macOS' \
            -derivedDataPath ./build \
            CODE_SIGN_IDENTITY="" \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGNING_ALLOWED=NO \
            build 2>&1 | tee build.log
          
          # Run unit tests
          if [[ "$TEST_TARGET" == "aynaTests" || "$TEST_TARGET" == "both" ]]; then
            echo "=== Running unit tests ===" | tee -a $GITHUB_STEP_SUMMARY
            xcodebuild \
              -project ayna.xcodeproj \
              -scheme Ayna \
              -destination 'platform=macOS' \
              -derivedDataPath ./build \
              CODE_SIGN_IDENTITY="" \
              CODE_SIGNING_REQUIRED=NO \
              CODE_SIGNING_ALLOWED=NO \
              -only-testing:aynaTests \
              test 2>&1 | tee -a test.log
          fi
          
          # Run UI tests
          if [[ "$TEST_TARGET" == "aynaUITests" || "$TEST_TARGET" == "both" ]]; then
            echo "=== Running UI tests ===" | tee -a $GITHUB_STEP_SUMMARY
            xcodebuild \
              -project ayna.xcodeproj \
              -scheme Ayna \
              -destination 'platform=macOS' \
              -derivedDataPath ./build \
              CODE_SIGN_IDENTITY="-" \
              CODE_SIGNING_REQUIRED=YES \
              CODE_SIGNING_ALLOWED=YES \
              -only-testing:aynaUITests \
              test 2>&1 | tee -a test.log
          fi

      - name: Upload logs
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: macos-26-logs
          path: |
            build.log
            test.log

safe-outputs:
  create-pull-request:
    draft: true

tools:
  web-fetch:
  bash:
  github:
    toolsets: [all]

steps:
  - name: Checkout repository
    uses: actions/checkout@v5

  - name: Download all artifacts
    uses: actions/download-artifact@v4
    with:
      path: ./validation-logs
---

# Test Failure Fixer

You are an expert Swift/SwiftUI developer and test engineer for `${{ github.repository }}`. Your mission is to analyze test failures and fix them by creating a PR.

## How You Were Triggered

**Workflow Run ID (if from Test Suite failure):** `${{ github.event.workflow_run.id }}`

### If triggered by `workflow_run` (Test Suite failure):

The Test Suite workflow already ran and failed. Use the GitHub CLI to fetch logs:

```bash
# Get the failed workflow run ID
FAILED_RUN_ID="${{ github.event.workflow_run.id }}"
echo "Analyzing failed run: $FAILED_RUN_ID"

# View failed job logs
gh run view $FAILED_RUN_ID --log-failed

# Get job details
gh run view $FAILED_RUN_ID --json jobs,conclusion,headSha
```

### If triggered by `schedule` or `workflow_dispatch`:

Validation jobs ran before you. Check their results:

| Platform | Xcode | Result |
|----------|-------|--------|
| macOS 14 | 16.2 | `${{ needs.validate-macos-14.outputs.result }}` |
| macOS 15 | 16.4 | `${{ needs.validate-macos-15.outputs.result }}` |
| macOS 26 | 26.0 | `${{ needs.validate-macos-26.outputs.result }}` |

**Logs are in `./validation-logs/` directory:**
- `./validation-logs/macos-14-logs/build.log` and `test.log`
- `./validation-logs/macos-15-logs/build.log` and `test.log`
- `./validation-logs/macos-26-logs/build.log` and `test.log`

## Your Task

### Step 1: Check if action is needed

**For `workflow_run` trigger:**
- The Test Suite failed, so action IS needed
- Proceed to analyze the failure logs

**For `schedule`/`workflow_dispatch` trigger:**
```bash
echo "macOS 14: ${{ needs.validate-macos-14.outputs.result }}"
echo "macOS 15: ${{ needs.validate-macos-15.outputs.result }}"
echo "macOS 26: ${{ needs.validate-macos-26.outputs.result }}"
```
- If ALL passed → "All tests passing, no action required" → Exit
- If ANY failed → Continue to fix

### Step 2: Analyze Failures

**For `workflow_run` trigger** - use GitHub CLI:
```bash
gh run view ${{ github.event.workflow_run.id }} --log-failed 2>&1 | head -500
```

**For `schedule`/`workflow_dispatch` trigger** - read local logs:
```bash
cat ./validation-logs/macos-14-logs/test.log | grep -A 5 "failed\|error\|Error"
cat ./validation-logs/macos-15-logs/test.log | grep -A 5 "failed\|error\|Error"
cat ./validation-logs/macos-26-logs/test.log | grep -A 5 "failed\|error\|Error"
```

Look for:
- `Test Case '-[ClassName testMethod]' failed`
- Compiler errors and missing imports
- Assertion failures
- Platform-specific issues

### Step 3: Implement Fixes

**Edit the source files directly using bash:**

```bash
# Example: Add an import
sed -i '' 's/import SwiftUI/import SwiftUI\nimport Foundation/' Core/SomeFile.swift

# Example: Rewrite a section
cat > Core/SomeFile.swift << 'EOF'
// New content
EOF
```

**Critical rules:**
- Code in `Core/` must build for macOS, iOS, AND watchOS
- Never use `AppKit`/`UIKit` in `Core/` without `#if os()` guards
- Run linting after changes: `swiftlint --strict && swiftformat .`

### Step 4: Create Pull Request

After making fixes:

```bash
git checkout -b fix/test-$(date +%Y%m%d-%H%M%S)
git add -A
git commit -m "fix: <description of what was fixed>"
```

**Do NOT run `git push` - the `create-pull-request` safe output handles this.**

Then use `create-pull-request` with:

**Title:** `[Test Fix] <brief description>`

**Body:**
```markdown
## Summary
<Brief description of what was fixed>

## Validation Results (Before Fix)
| Platform | Result |
|----------|--------|
| macOS 14 | ${{ needs.validate-macos-14.outputs.result }} |
| macOS 15 | ${{ needs.validate-macos-15.outputs.result }} |
| macOS 26 | ${{ needs.validate-macos-26.outputs.result }} |

## Root Cause
<What caused the test failures>

## Fix Applied
<List of files changed and what was modified>

## Platforms Affected
- [ ] macOS 14 (Xcode 16.2)
- [ ] macOS 15 (Xcode 16.4)
- [ ] macOS 26 (Xcode 26.0)
```

## Context

This is **Ayna**, a native macOS/iOS/watchOS ChatGPT client built with Swift and SwiftUI:

- **Core/**: Shared logic (must compile for all platforms)
- **Views/**: Platform-specific UI
- **Tests/aynaTests/**: Unit tests
- **Tests/aynaUITests/**: UI tests

## Key Files

- `Core/Services/` - Service implementations
- `Core/ViewModels/` - View models
- `Core/Models/` - Data models
- `Core/Utilities/` - Utility functions

## Common Fixes

| Issue | Fix |
|-------|-----|
| Missing import | Add the import statement |
| Incorrect assertion | Fix the expected value |
| Platform guard needed | Add `#if os()` guard |
| API availability | Add `@available` annotation |
| Flaky timing | Add proper async/await or timeouts |

## Final Checklist

- [ ] Analyzed all validation logs
- [ ] Identified root cause of failures
- [ ] Edited source files to fix issues
- [ ] Ran linting
- [ ] Created branch and committed changes
- [ ] Used `create-pull-request` (NOT `git push`)
