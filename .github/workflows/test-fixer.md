---
description: |
  This workflow monitors unit and UI test failures across macOS 14, 15, and 26,
  investigates the root cause, and automatically creates draft PRs to fix the issues.
  It triggers when the Test Suite workflow fails on main branch.
  
  CRITICAL: The agent MUST edit source files and create pull requests.
  The agent MUST NOT create issues describing fixes - it must implement the fixes.
  Use bash tools (sed, cat) to edit files, then git to commit, then create-pull-request.

on:
  workflow_run:
    workflows: ["Test Suite"]
    types: [completed]
    branches:
      - main
  workflow_dispatch:
    inputs:
      run_id:
        description: 'Workflow run ID to investigate (optional)'
        required: false
        type: string
  pull_request:
    types: [labeled]
    names: ["fix-tests"]

timeout-minutes: 45

permissions:
  contents: read
  actions: read
  checks: read
  discussions: read
  issues: read
  pull-requests: read
  repository-projects: read
  security-events: read
  id-token: write

network: defaults

engine:
  id: copilot
  model: claude-opus-4.5

safe-outputs:
  create-pull-request:
    draft: true
  jobs:
    validate-macos-14:
      description: "Build and test the proposed fix on macOS 14 with Xcode 16.2"
      runs-on: macos-14
      output: "Validation completed on macOS 14"
      permissions:
        contents: read
      inputs:
        test_target:
          description: "Which test target to run. Valid values: aynaTests, aynaUITests, both"
          required: true
          type: string
        failed_tests:
          description: "Comma-separated list of specific failed test names to re-run (optional)"
          required: false
          type: string
      steps:
        - name: Checkout with agent changes
          uses: actions/checkout@v5
          with:
            ref: ${{ github.head_ref || github.ref }}

        - name: Select Xcode 16.2
          run: sudo xcode-select -s /Applications/Xcode_16.2.app/Contents/Developer

        - name: Show Xcode version
          run: xcodebuild -version

        - name: Build project
          run: |
            set -o pipefail
            echo "=== Building macOS target (macOS 14 / Xcode 16.2) ===" | tee -a $GITHUB_STEP_SUMMARY
            xcodebuild \
              -project ayna.xcodeproj \
              -scheme Ayna \
              -destination 'platform=macOS' \
              -derivedDataPath ./build \
              CODE_SIGN_IDENTITY="" \
              CODE_SIGNING_REQUIRED=NO \
              CODE_SIGNING_ALLOWED=NO \
              build 2>&1 | tee build.log | tail -100
            echo "✅ Build succeeded on macOS 14" | tee -a $GITHUB_STEP_SUMMARY

        - name: Run unit tests
          if: inputs.test_target == 'aynaTests' || inputs.test_target == 'both'
          run: |
            set -o pipefail
            echo "=== Running unit tests (macOS 14) ===" | tee -a $GITHUB_STEP_SUMMARY
            TEST_ARGS=""
            if [ -n "${{ inputs.failed_tests }}" ]; then
              for test in $(echo "${{ inputs.failed_tests }}" | tr ',' ' '); do
                TEST_ARGS="$TEST_ARGS -only-testing:aynaTests/$test"
              done
            else
              TEST_ARGS="-only-testing:aynaTests"
            fi
            xcodebuild \
              -project ayna.xcodeproj \
              -scheme Ayna \
              -destination 'platform=macOS' \
              -derivedDataPath ./build \
              CODE_SIGN_IDENTITY="" \
              CODE_SIGNING_REQUIRED=NO \
              CODE_SIGNING_ALLOWED=NO \
              $TEST_ARGS \
              test 2>&1 | tee test.log | tail -100
            echo "✅ Unit tests passed on macOS 14" | tee -a $GITHUB_STEP_SUMMARY

        - name: Run UI tests
          if: inputs.test_target == 'aynaUITests' || inputs.test_target == 'both'
          run: |
            set -o pipefail
            echo "=== Running UI tests (macOS 14) ===" | tee -a $GITHUB_STEP_SUMMARY
            TEST_ARGS=""
            if [ -n "${{ inputs.failed_tests }}" ]; then
              for test in $(echo "${{ inputs.failed_tests }}" | tr ',' ' '); do
                TEST_ARGS="$TEST_ARGS -only-testing:aynaUITests/$test"
              done
            else
              TEST_ARGS="-only-testing:aynaUITests"
            fi
            xcodebuild \
              -project ayna.xcodeproj \
              -scheme Ayna \
              -destination 'platform=macOS' \
              -derivedDataPath ./build \
              CODE_SIGN_IDENTITY="-" \
              CODE_SIGNING_REQUIRED=YES \
              CODE_SIGNING_ALLOWED=YES \
              $TEST_ARGS \
              test 2>&1 | tee uitest.log | tail -100
            echo "✅ UI tests passed on macOS 14" | tee -a $GITHUB_STEP_SUMMARY

        - name: Summary
          if: always()
          run: |
            echo "=== macOS 14 Validation Summary ===" | tee -a $GITHUB_STEP_SUMMARY
            if [ -f build.log ]; then tail -20 build.log | tee -a $GITHUB_STEP_SUMMARY; fi
            if [ -f test.log ]; then tail -20 test.log | tee -a $GITHUB_STEP_SUMMARY; fi

    validate-macos-15:
      description: "Build and test the proposed fix on macOS 15 with Xcode 16.4"
      runs-on: macos-15
      output: "Validation completed on macOS 15"
      permissions:
        contents: read
      inputs:
        test_target:
          description: "Which test target to run. Valid values: aynaTests, aynaUITests, both"
          required: true
          type: string
        failed_tests:
          description: "Comma-separated list of specific failed test names to re-run (optional)"
          required: false
          type: string
      steps:
        - name: Checkout with agent changes
          uses: actions/checkout@v5
          with:
            ref: ${{ github.head_ref || github.ref }}

        - name: Select Xcode 16.4
          run: sudo xcode-select -s /Applications/Xcode_16.4.app/Contents/Developer

        - name: Show Xcode version
          run: xcodebuild -version

        - name: Build project
          run: |
            set -o pipefail
            echo "=== Building macOS target (macOS 15 / Xcode 16.4) ===" | tee -a $GITHUB_STEP_SUMMARY
            xcodebuild \
              -project ayna.xcodeproj \
              -scheme Ayna \
              -destination 'platform=macOS' \
              -derivedDataPath ./build \
              CODE_SIGN_IDENTITY="" \
              CODE_SIGNING_REQUIRED=NO \
              CODE_SIGNING_ALLOWED=NO \
              build 2>&1 | tee build.log | tail -100
            echo "✅ Build succeeded on macOS 15" | tee -a $GITHUB_STEP_SUMMARY

        - name: Run unit tests
          if: inputs.test_target == 'aynaTests' || inputs.test_target == 'both'
          run: |
            set -o pipefail
            echo "=== Running unit tests (macOS 15) ===" | tee -a $GITHUB_STEP_SUMMARY
            TEST_ARGS=""
            if [ -n "${{ inputs.failed_tests }}" ]; then
              for test in $(echo "${{ inputs.failed_tests }}" | tr ',' ' '); do
                TEST_ARGS="$TEST_ARGS -only-testing:aynaTests/$test"
              done
            else
              TEST_ARGS="-only-testing:aynaTests"
            fi
            xcodebuild \
              -project ayna.xcodeproj \
              -scheme Ayna \
              -destination 'platform=macOS' \
              -derivedDataPath ./build \
              CODE_SIGN_IDENTITY="" \
              CODE_SIGNING_REQUIRED=NO \
              CODE_SIGNING_ALLOWED=NO \
              $TEST_ARGS \
              test 2>&1 | tee test.log | tail -100
            echo "✅ Unit tests passed on macOS 15" | tee -a $GITHUB_STEP_SUMMARY

        - name: Run UI tests
          if: inputs.test_target == 'aynaUITests' || inputs.test_target == 'both'
          run: |
            set -o pipefail
            echo "=== Running UI tests (macOS 15) ===" | tee -a $GITHUB_STEP_SUMMARY
            TEST_ARGS=""
            if [ -n "${{ inputs.failed_tests }}" ]; then
              for test in $(echo "${{ inputs.failed_tests }}" | tr ',' ' '); do
                TEST_ARGS="$TEST_ARGS -only-testing:aynaUITests/$test"
              done
            else
              TEST_ARGS="-only-testing:aynaUITests"
            fi
            xcodebuild \
              -project ayna.xcodeproj \
              -scheme Ayna \
              -destination 'platform=macOS' \
              -derivedDataPath ./build \
              CODE_SIGN_IDENTITY="-" \
              CODE_SIGNING_REQUIRED=YES \
              CODE_SIGNING_ALLOWED=YES \
              $TEST_ARGS \
              test 2>&1 | tee uitest.log | tail -100
            echo "✅ UI tests passed on macOS 15" | tee -a $GITHUB_STEP_SUMMARY

        - name: Summary
          if: always()
          run: |
            echo "=== macOS 15 Validation Summary ===" | tee -a $GITHUB_STEP_SUMMARY
            if [ -f build.log ]; then tail -20 build.log | tee -a $GITHUB_STEP_SUMMARY; fi
            if [ -f test.log ]; then tail -20 test.log | tee -a $GITHUB_STEP_SUMMARY; fi

    validate-macos-26:
      description: "Build and test the proposed fix on macOS 26 with Xcode 26.0"
      runs-on: macos-26
      output: "Validation completed on macOS 26"
      permissions:
        contents: read
      inputs:
        test_target:
          description: "Which test target to run. Valid values: aynaTests, aynaUITests, both"
          required: true
          type: string
        failed_tests:
          description: "Comma-separated list of specific failed test names to re-run (optional)"
          required: false
          type: string
      steps:
        - name: Checkout with agent changes
          uses: actions/checkout@v5
          with:
            ref: ${{ github.head_ref || github.ref }}

        - name: Select Xcode 26.0
          run: sudo xcode-select -s /Applications/Xcode_26.0.app/Contents/Developer

        - name: Show Xcode version
          run: xcodebuild -version

        - name: Build project
          run: |
            set -o pipefail
            echo "=== Building macOS target (macOS 26 / Xcode 26.0) ===" | tee -a $GITHUB_STEP_SUMMARY
            xcodebuild \
              -project ayna.xcodeproj \
              -scheme Ayna \
              -destination 'platform=macOS' \
              -derivedDataPath ./build \
              CODE_SIGN_IDENTITY="" \
              CODE_SIGNING_REQUIRED=NO \
              CODE_SIGNING_ALLOWED=NO \
              build 2>&1 | tee build.log | tail -100
            echo "✅ Build succeeded on macOS 26" | tee -a $GITHUB_STEP_SUMMARY

        - name: Run unit tests
          if: inputs.test_target == 'aynaTests' || inputs.test_target == 'both'
          run: |
            set -o pipefail
            echo "=== Running unit tests (macOS 26) ===" | tee -a $GITHUB_STEP_SUMMARY
            TEST_ARGS=""
            if [ -n "${{ inputs.failed_tests }}" ]; then
              for test in $(echo "${{ inputs.failed_tests }}" | tr ',' ' '); do
                TEST_ARGS="$TEST_ARGS -only-testing:aynaTests/$test"
              done
            else
              TEST_ARGS="-only-testing:aynaTests"
            fi
            xcodebuild \
              -project ayna.xcodeproj \
              -scheme Ayna \
              -destination 'platform=macOS' \
              -derivedDataPath ./build \
              CODE_SIGN_IDENTITY="" \
              CODE_SIGNING_REQUIRED=NO \
              CODE_SIGNING_ALLOWED=NO \
              $TEST_ARGS \
              test 2>&1 | tee test.log | tail -100
            echo "✅ Unit tests passed on macOS 26" | tee -a $GITHUB_STEP_SUMMARY

        - name: Run UI tests
          if: inputs.test_target == 'aynaUITests' || inputs.test_target == 'both'
          run: |
            set -o pipefail
            echo "=== Running UI tests (macOS 26) ===" | tee -a $GITHUB_STEP_SUMMARY
            TEST_ARGS=""
            if [ -n "${{ inputs.failed_tests }}" ]; then
              for test in $(echo "${{ inputs.failed_tests }}" | tr ',' ' '); do
                TEST_ARGS="$TEST_ARGS -only-testing:aynaUITests/$test"
              done
            else
              TEST_ARGS="-only-testing:aynaUITests"
            fi
            xcodebuild \
              -project ayna.xcodeproj \
              -scheme Ayna \
              -destination 'platform=macOS' \
              -derivedDataPath ./build \
              CODE_SIGN_IDENTITY="-" \
              CODE_SIGNING_REQUIRED=YES \
              CODE_SIGNING_ALLOWED=YES \
              $TEST_ARGS \
              test 2>&1 | tee uitest.log | tail -100
            echo "✅ UI tests passed on macOS 26" | tee -a $GITHUB_STEP_SUMMARY

        - name: Summary
          if: always()
          run: |
            echo "=== macOS 26 Validation Summary ===" | tee -a $GITHUB_STEP_SUMMARY
            if [ -f build.log ]; then tail -20 build.log | tee -a $GITHUB_STEP_SUMMARY; fi
            if [ -f test.log ]; then tail -20 test.log | tee -a $GITHUB_STEP_SUMMARY; fi

tools:
  web-fetch:
  bash:
  github:
    toolsets: [all]

steps:
  - name: Checkout repository
    uses: actions/checkout@v5
---

# Test Failure Fixer

You are an expert Swift/SwiftUI developer and test engineer for `${{ github.repository }}`. Your mission is to automatically investigate and fix test failures in unit tests and UI tests across macOS 14, 15, and 26.

## ⛔ ABSOLUTE RULE - READ THIS FIRST ⛔

**YOU MUST CREATE A PULL REQUEST WITH CODE CHANGES.**

- ✅ Use file editing tools (bash with sed/cat, or file write operations) to modify code
- ✅ Use `git` commands to create a branch and commit
- ✅ Use `create-pull-request` to submit your fix

**The only acceptable output is a Pull Request with actual code changes committed.**

## Context

This is a native macOS/iOS/watchOS ChatGPT client built with Swift and SwiftUI called **Ayna**. The project has:

- **Core/**: Shared logic that must compile for all platforms (macOS, iOS, watchOS)
- **Views/**: Platform-specific UI code
- **Tests/aynaTests/**: Unit tests
- **Tests/aynaUITests/**: UI tests for macOS

The test matrix includes:
- **macOS 14** with Xcode 16.2
- **macOS 15** with Xcode 16.4
- **macOS 26** with Xcode 26.0

## Your Task

When the Test Suite workflow fails, you MUST follow this EXACT sequence:

1. **Investigate** - Analyze workflow logs to identify root cause
2. **EDIT FILES** - Use bash/cat/sed to modify the actual source code files
3. **COMMIT** - Create a branch, add files, and commit changes
4. **CREATE PR** - Use `create-pull-request` to submit your fix

**You MUST edit files and create a PR. There is no other option.**

## Investigation Protocol

### Phase 1: Gather Failure Information

1. **Get workflow run information**:
   - If triggered by `workflow_run`, use run ID: `${{ github.event.workflow_run.id }}`
   - If triggered manually, use input run ID: `${{ github.event.inputs.run_id }}`
   - If neither available, find the most recent failed run of "Test Suite" workflow

2. **Download and analyze logs** using the GitHub CLI:
   ```bash
   gh run view <run_id> --log-failed
   gh run view <run_id> --json jobs,conclusion,headSha
   ```

3. **Identify which jobs failed**:
   - `unit_tests (macos-14, ...)` - Unit tests on macOS 14
   - `unit_tests (macos-15, ...)` - Unit tests on macOS 15
   - `unit_tests (macos-26, ...)` - Unit tests on macOS 26
   - `ui_tests (macos-14, ...)` - UI tests on macOS 14
   - `ui_tests (macos-15, ...)` - UI tests on macOS 15
   - `ui_tests (macos-26, ...)` - UI tests on macOS 26

### Phase 2: Root Cause Analysis

Analyze the failure logs to identify:

1. **Test failures**: Which specific tests failed?
   - Look for `Test Case '-[ClassName testMethod]' failed`
   - Look for assertion failures and their messages
   - Look for XCTest error messages

2. **Build failures**: Did the code fail to compile?
   - Look for compiler errors in Swift code
   - Check for missing imports or undefined symbols
   - Check for API availability issues across macOS versions

3. **Platform-specific issues**: Is the failure specific to one macOS version?
   - macOS 26 has new APIs that may cause issues
   - macOS 14 may lack newer APIs
   - Check for `#available` or `@available` issues

4. **Common failure patterns**:
   - **Flaky tests**: Timing issues, race conditions
   - **UI test failures**: Element not found, accessibility issues
   - **API deprecations**: Using deprecated APIs in newer Xcode
   - **Code signing**: Issues with CODE_SIGN_IDENTITY settings
   - **Simulator issues**: Simulator boot failures, device not available

### Phase 3: Fix Implementation

**⛔ THIS IS WHERE YOU MUST EDIT FILES - NOT DESCRIBE WHAT TO EDIT ⛔**

You have bash available. Use it to edit files directly:

```bash
# Example: Add an import to a Swift file
sed -i '' 's/import SwiftUI/import SwiftUI\n#if os(iOS)\nimport UIKit\n#endif/' Core/Utilities/SomeFile.swift

# Example: Use cat to rewrite a file section
cat > Core/Utilities/SomeFile.swift << 'EOF'
// New file contents here
EOF

# Example: Append to a file
cat >> Core/Utilities/SomeFile.swift << 'EOF'
// Additional code here
EOF
```

Based on your analysis, **ACTUALLY EDIT** the files:

1. **For test failures**:
   - Edit test files to fix incorrect assertions
   - Add proper async/await handling
   - Add timeouts for UI tests
   - Fix accessibility identifiers
   - Add `#if os()` guards for platform-specific code

2. **For build failures**:
   - Edit source files to fix compiler errors
   - Add missing imports
   - Add `@available` annotations for newer APIs
   - Add fallback implementations for older platforms

3. **For platform compatibility**:
   - Use `#if os(macOS)` guards appropriately
   - Use `@available(macOS 14, *)` or similar annotations
   - Provide fallback implementations

4. **After making changes**:
   - Run linting: `swiftlint --strict && swiftformat .`
   - Commit your changes to a new branch
   - Create a PR with your fixes

5. **Critical rules from AGENTS.md**:
   - Code in `Core/` must build for macOS, iOS, AND watchOS
   - Never use `AppKit`/`UIKit` in `Core/` without `#if os()` guards

**⛔ REMINDER: You must have ACTUALLY EDITED files before proceeding. If you haven't run any file-editing commands yet, go back and do that NOW.**

### Phase 4: Validation on macOS (OPTIONAL - Skip if confident)

**CRITICAL: Each validation job can only be called ONCE. Do NOT call them iteratively.**

You have three validation tools available:

| Tool | Runner | Xcode |
|------|--------|-------|
| `validate-macos-14` | macOS 14 | Xcode 16.2 |
| `validate-macos-15` | macOS 15 | Xcode 16.4 |
| `validate-macos-26` | macOS 26 | Xcode 26.0 |

**Workflow:**
1. Make ALL your code fixes FIRST
2. Only THEN call validation jobs (once each) to verify
3. If validation fails, create an issue instead of trying again

**When to use validation:**
- Use validation when you want extra confidence before creating a PR
- Skip validation if the fix is straightforward (e.g., simple typo, obvious assertion fix)
- The PR will be validated by CI anyway after creation

**If you do validate:**
- Call each job only ONCE with `test_target` set to `aynaTests`, `aynaUITests`, or `both`
- If validation fails, proceed to create the PR anyway (CI will catch issues) OR create an issue

**Example:**
```
# After making all fixes, validate once:
Call validate-macos-14 with: test_target: "aynaTests"
Call validate-macos-15 with: test_target: "aynaTests"
Call validate-macos-26 with: test_target: "aynaTests"
```

### Phase 5: Create Pull Request

**⛔ MANDATORY: You MUST have edited files before this step. If you haven't, go back to Phase 3.**

**After implementing your fixes (i.e., after running file-editing commands), create a PR:**

1. **Create a branch and commit** with your changes:
   ```bash
   git checkout -b fix/test-<short-description>
   git add -A
   git commit -m "fix: <description of the fix>"
   ```
   
   **IMPORTANT: Do NOT run `git push`. The `create-pull-request` safe output will handle pushing for you.**

2. **Create a Pull Request** using `create-pull-request` safe output with:
   - **Title**: `[Test Fix] <brief description>`
   - **Body**: Include root cause, fix applied, platforms affected, and link to failed run

3. **PR description template**:
   ```markdown
   ## Summary
   <Brief description of what was fixed>

   ## Root Cause
   <What caused the test failure>

   ## Fix Applied
   <List of files changed and what was modified>

   ## Platforms Affected
   - [ ] macOS 14 (Xcode 16.2)
   - [ ] macOS 15 (Xcode 16.4)
   - [ ] macOS 26 (Xcode 26.0)

   ## Related
   - Failed workflow run: <link>
   ```

**Use `create-pull-request` to submit your fix.**

## Common Test File Locations

- Unit tests: `Tests/aynaTests/`
- macOS UI tests: `Tests/aynaUITests/`
- iOS tests: `Tests/Ayna-iOSTests/` and `Tests/Ayna-iOSUITests/`
- watchOS UI tests: `Tests/Ayna-watchOSUITests/`

## Key Files to Check

- `Core/Services/` - Service implementations often tested
- `Core/ViewModels/` - View models with business logic
- `Core/Models/` - Data models and parsing
- `Core/Utilities/` - Utility functions and helpers

## Output Requirements

### ✅ REQUIRED: Creating Pull Requests

**Your ONLY output is a Pull Request with actual code changes.**

You must:
1. Edit the actual source files using bash/sed/cat
2. Commit your changes to a new branch
3. Use `create-pull-request` to submit

### Required Actions:

1. **Analyze ALL failed jobs** from the workflow run across the entire matrix:
   - `unit_tests (macos-14, ...)` 
   - `unit_tests (macos-15, ...)`
   - `unit_tests (macos-26, ...)`
   - `ui_tests (macos-14, ...)`
   - `ui_tests (macos-15, ...)`
   - `ui_tests (macos-26, ...)`

2. **EDIT the actual source files using bash commands**:
   - Use `sed -i ''` to make targeted replacements
   - Use `cat > file << 'EOF'` to rewrite files
   - Use `cat >> file << 'EOF'` to append to files
   - Run linting after changes: `swiftlint --strict && swiftformat .`

3. **Create a branch and commit your changes**:
   ```bash
   git checkout -b fix/test-<short-description>
   git add -A
   git commit -m "fix: <description of the fix>"
   ```
   
   **Do NOT run `git push` - the `create-pull-request` safe output handles this.**

4. **Use `create-pull-request`**:
   - Explanation of the fix you implemented
   - Link to the failed workflow run

### PR description must include:
- **Failures Found**: List of all test failures across the matrix
- **Root Cause**: What caused the test failures
- **Fix Applied**: What code changes were made (file names and brief description)
- **Platforms Affected**: Which macOS versions had the issue
- **Related Run**: Link to the failed workflow run

### Common Fixes (all require PRs)

- Missing imports → Edit the file, add the import, create PR
- Incorrect assertions → Edit the test file, fix the assertion, create PR
- Platform guards needed → Edit the file, add `#if os()`, create PR
- API availability issues → Edit the file, add `@available`, create PR

## Important Guidelines

- **ALWAYS implement the fix**: Don't just describe what should be done - do it
- **Don't break other platforms**: Changes to `Core/` must work on all platforms
- **Be conservative**: Make minimal changes needed to fix the issue
- **Document changes**: Add comments explaining platform-specific workarounds
- **Don't skip tests**: Fix tests rather than disabling them
- **Preserve test coverage**: Ensure fixes don't reduce test effectiveness

## Final Checklist Before Completion

Before you finish, verify:
- [ ] Did you run bash commands to EDIT actual source files?
- [ ] Did you run `git add` and `git commit`?
- [ ] Are you using `create-pull-request`? (Do NOT run `git push` - the safe output handles it)

If any answer is NO, go back and complete those steps.
