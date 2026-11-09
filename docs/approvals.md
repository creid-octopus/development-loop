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
| PT - Kustomize | `Checkout` | None | None |
| PT - Raw YAML | None | None | None |
| PT - Linux Package | None | None | None |

## Rules

| Rule | Scope | Approvers | Minimum | Self-approval | Tenants |
| --- | --- | --- | --- | --- | --- |
| `Shared Environment Approval - Payments` (`ApprovalRules-21`) | `TeamOwner/Payments` and `EnvironmentUsage/Shared` | Payments (`Teams-161`) | 1 | Allowed | `PerRelease` |
| `Shared Environment Approval - Checkout` (`ApprovalRules-22`) | `TeamOwner/Checkout` and `EnvironmentUsage/Shared` | Checkout (`Teams-162`) | 1 | Allowed | `PerRelease` |
| `Production Release Approval` (`ApprovalRules-2`) | `Change Approvals/ProductionOnly` and `Meta-Environment/Production` | Octopus Managers (`teams-managers`) | 1 | Allowed | `PerRelease` |

So PT - Helm needs Payments approval in Test and Managers approval in Production. PT - Kustomize needs Checkout approval in Test. PT - Raw YAML and PT - Linux Package need no change request anywhere, and `Require Team Approval` warns on their Test deploys.

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

**`ProjectStatus` decides the outcome.** The `action` in a Rego result overrides the policy's setting in the UI. The policy returns `block` when the project's status is in `blocking_statuses`, and `warn` otherwise. That covers `Onboarding` projects and projects with no status tag. The set is empty for now, so every violation warns. Add `ProjectStatus/Active` to make active projects block, once the Evaluations tab shows clean results.

The Rego was checked locally with OPA 1.10.1 (`opa check --strict`, and `opa eval` against sample inputs for each case) before it was published.

**Tags are only as strong as whoever can apply them.** Locking the tag sets stops new tags. But applying a tag to a project needs `ProjectEdit`, which project teams usually have. A team could switch its project from `Active` to `Onboarding` and get warnings instead, or remove `TeamOwner`. That's acceptable for now. If a block has to hold, scope `ProjectEdit` more tightly, or have the platform team own status changes.
