# Jenkins → GHA construct mapping

Read the whole `Jenkinsfile` before starting a translation — later stages
often reference environment set up in earlier ones, and a `post {}` block at
the bottom can change how you'd write the steps above it (e.g. a step that
looks like it should `exit 1` on failure might actually be expected to let
`post { failure {} }` handle the response).

## Structural

| Jenkins | GHA | Notes |
|---|---|---|
| `pipeline { agent { label 'x' } }` | `runs-on: ...` | Don't reuse the Jenkins label as the GHA runner label — they're different systems. Confirm the intended runner in Step 4 of SKILL.md. |
| `agent any` | `runs-on: ubuntu-latest` (default assumption) | Confirm with the user; "any" in Jenkins often meant "whatever's free," which isn't a meaningful GHA equivalent. |
| `stages { stage('X') { steps { ... } } }` | one `jobs.<id>.steps` entry per stage, in the same job (or split into multiple `jobs:` if they were meant to run on different agents) | Keep the original order. |
| `environment { FOO = 'bar' }` | `env: { FOO: bar }` at the workflow, job, or step level (match the original scope) | A Jenkins credential-backed `environment` entry (see below) is different from a plain string. |
| `parameters { choice(...) / string(...) }` | `on.workflow_dispatch.inputs` | Jenkins build parameters become dispatch inputs; a scheduled/push-triggered run won't have them, so anything read from a parameter needs a sane default. |
| `triggers { cron('H 2 * * *') }` | `on.schedule: - cron: '...'` | GHA cron doesn't support Jenkins' `H` (hash) syntax for load-spreading — pick a concrete minute. |

## Credentials

```groovy
withCredentials([usernamePassword(credentialsId: 'db-creds', usernameVariable: 'DB_USER', passwordVariable: 'DB_PASS')]) {
  sh './migrate.sh'
}
```

→ the two values become two GitHub secrets, referenced through `env:` (never
inline `${{ secrets.* }}` into a `run:` string, same injection-safety rule as
`github.*`):

```yaml
- name: Migrate
  env:
    DB_USER: ${{ secrets.DB_USER }}
    DB_PASS: ${{ secrets.DB_PASS }}
  run: ./migrate.sh
```

If the Jenkins credential is a file (`file(credentialsId: ...)`) or an SSH key
(`sshUserPrivateKey(...)`), the GHA equivalent is usually writing the secret
to a temp file in the step before it's needed, then cleaning it up — there's
no direct 1:1 binding syntax.

## Parallel stages

```groovy
parallel {
  stage('Lint') { steps { sh 'npm run lint' } }
  stage('Typecheck') { steps { sh 'npm run typecheck' } }
}
```

Two reasonable GHA shapes, pick based on whether the parallel stages are
truly independent or share setup:

- **Separate jobs** (if they don't share expensive setup) — each gets its own
  `jobs.<id>` block; GHA runs jobs with no `needs:` dependency in parallel
  automatically.
- **A matrix** (if it's the same steps against different inputs) —
  `strategy.matrix` inside one job.

If the parallel stages share a build artifact (e.g. both need `node_modules`
installed first), that setup has to happen once and be passed via
`actions/upload-artifact` + `actions/download-artifact`, or the two jobs each
redo it — decide based on how expensive the shared step actually is.

## Post-build actions

```groovy
post {
  success { slackSend(...) }
  failure { slackSend(...) }
  always { junit 'reports/**/*.xml' }
}
```

→ GHA has no `post` block; each condition becomes a step-level `if:` at the
end of the job:

```yaml
- name: Notify success
  if: success()
  run: ...
- name: Notify failure
  if: failure()
  run: ...
- name: Publish test results
  if: always()
  uses: ...
```

`always()` steps still run after a job-cancelling timeout, matching Jenkins'
`always`.

## Conditional stages

```groovy
when { branch 'main' }
```

→ either an `if:` on the job/step (routed through `env:`, per SKILL.md Step
7), or scope the whole workflow with `on.push.branches: [main]` if *every*
stage in the pipeline was gated the same way.

## What doesn't translate mechanically

- **`@Library('shared-lib') _`** — Jenkins shared libraries live in their own
  repo and can define arbitrarily complex custom steps. Go read what the
  library actually does before proposing any mapping; don't guess from the
  call site alone.
- **Heavy Groovy scripting** (loops building dynamic stage lists, custom
  `class`/`def` blocks) — GHA's expression syntax is much more limited.
  Usually the right move is to replace the *dynamic* part with a small script
  (bash/node) that the workflow calls, rather than trying to port the Groovy
  logic into YAML expressions.
- **The `input` manual-approval step** — GHA's nearest equivalent is a
  [required reviewer on an
  Environment](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment),
  which is a repo/environment setting, not something expressible purely in
  the workflow YAML. Flag this as a one-time setup step for the user rather
  than something the workflow file alone can encode.
