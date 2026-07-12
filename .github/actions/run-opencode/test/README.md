# run-opencode tests

`guard_test.sh` exercises provider usage, billing, quota, and zero-balance
detection against fixtures distilled from real OpenCode runs.

`direct_run_test.sh` verifies that CI uses non-interactive `opencode run`,
extracts a structured JSON review, and publishes only validated output.

Run both through the repository harness:

```bash
./script/test-review-automation.sh
```
