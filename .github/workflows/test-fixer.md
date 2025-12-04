---
description: |
  This workflow monitors unit and UI test failures across macOS 14, 15, and 26,
  investigates the root cause, and automatically creates draft PRs to fix the issues.
  It triggers when the Test Suite workflow fails on main branch.

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
  create-issue:
    title-prefix: "[Test Fix]"
    labels: ["test-failure", "automated"]
    max: 1
  add-comment:
    target: "*"
    max: 3
  create-pull-request:
    title-prefix: "[Test Fix]"
    labels: ["test-fix", "automated"]
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
          description: "Which test target to run (aynaTests or aynaUITests)"
          required: true
          type: choice
          options: ["aynaTests", "aynaUITests", "both"]
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
          description: "Which test target to run (aynaTests or aynaUITests)"
          required: true
          type: choice
          options: ["aynaTests", "aynaUITests", "both"]
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
          description: "Which test target to run (aynaTests or aynaUITests)"
          required: true
          type: choice
          options: ["aynaTests", "aynaUITests", "both"]
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

When the Test Suite workflow fails, you need to:

1. **Investigate the failure** by analyzing workflow logs and identifying the root cause
2. **Fix the issue** by modifying the relevant code or tests
3. **Create a draft PR** with your fixes

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

Based on your analysis, implement fixes:

1. **For test failures**:
   - Fix incorrect assertions
   - Add proper async/await handling
   - Add timeouts for UI tests
   - Fix accessibility identifiers
   - Add `#if os()` guards for platform-specific code

2. **For build failures**:
   - Fix compiler errors
   - Add missing imports
   - Add `@available` annotations for newer APIs
   - Add fallback implementations for older platforms

3. **For platform compatibility**:
   - Use `#if os(macOS)` guards appropriately
   - Use `@available(macOS 14, *)` or similar annotations
   - Provide fallback implementations

4. **Critical rules from AGENTS.md**:
   - Code in `Core/` must build for macOS, iOS, AND watchOS
   - Never use `AppKit`/`UIKit` in `Core/` without `#if os()` guards
   - Run linting: `swiftlint --strict && swiftformat .` after changes

### Phase 4: Validation on macOS (REQUIRED!)

**You MUST validate your fixes on the affected macOS version(s) before creating a PR.** You have three validation tools available:

| Tool | Runner | Xcode |
|------|--------|-------|
| `validate-macos-14` | macOS 14 | Xcode 16.2 |
| `validate-macos-15` | macOS 15 | Xcode 16.4 |
| `validate-macos-26` | macOS 26 | Xcode 26.0 |

1. **Identify which platform(s) failed** from the original test failure logs

2. **Call the appropriate validation job(s)** for each failed platform:
   - Set `test_target` to the appropriate target:
     - `aynaTests` for unit test failures
     - `aynaUITests` for UI test failures  
     - `both` if both types of tests failed
   - Set `failed_tests` to the specific test names that failed (comma-separated), or leave empty to run all tests in the target

3. **Validate on ALL affected platforms**:
   - If macOS 14 failed → call `validate-macos-14`
   - If macOS 15 failed → call `validate-macos-15`
   - If macOS 26 failed → call `validate-macos-26`
   - If multiple platforms failed → call multiple validation jobs

4. **Check the validation results**:
   - If ALL validations **pass**: Proceed to create the PR
   - If ANY validation **fails**: Analyze the new errors, iterate on your fix, and validate again
   - Maximum 3 validation attempts per platform before creating an issue instead

5. **Example for multi-platform failure**:
   ```
   # If tests failed on macOS 14 and macOS 26:
   
   Call validate-macos-14 with:
   - test_target: "aynaTests"
   - failed_tests: "MessageTests/testMessageParsing"
   
   Call validate-macos-26 with:
   - test_target: "aynaTests"
   - failed_tests: "MessageTests/testMessageParsing"
   ```

This ensures your fix works across all affected macOS versions before submitting.

### Phase 5: Create Pull Request

1. **Create a descriptive branch** starting with `fix/test-`:
   ```
   fix/test-<short-description>
   ```

2. **Write a clear PR description** including:
   - **Root Cause**: What caused the test failure
   - **Fix Applied**: What changes were made
   - **Platforms Affected**: Which macOS versions had the issue
   - **Testing**: How the fix was verified
   - **Related Run**: Link to the failed workflow run

3. **Request review** from maintainers for non-trivial changes

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

### If you successfully fix the issue:
1. Create a **draft pull request** with the fix
2. Include a clear explanation of what was broken and how you fixed it
3. Tag the PR with `test-fix` and `automated` labels

### If you cannot fix the issue:
1. Create an **issue** documenting:
   - The failure details
   - Your investigation findings
   - Why automated fixing wasn't possible
   - Suggestions for manual resolution
2. Tag the issue with `test-failure` and `needs-investigation`

### If the failure is a known flaky test:
1. Add a comment to any existing issue about the flaky test
2. Consider adding retry logic or `XCTExpectFailure` as appropriate

## Important Guidelines

- **Don't break other platforms**: Changes to `Core/` must work on all platforms
- **Be conservative**: Make minimal changes needed to fix the issue
- **Document changes**: Add comments explaining platform-specific workarounds
- **Don't skip tests**: Fix tests rather than disabling them
- **Preserve test coverage**: Ensure fixes don't reduce test effectiveness
