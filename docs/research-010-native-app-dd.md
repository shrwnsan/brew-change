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
