## What and why

<!-- One paragraph. Link the issue/spec/ADR. -->

## Checks

- [ ] Title follows Conventional Commits; the PR is ≤400 changed lines (or the description says why it is larger)
- [ ] Behaviour changes have tests; no golden file was regenerated to make CI pass
- [ ] Every commit has one provenance trailer (`Agent-Session: <id>` or `Human-Authored: yes`)
- [ ] Adds a package, route, screen or public config option → labelled `scope-expanding`
- [ ] Cost of the agent run (tokens/$), if any:
