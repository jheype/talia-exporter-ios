# Native Super Admin

SA Portal is a SwiftUI workspace in Talia Exporter. It uses the app's existing graphite/warm-white theme, native navigation, forms, lists, charts, confirmation sheets and sharing. No web page is embedded.

The top switch preserves the Exporter tab tree. SA has Overview, Users, Alerts, Manage and Security tabs. Manage exposes the existing thirteen portal areas. The server remains authoritative for permissions and mutations.

| Area | Native coverage |
| --- | --- |
| Overview | Live company/user totals, trials, churn signals and unread security incidents |
| Tenants | Companies and people, creation, signup links/revocation, plan/status/trial/settings/AI changes, usage, password-reset/invitation actions and CSV export |
| Billing | Revenue, trials and subscriptions; payment retry and cancellation from company details |
| Developers | Accounts, usage, trials, API/login suspension, subscription renewal and key revocation |
| Pricing | Plans, Stripe environment, price preview, reprice jobs and subscription migration |
| Exchange | Overview, listings/photos/history, cases, dealers, moderation, listing edits, holds and restrictions |
| Analytics | Platform totals, company growth chart and churn signals |
| AI Usage | Usage by company, company details and model configuration |
| Watch Signals | Validation totals and validation audit history |
| Email Log | Delivery entries and recipient search |
| Audit Log | Admin actions and exact action filter |
| Access Security | Summary, searchable/paginated requests, risk filters and reversible account blocking |
| Security | Native MFA login/enrolment, disable MFA, notification controls and sign-out |

## Users (customer analytics and outreach)

The Users tab lists every CRM user from `admin/user-analytics`. Each row shows the last time they used Talia on desktop or phone, their active time, their top area and a churn-risk status (new, active, cooling, at risk, dormant). Filters: churn risk, inactive 2+ days, warm, follow-ups due, not contacted in 30 days, and internal. A user's page shows:

- daily active time (desktop vs phone) and time per area
- what they did (stock, invoices, sales, clients, Exchange, price searches, AI and so on) and a recent activity timeline
- the relationship (stage, owner, follow-up, note, internal flag) and the outreach log

Log outreach and edit the relationship from the + menu. Swipe an outreach entry to delete it.

Each morning the server sends one **inactivity digest** alert to every SA phone with alerts on, whatever its risk preference: people who haven't used Talia for 2 days, plus follow-ups due. Its notification (`kind: sa-inactivity`) opens the alert, which lists the people, each linking to their page. The lock screen shows counts only. Server details: talia-crm-ai-v20 `docs/operations/sa-user-analytics.md`.

## Authentication

Exporter continues to use v14 at `api.talia.co.uk`. SA uses `https://app.taliaai.com/api/v1/` and a separate ephemeral URLSession, with no cookie jar or web view. CRM access/refresh tokens are stored in the iOS Keychain using `WhenUnlockedThisDeviceOnly`, scoped to the Exporter account. Passwords and authenticator setup secrets are not persisted.

CRM `is_super_admin`, current database permissions and verified MFA are required by the existing backend. A v14 owner is not automatically an SA. The native login handles both TOTP and email verification challenges, and enrolment requires the current password. After enrolment the user signs in again to obtain a verified MFA session.

The CRM currently permits one mobile authentication session per account. Signing into SA here can replace the same account's session in another native CRM app. That is an existing backend policy, not an additional Exporter exception.

On account change, pending requests are invalidated synchronously and old credentials/data are cleared. Server sign-out is attempted. An offline sign-out cannot promise immediate server revocation; devices also stop receiving when the bound session expires or is revoked. SA content is covered while the app is inactive.

## Notifications

Deploy the companion CRM backend patch and migration first. Enable Push Notifications for the app identifier and configure the server's Apple APNs key. The app already contains `aps-environment`; `TaliaPushEnvironment` expands the same build setting so device registration selects sandbox for development and production for distribution.

In **SA Portal → Security → Enable security alerts**, grant iOS permission. Use **Send a test notification** to test this phone. A successful API result means Apple accepted the request, not a delivery receipt from the handset. Confirm it on a signed physical device, including with the app closed and by tapping the notification.

The server creates alerts for existing high/critical access-risk signals and at least ten rejected sign-ins from the same IP within five minutes. Repeated events with the same source/rule/severity are grouped into ten-minute buckets. This is access-security telemetry, not a financial-fraud classifier or a guarantee of detecting every suspicious event. The existing telemetry writer remains best effort; events that never reach that log cannot produce an incident.

Lock-screen text contains no company, email, IP or customer information. Incident details require authenticated SA access. Notifications are sent by APNs; there is no simulated local-notification timer or foreground polling requirement for delivery. Existing Exporter interruption alerts remain independently controlled.

Registrations are bound to the verified mobile session, and delivery rechecks the current SA role, MFA, revocation and account security state. The present CRM session lifetime is seven days without refresh; reopen/sign in before it expires if continuing alerts are required. Expired or invalid registrations do not silently continue. iOS notification settings and Focus can suppress presentation.

## Validation and release

- New backend suite: 9 passing tests using PostgreSQL via PGlite, real Express routes and mocked APNs transport. Covers grouping, sign-in bursts, registration, token reassignment, revocation, severity preferences, retry/invalidation, read receipts and payload privacy.
- New TypeScript modules and tests typechecked with the available backend dependency tree.
- All Swift files parsed, Info.plist validated and Xcode source membership verified.
- Swift tests added for native API isolation, refresh, mutation retry policy, account reset, push routing and light/dark login rendering.
- No Xcode or Apple SDK is available in the build environment used to prepare this package. The iOS target and Swift tests have **not** been compiled or run here. No live APNs delivery or production mutation has been performed.

On a Mac, open `TaliaExporter.xcodeproj`, select the correct team for the app and widget, run the existing test scheme, then run on the iPhone. Keep the existing app/group bundle identifiers if replacing an installed development build.
