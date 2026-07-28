# Repository Guidelines

## Scope and Sources of Truth

These instructions apply to every AI agent working in this repository, regardless of platform or vendor. Before changing scripts, configuration, deployment behavior, or documented technical conventions, read `TECH_SCOPE.md` completely. Treat it as the technical source of truth; use this file only for agent behavior and working discipline.

If the documentation and repository state disagree, report the discrepancy before making a risky change. Do not invent missing architecture, deployment assumptions, or conventions.

## Change Discipline

Make the smallest change that fully addresses the request. Preserve established formatting and naming, avoid unrelated refactors, and do not rewrite whole configuration files. Inspect every downstream consumer when changing a path, filename, port, placeholder, or derived value.

Do not add dependencies, change public behavior, alter deployment targets, or broaden security policy without explicit authorization. Keep unrelated findings out of the patch and report them separately.

## Product Boundary

Respect the deliberately narrow, one-shot bootstrap model documented in `TECH_SCOPE.md`. Do not redesign it into an idempotent provisioner, introduce infrastructure orchestration, add server-role profiles, or absorb downstream configuration unless the user explicitly requests that change. Do not turn observations about individual files into broader design work without first receiving a task for that area.

## Safety and Authorization

Treat installation scripts and service configuration as security-sensitive and potentially lockout-inducing. Never execute privileged setup, change a live host, contact a deployment target, or perform destructive operations unless the user explicitly requests that exact action. Use an isolated, disposable environment for behavioral testing.

Never read, modify, or commit credentials, private keys, tokens, production secrets, or environment-specific administrative data. Preserve placeholders unless replacing them is explicitly in scope, and confirm the intended value before doing so.

## Verification

Use the targeted validation commands documented in `TECH_SCOPE.md`. Prefer static checks before any runtime validation. Never claim a check was run unless it completed; distinguish failures caused by the change from pre-existing issues. If the required environment or tool is unavailable, state that clearly and provide the exact command for manual verification.

## Reporting and Review

Before finishing, review the diff for accidental changes and check whether the implementation made `TECH_SCOPE.md` stale. Report changed files, completed validation, unverified behavior, assumptions, side effects, and rollback or follow-up needs. Security-impacting reviews must call out authentication, firewall, remote-access, and recovery implications.
