---
description: |
  This workflow monitors unit and UI test failures and automatically creates draft PRs to fix them.
  
  Flow:
  1. Triggered by Test Suite workflow failure, schedule, or manually
  2. Agent analyzes test results (from triggering workflow or by running tests)
  3. If all tests pass, no action needed
  4. If any tests fail, agent creates a single PR to fix all failures
  
  The agent reuses the existing Test Suite workflow - no duplicate test definitions.

on:
  workflow_run:
    workflows: ["Test Suite"]
    types: [completed]
    branches:
      - main
  schedule:
    - cron: '0 6 * * *'  # Daily at 6 AM UTC
  workflow_dispatch:

timeout-minutes: 60

permissions:
  all: read
  id-token: write

network: defaults

engine:
  id: copilot
  model: claude-opus-4.5

safe-outputs:
  noop:
    max: 1

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

You are an expert Swift/SwiftUI developer and test engineer for `${{ github.repository }}`. Your mission is to analyze test failures and fix them by creating a PR.

## How You Were Triggered

**Workflow Run ID (if from Test Suite failure):** `${{ github.event.workflow_run.id }}`
**Workflow Run Conclusion:** `${{ github.event.workflow_run.conclusion }}`

## Your Task

### Step 1: Get Test Results

**If triggered by `workflow_run` (Test Suite completed):**

The Test Suite workflow already ran. Check if it failed:

```bash
# Check the workflow run that triggered us
WORKFLOW_RUN_ID="${{ github.event.workflow_run.id }}"
CONCLUSION="${{ github.event.workflow_run.conclusion }}"

echo "Test Suite Run ID: $WORKFLOW_RUN_ID"
echo "Conclusion: $CONCLUSION"

if [ "$CONCLUSION" = "success" ]; then
  echo "✅ All tests passed! No action needed."
  exit 0
fi

# Get details of the failed run
gh run view $WORKFLOW_RUN_ID --json jobs,conclusion,headSha
```

**If triggered by `schedule` or `workflow_dispatch`:**

Trigger the Test Suite and wait for results:

```bash
# Trigger the Test Suite workflow
echo "Triggering Test Suite workflow..."
gh workflow run tests.yml

# Wait a moment for workflow to start
sleep 10

# Get the run ID of the workflow we just triggered
RUN_ID=$(gh run list --workflow=tests.yml --limit=1 --json databaseId --jq '.[0].databaseId')
echo "Test Suite Run ID: $RUN_ID"

# Wait for it to complete (with timeout)
echo "Waiting for Test Suite to complete..."
gh run watch $RUN_ID --exit-status || true

# Check the conclusion
CONCLUSION=$(gh run view $RUN_ID --json conclusion --jq '.conclusion')
echo "Conclusion: $CONCLUSION"

if [ "$CONCLUSION" = "success" ]; then
  echo "✅ All tests passed! No action needed."
  exit 0
fi
```

### Step 2: Analyze Failures

Once you have a failed run ID, analyze the failures:

```bash
# View failed job logs
gh run view $RUN_ID --log-failed 2>&1 | head -1000

# Get detailed job information
gh run view $RUN_ID --json jobs --jq '.jobs[] | select(.conclusion == "failure") | {name: .name, conclusion: .conclusion}'
```

Look for:
- `Test Case '-[ClassName testMethod]' failed`
- Compiler errors and missing imports
- Assertion failures
- Platform-specific issues (macOS 14 vs 15 vs 26)

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

After making fixes, create a branch and commit locally:

```bash
BRANCH_NAME="fix/test-$(date +%Y%m%d-%H%M%S)"
git checkout -b "$BRANCH_NAME"
git add -A
git commit -m "fix: <description of what was fixed>"
```

**Push the branch and create the PR using the GitHub CLI:**

```bash
# Push the branch
git push origin "$BRANCH_NAME"

# Create a draft PR using gh CLI
gh pr create --draft \
  --title "[Test Fix] <brief description>" \
  --body "## Summary
<Brief description of what was fixed>

## Failed Test Suite Run
- Run ID: <run_id>
- URL: https://github.com/${{ github.repository }}/actions/runs/<run_id>

## Root Cause
<What caused the test failures>

## Fix Applied
<List of files changed and what was modified>

## Platforms Affected
- [ ] macOS 14 (Xcode 16.2)
- [ ] macOS 15 (Xcode 16.4)
- [ ] macOS 26 (Xcode 26.0)
- [ ] iOS
- [ ] watchOS"
```

**Then call the `noop` safe output** to log that the PR was created successfully, passing the PR URL in the message.

## Context

This is **Ayna**, a native macOS/iOS/watchOS ChatGPT client built with Swift and SwiftUI:

- **Core/**: Shared logic (must compile for all platforms)
- **Views/**: Platform-specific UI
- **Tests/aynaTests/**: macOS Unit tests
- **Tests/aynaUITests/**: macOS UI tests
- **Tests/Ayna-iOSTests/**: iOS Unit tests
- **Tests/Ayna-iOSUITests/**: iOS UI tests
- **Tests/Ayna-watchOSTests/**: watchOS Unit tests
- **Tests/Ayna-watchOSUITests/**: watchOS UI tests

## Test Matrix (from tests.yml)

| Platform | Versions | Xcode |
|----------|----------|-------|
| macOS | 14, 15, 26 | 16.2, 16.4, 26.0 |
| iOS | Simulator (iPhone 16/17) | 16.2, 16.4, 26.0 |
| watchOS | Simulator (Watch Ultra 2/3) | 16.2, 16.4, 26.0 |

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

- [ ] Got test results (from workflow_run or by triggering tests.yml)
- [ ] Analyzed failure logs
- [ ] Identified root cause
- [ ] Edited source files to fix issues
- [ ] Ran linting
- [ ] Created branch and committed changes locally
- [ ] Pushed branch and created draft PR using `gh pr create`
- [ ] Called `noop` safe output to confirm completion
