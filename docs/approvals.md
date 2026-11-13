# Approvals and team ownership

This page records how deployments get approved, and why. The approval rules live in Octopus, not in this repo, so this page is their written record. Update it whenever a rule, a tag set, or a tag on a project or environment changes.

The findings come from tests on November 9, 2026, with PT - Helm `1.2.19` from Development to Production on all three tenants.

For the pauses inside the deployment process, see [`database-migrations.md`](database-migrations.md) (rollbacks and the DBA review) and [`workflow-decisions.md`](workflow-decisions.md#aiassisted-release-field) (AI-assisted releases).

## Decisions

- **Ownership is a project tag.** `TeamOwner` names the team that owns a project. An approval rule matches the tag, so retagging a project changes who approves. No process edit is needed.
- **Team approvals use [Octopus Approvals](https://octopus.com/docs/approvals/octopus-approvals), not a process template or a policy.** Rules scope by project and environment tags, and their approvers are Octopus teams. A template would need a script that calls the API to read tags and team members. The trade-off: the rules aren't in Config as Code or Platform Hub, so this page records them.
- **Shared environments need the owner's approval.** `EnvironmentUsage/Shared` marks an environment that several teams use. Today that's Test.
- **Development stays untagged.** The release train deploys `main` to Development every hour as the `GHA-OIDC` service account. A rule there would stop the loop until a person approved it.
- **Owners can approve their own deploys.** Approvals has no "skip the rule when the deployer is on the owning team" setting. With self-approval allowed, an owner approves their own deploy and the approval is on record. Anyone else waits for an owner.
- **One change request per release.** Rules use `PerRelease`, so one approval covers every tenant. The manual interventions in the process still pause each tenant's task.
- **The AI-assisted review stays a manual intervention.** Approval rules can't read release custom fields, so they can't see `AIAssisted`. A change request asks "does the owner agree?". `Confirm AI-assisted release` asks "has someone reviewed the AI-written changes?".

## Tag sets

| Tag set | Applies to | Tags | Used by |
| --- | --- | --- | --- |
| `TeamOwner` | Projects, single select | `Payments`, `Checkout` | Rule 21 (`Payments`), rule 22 (`Checkout`) |
| `EnvironmentUsage` | Environments, single select | `Shared`, `Isolated` | Rules 21 and 22 (`Shared`) |
| `Change Approvals` | Projects, single select | `ProductionOnly`, `AllEnvs` | Rule 2 (`ProductionOnly`) |
| `Meta-Environment` | Environments, single select | `Nonproduction`, `Production` | Rule 2 (`Production`) |
| `ProjectStatus` | Projects, single select | `Onboarding`, `Active`, `Maintenance`, `Offboarding`, `Inactive` | No rule yet |

## What's tagged

| Environment | `EnvironmentUsage` | `Meta-Environment` |
| --- | --- | --- |
| Development | None | `Nonproduction` |
| Test | `Shared` | `Nonproduction` |
| Production | `Isolated` | `Production` |
| `pr-<n>` | None. Ephemeral environments have no tags | None |

| Project | `TeamOwner` | `Change Approvals` | `ProjectStatus` |
| --- | --- | --- | --- |
| PT - Helm | `Payments` | `ProductionOnly` | `Active` |
| PT - Kustomize | `Checkout` | `ProductionOnly` | `Active` |
| PT - Raw YAML | `Checkout` | `ProductionOnly` | `Active` |
| PT - Linux Package | `Payments` | `ProductionOnly` | `Active` |
| PT - Linux Package Streamlined | `Payments` | `ProductionOnly` | `Active`. It started with no tags. See [Setting up a new pipeline](#setting-up-a-new-pipeline) |

## Rules

| Rule | Scope | Approvers | Minimum | Self-approval | Tenants |
| --- | --- | --- | --- | --- | --- |
| `Shared Environment Approval - Payments` (`ApprovalRules-21`) | `TeamOwner/Payments` and `EnvironmentUsage/Shared` | Payments (`Teams-161`) | 1 | Allowed | `PerRelease` |
| `Shared Environment Approval - Checkout` (`ApprovalRules-22`) | `TeamOwner/Checkout` and `EnvironmentUsage/Shared` | Checkout (`Teams-162`) | 1 | Allowed | `PerRelease` |
| `Production Release Approval` (`ApprovalRules-2`) | `Change Approvals/ProductionOnly` and `Meta-Environment/Production` | Octopus Managers (`teams-managers`) | 1 | Allowed | `PerRelease` |

So in Test, PT - Helm and PT - Linux Package need Payments approval, and PT - Kustomize and PT - Raw YAML need Checkout approval. All four need Managers approval in Production.

## How the gates stack up

A deployment that matches a rule raises an `OCT-<number>` change request when it's queued, before any step runs. The pauses inside the process come after it.

| Order | Gate | When | Once per |
| --- | --- | --- | --- |
| 1 | Change request (`OCT-<number>`) | The project and environment match a rule | Release |
| 2 | `Confirm rollback` (`predeploy-boilerplate`) | Rollback | Tenant |
| 3 | `Confirm AI-assisted release` (`predeploy-boilerplate`) | First deploy of an AI-assisted release to Test or Production | Tenant |
| 4 | `DBA review` | Every rollback, and when the review finds risky SQL or hazards | Tenant |

Confirmed November 9 on PT - Helm, and on PT - Kustomize for the Checkout rule:

- **Deploy.** `1.2.19` (AI-assisted) raised one change request in Test (Payments) and one in Production (Managers). Each was followed by one `Confirm AI-assisted release` pause per tenant.
- **Redeploy.** Redeploying `1.2.19` didn't raise a second change request. It linked to the one already approved. The AI review didn't pause either.
- **Rollback.** A Production rollback to an earlier release raised a new change request, then paused at `Confirm rollback` and at the DBA review. On a project that matches a rule, a rollback passes three gates. The rollback succeeded, and Production then rolled forward to `1.2.19`.
- **Policy.** `Require Team Approval` warned on a PT - Raw YAML deploy to Test (`Deployments-158924`) with the no-owner message. It warned on PT - Kustomize until rule 22 was added. After that, PT - Kustomize's Test deploy raised a Checkout change request.

## Adding a team or a project

1. Add the team's name as a tag in `TeamOwner`, and create an Octopus team with the same name.
2. Add an approval rule scoped to `TeamOwner/<team>` and `EnvironmentUsage/Shared`, with that team as the approver. Copy rule 21's other settings.
3. Tag each project the team owns with `TeamOwner/<team>`. Add `Change Approvals/ProductionOnly` if Production needs approval too.
4. Update the tables on this page.

Editing rules needs `ApprovalRuleAdminister`. It's a space-wide permission, held by the built-in Space manager and Environment manager roles. Project teams can't edit the rules that govern them.

## Gaps and open questions

- **One person is on both teams.** Cory is on Payments and Checkout, so the demo doesn't show a deployer who isn't allowed to approve. Not required. A demo user on one team only would make the demo cleaner.
- **Production allows self-approval.** Not required. Turning on **Block approvals by the deployment creator** on rule 2 would show separation of duties, for a cleaner demo. It needs a second person on the Managers team.
- **Pull request environments aren't covered.** They carry no tags, so no rule matches them. That's intended.
- **Octopus Approvals is in Public Preview.**

## What policies can see

Answered November 9 from `Deployments-158920` (`ServerTasks-54813`, PT - Helm `1.2.19` to Production for Apextime):

- **`RequiresApproval` is `true` when a rule matches.** Compliance policies run before the change request is created, and the field is already set by then.
- **Tags are in the input.** `Project.Tags`, `Environment.Tags`, and `Tenant.Tags` list canonical names, such as `TeamOwner/Payments` and `EnvironmentUsage/Isolated`.

So a policy can check coverage without knowing the rules.

## The `Require Team Approval` policy

`octopus-base-infrastructure/.octopus/policies/require_team_approval.ocl` covers deployments to environments tagged `EnvironmentUsage/Shared`. It doesn't name any rule. It fails a deployment in two cases:

| Case | Message |
| --- | --- |
| The project has no `TeamOwner` tag | "PT - Raw YAML has no `TeamOwner` tag, so no team signs off on its deploys to Test, a shared environment. Tag the project with the team that owns it." |
| The project has an owner, but no rule matched (`RequiresApproval` is false) | "Checkout owns PT - Kustomize, but no approval rule covers it in Test, a shared environment. Other teams can deploy it here without Checkout's sign-off. To add one, ask a space manager for an approval rule on `TeamOwner/Checkout`." |

**The policy is advisory.** Teams should know they *can* require an approval, not that they *must*, and the platform team communicates the options. Every violation warns, including on `Active` projects. Confirmed November 13 on `Deployments-158968` and `-158969`: an `Active` project with no `TeamOwner` warned in Test.

The mechanism for blocking is still there. The `action` in a Rego result overrides the policy's setting in the UI. The policy returns `block` when the project's status is in `blocking_statuses`, and `warn` otherwise. The set is empty on purpose. A first version briefly put `ProjectStatus/Active` in it (`384a925`), and it was never published. To turn blocking on later, add `ProjectStatus/Active` to the set and publish.

The Rego was checked locally with OPA 1.10.1 (`opa check --strict`, and `opa eval` against sample inputs for each case) before it was published.

**Tags are only as strong as whoever can apply them.** Locking the tag sets stops new tags. But applying a tag to a project needs `ProjectEdit`, which project teams usually have. A team could remove `TeamOwner` or change its `ProjectStatus`. That doesn't matter while the policy only warns. If a block ever has to hold, scope `ProjectEdit` more tightly, or have the platform team own status changes.

## The `Require Production Approval` policy

`octopus-base-infrastructure/.octopus/policies/require_production_approval.ocl` covers every deployment and runbook run in an environment tagged `Meta-Environment/Production`. It passes when `RequiresApproval` is `true` and fails otherwise, including when the field is missing. It doesn't name any rule or tool, so an ITSM change request (layer 10) passes the same way, if it sets `RequiresApproval` as the schema describes. That needs checking in layer 10.

`RequiresApproval` is an explicit `false` when no rule matched. Checked November 12 in a Development deploy (`ServerTasks-54871`) and a Production runbook run (`ServerTasks-50782`). A runbook run's input has the same field and a `Runbook` block.

| Case | Message |
| --- | --- |
| No approval gates the deployment or runbook run | "This deployment of PT - Linux Package Streamlined to Production has no approval gating it. Production changes need a recorded approval before they run. Approval is gated by a project tag: tag the project `Change Approvals/ProductionOnly` and the `Production Release Approval` rule will require an approval before it runs. If the project already has that tag, ask a space manager to check the rule." A runbook run says "runbook run" instead of "deployment" |

An approval before Production is a baseline control, unlike team ownership, so this one blocks on `ProjectStatus/Active` projects and warns on everything else (`Onboarding`, or no status). It only fails when no approval rule matched at all, never while a change request is pending, and the fix is always the tag in the message. Case 4 on November 13 showed the warning on a deploy to Production without `ProductionOnly`.

The Rego was checked locally with OPA 1.10.1 (`opa check --strict` and `opa eval` against sample inputs). The first draft didn't load: Rego doesn't allow `sprintf` in a `default` rule, so the violation is a second rule that can't be true at the same time as the passing one.

The five PT projects pass when they carry `Change Approvals/ProductionOnly`. A project without it is the case this policy exists for: on November 13, PT - Linux Package Streamlined without the tag warned (`Deployments-158971`), and then, once the policy blocked `Active` projects, was blocked (`Deployments-158973`, state Failed, no change request).

**Runbook runs need an approval too.** An approval rule can't pick individual runbooks. Any runbook run in Production for a project that matches rule 2 raises a change request. That includes provisioning runs started by the tenant reconciler for a new tenant, which then wait for a Managers approval.

That includes the `Restart app` runbook. In Test and Production it raised a change request each (November 13), and that's accepted for now: Octopus engineering is working on runbook-level approval scoping, so there's no exemption by runbook name, and no separate operations project. The extra approvals will go away when scoping lands.

## The `Require Predeploy Gates` policy

`octopus-base-infrastructure/.octopus/policies/require_predeploy_gates.ocl` checks that a deployment runs the Predeploy Boilerplate process template with its gates in place: `Calculate Deployment Mode` always runs, and the rollback and AI-assisted review pauses are enabled and not skipped. It's how a rollback problem in a higher environment shows up. It warns.

**Where it applies.** Deployments to Production, and to shared environments such as Test (`EnvironmentUsage/Shared`). Not Development, runbook runs, or `pr-<n>`. Development is left out on purpose: a developer working on a new pipeline would otherwise get a boilerplate warning on the very first deploy, before it matters. Rollbacks and AI-assisted releases need their pauses in the higher environments.

**The naming case.** It has a second, separate failure reason. When the gates are in place but the boilerplate step's slug isn't `predeploy-boilerplate`, the policy warns and names the slug it found. Other steps refer to the boilerplate by name, such as the rollback expression on `Postgres.Review.Policy`, which reads `Octopus.Action[Predeploy Boilerplate-Calculate Deployment Mode]`. With a different name nothing fails: the expression stops matching, and a rollback no longer pauses at the DBA review. The policy input has each step's `Id` and `Slug` and no display name, so the slug stands in for the name. In the Octopus UI, regenerate the slug when you rename the step. Confirmed November 13 on `Deployments-158972`: a release made before the rename warned with the slug `run-a-process-template`.

The Rego was checked with OPA 1.10.1: a pass, the naming case, no boilerplate, a skipped or disabled gate, and a conditional mode step. When the gates and the name both fail, the gates reason shows first.

`Confirm Latest Predeploy Boilerplate Versioning` isn't activated. It's an inventory tool, run in evaluate mode, and it appears in no task log.

## Setting up a new pipeline

PT - Linux Package Streamlined started with no tags, and the policies and rules responded as tags were added. Results confirmed from the task logs on November 12 and 13:

| Stage | Project tags | Result |
| --- | --- | --- |
| Development, first deploy | None | No warnings. `Require Predeploy Gates` doesn't cover Development (`Deployments-158963`). Before it was scoped, the same deploy warned (`Deployments-158961`) |
| Test | None | Two warnings: `Require Predeploy Gates`, and `Require Team Approval` (no `TeamOwner`). The deploy goes ahead (`Deployments-158964`) |
| Test | `Active`, no owner | `Require Team Approval` still warns. It's advisory, so it never blocks (`Deployments-158969`) |
| Test | Owned | Rule 21 raises a Payments change request, `OCT57257` (`Deployments-158966`). A redeploy links to it and raises no new one (`Deployments-158970`) |
| Production | Owned, `ProductionOnly` | Rule 2 raises a Managers change request, `OCT57270` (`Deployments-158967`) |
| Production | `Active`, no `ProductionOnly` | `Require Production Approval` warns with the tag-first message (`Deployments-158971`), and blocks once it blocks `Active` projects (`Deployments-158973`) |
| Test, Production | Owned, `ProductionOnly` | A boilerplate step with the old name warns (`Deployments-158972`) |
| All three, new release | `Active`, `TeamOwner/Payments`, `ProductionOnly` | `1.1.17-FullPolicyApproval`: no warnings, `OCT57810` in Test and `OCT57811` in Production (`Deployments-158974`, `-158976`, `-158977`) |
| All three, rollback | Same tags | `1.1.16-Rollback`: `Confirm rollback` and the DBA review in every environment, plus `OCT57822` in Test (`Deployments-158978`, `-158979`). Production waits on `OCT57825` (`Deployments-158980`), left queued for a live demo |

The order inside a task is: policies, then the change request, then the pauses inside the deployment. A block appears before any change request exists.

`Restart app` raised a change request in Test (`OCT57783`) and Production (`OCT57785`), as in [`Require Production Approval`](#the-require-production-approval-policy).

To run it again, remove the tags to go back to the start. A redeploy of the same release links to an approved change request instead of raising a new one, so create a new release for a fresh one.

