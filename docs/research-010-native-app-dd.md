# T-004/T4 Gates — Native Homebrew App Due Diligence (Decision Record)

**Status:** Adversarial review complete (2 rounds + field research), 2026-08-24; awaiting maintainer go/no-go
**Decides:** The expanded Phase 4 idea — a full native macOS app for the Homebrew ecosystem (menu bar, notifications, browse/review/upgrade GUI), potentially App Store distributed, hoping for donations/sponsorship/VC — versus the original narrow shape (menu-bar notifications) versus doing nothing.
**Method:** Web-research agent (market, App Store constraints, demand, monetization, trademark — all claims sourced) + two Gilfoyle-persona adversarial rounds. No round 3: both rounds agree on the headline verdict.

## 1. The thought under review (maintainer, 2026-08-24)

Expand the native-integration roadmap item into a full macOS app for the Homebrew ecosystem, potentially App Store distributed, with the hope that users rave about it enough that donations/sponsorship sustain development ("VC funding if it comes to it").

## 2. Verified field facts

- **The space is served, actively.** Cork (leading Homebrew GUI; maintained, ~20 stars/week, **€25** one-time for prebuilt binaries), Tappie (free), Applite (MIT), BrewServicesManager (menu-bar) — and **`Homebrew/brewui` is an official Homebrew-organization GUI project** in early development. Cakebrew, the pioneer, is officially discontinued — a **maintenance** death, not a demand death.
- **App Store distribution is technically near-dead for this category.** Sandboxed apps cannot write `/opt/homebrew` or run `brew` as an external helper without embedding and re-signing brew itself; Homebrew even ships `HOMEBREW_AVOID_NESTED_SANDBOXING` because nested sandboxes conflict. **Zero package-manager GUIs exist on the Mac App Store**; every one distributes direct-download DMG.
- **Demand is real but split.** Active r/macapps interest threads alongside one literally titled "Another homebrew GUI? Why?" — and the standing "the benefit of Homebrew is the CLI" faction. No survey data quantifying either side.
- **Monetization.** Cork's €25 proves *some* money exists; no verified revenue numbers for any comparable (GitHub Sponsors earnings are private). Homebrew itself raised $310k+ Sponsors — infrastructure scale, not comparable to a wrapper app. **Zero VC-backed companies around dev package-management utilities found.**
- **Trademark risk: low.** No Homebrew trademark policy exists publicly; multiple apps use "brew"/"Homebrew" freely; no enforcement observed.

## 3. Round 1 verdict (premise attack, no data)

**REJECT** the full app; **GATHER-EVIDENCE** on a menu-bar-only open-source notifier. Most damning argument: "you're building a GUI for an audience that explicitly chose the CLI." Five-item evidence checklist issued.

## 4. Round 2 reconciliation (facts applied)

Round 1 was **right for partly wrong reasons**: the space isn't dead — it's *crowded*, including officially (brewui). Checklist outcomes: survey item dead (no data), revenue comparables dead (private), active-GUI item partially satisfied (Cork — MAU unknown), App Store item moot (technically impossible), VC item dead.

**Surviving argument against the full app:** the market already has package-manager GUIs; brew-change's actual differentiation — honest three-state assessment, breaking-change verdicts, evidence provenance — is a **trust layer**, not a package manager, and doesn't require becoming another Cork.

**What the facts do support:** a *menu-bar companion to brew-change* that surfaces the verdict workflow (e.g., "3 updates available · 1 breaking"), read-only at first, direct-download, open-source, no App Store, no monetization narrative.

## 5. Verdicts

| Shape | Verdict |
|---|---|
| Full app, App Store, monetization/VC hopes | **REJECT** — App Store technically infeasible; space served incl. officially; no VC precedent; solo-maintainer burnout math (Cakebrew's path) |
| Menu-bar open-source companion centering the verdict/trust workflow, direct download | **PROCEED (conditional)** — only behind the cheapest-experiment gate below |
| Contribute to `Homebrew/brewui` instead | **Worth considering** — official surface, but the trust workflow may not fit their scope |

## 6. Cheapest settling experiment (before any committed build)

A read-only Swift menu-bar prototype (~40 hours, unsigned DMG, ~50 users from r/macapps / Homebrew communities): one menu line — "3 updates available (1 breaking, 2 minor)" — click-through to brew-change's verdict. Measures: (1) will users install unsigned?, (2) do they click through?, (3) do they ask for install capability? **Proceed only if >60% install AND click through AND ask for install.** Cost: ~40h, $0; kills or confirms the idea without a maintenance surface.

## 7. Roadmap consequence

This record closes the T4.0.1/T4.0.2 gates for the App-Store/monetized shape permanently absent new evidence (reconsideration restarts at round 1). The narrow T4 path that may proceed — menu-bar verdict companion — is **blocked on the maintainer's go/no-go** and, if go, on the §6 experiment result. No implementation task becomes Ready without that approval.

## 8. Addendum (2026-08-24, maintainer questions)

**Q1 — "Did Cakebrew have AI tooling? Building is cheap now; just build the right thing with distribution."**

Conceded, with boundaries. Cakebrew (2014–2020) predates AI-assisted development, and the §6 experiment's ~40h estimate already assumes that cheaper curve. What AI genuinely cheapens: writing the Swift, porting across macOS releases, drafting docs. What it does not cheapen: the responsibility surface — triaging user reports, trust/security review for anything that mutates the system, signing/notarization chores, and simply *being the human accountable for an app people install*. For a **read-only** companion that surface shrinks a lot, so the point materially strengthens the menu-bar case; it changes nothing for the App Store/monetization case, which died on technical infeasibility and a served market, not on effort.

**Q2 — "Contribute to brewui instead? More confidence there than DIY?"**

Fresh brewui facts (2026-08-24): created 2026-03, **923 commits** (~3/day), last commit 2026-08-23 — very active; led by **Mike McQuaid, Homebrew's project leader**; Swift 6 / SwiftUI; macOS Tahoe 26+ back to Sonoma; **AGPL-3.0**; early "Foundation D1" phase with contribution guidelines explicitly "coming as part of the initial setup work"; stated goal — *"enable CLI-averse users to safely discover, install, update, and manage Homebrew packages through a native SwiftUI interface that never hides what Homebrew is doing."* No changelog/risk-assessment roadmap items yet; no distribution statements yet; 102 stars; minimal public discussion so far.

Confidence comparison, honestly:

- **brewui** has the distribution confidence (official org, project-leader commitment, will be promoted by Homebrew itself) and a philosophy ("never hides what Homebrew is doing") that is *aligned* with brew-change's trust edge. But it is early, has no contribution process yet, commits to no feature roadmap, and its license (AGPL-3.0) means any *code* sharing is one-directional — brew-change (Apache-2.0) must not embed brewui code.
- **DIY** has full control and zero distribution — the exact inverse.

**The option that beats both: brew-change as the assessment layer, consumed through its existing export surface.** brew-change already ships a versioned, public JSON export (`~/.brew-change/last-assessment.json`, `brew-change export`, schema_version 1 — tasks-005) designed for exactly this. The highest-leverage move is not Swift contributions and not a competing app: it is (a) proposing to brewui — once their contribution process opens — a "trusted update view" powered by brew-change's export (their stated goal is a natural host for the verdict: attention / no-signal / unknown with reasons and provenance), and (b) optionally proving the integration API with the §6 menu-bar prototype, which doubles as the demand probe. Distribution then comes from brewui's official channel; the differentiation stays in brew-change where it already has tests, users, and a release cadence.

Recommendation update (supersedes the §5 third row): **prefer the export-integration path first**, keep the §6 prototype as the cheap demand probe, and revisit Swift-level contribution to brewui only if the integration lands and pulls. The maintainer's go/no-go still gates everything.
