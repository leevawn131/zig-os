---
trigger: always_on
---

# 01 - Engineering Workflow & Change Management

## 1. Pre-Task Inspection Protocol
Before writing any code or initiating any system changes, every AI agent must:
1. Inspect `git status` to verify the working tree state and identify modified or untracked files.
2. Inspect `git branch` and verify the current active branch.
3. Inspect `git log -n 5` to understand recent commits and progress context.
4. Inspect affected modules, dependencies, and interfaces.
5. Create an implementation plan detailing risks, architectural alignment, and acceptance criteria.
6. Identify regression risks to previously verified subsystems.

## 2. Verification Labels & Evidence Mandate
Agents must never state a feature works without empirical test logs. Every status assertion must use one of the standard verification labels:
- `NOT IMPLEMENTED`: Feature does not exist or contains only signatures.
- `IMPLEMENTED`: Code written, pending compilation or test execution.
- `BUILD VERIFIED`: Successfully compiled with Zig 0.17.1 without warnings or errors.
- `UNIT TEST VERIFIED`: Host unit test executed and passed (`zig build test`).
- `QEMU VERIFIED`: Headless boot test passed with full serial log capture.
- `HARDWARE VERIFIED`: Verified on bare-metal physical machine.
- `PRODUCTION READY`: Thoroughly reviewed, fuzz-tested, and audited.

Passing compilation does **not** equal kernel correctness.
Passing a host unit test does **not** verify the freestanding kernel environment.

## 3. Git Operations & Safety Constraints
To maintain a safe, recoverable history, the following operations are strictly **PROHIBITED**:
- `git reset --hard` (destroys uncommitted work).
- `git clean -fd` (deletes untracked work).
- `git checkout -- .` or `git restore .` without human permission.
- Deleting unknown, untracked, or binary files (e.g. `zig.zip`).
- Overwriting user-authored modifications.
- History rewriting (`git commit --amend`, `git rebase -i`) on shared/published branches.
- Force pushing (`git push --force`).
- Automatic Git commits unless explicitly instructed by the user.

## 4. Failure Recovery Strategy
If a build, test, or QEMU run fails:
1. Capture the exact error log and exit status.
2. Formulate a root-cause hypothesis.
3. Apply targeted, incremental corrections.
4. Never run destructive cleanup commands to "reset" the workspace.
