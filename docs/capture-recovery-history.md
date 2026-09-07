# PR-2 — Exporter capture start/resume recovery

This package is intentionally separate from the UK Chats image-intelligence
correction package. It fixes the Lucas Renshaw account symptoms:

- `Unable to start capture — Check your internet connection and try again.`
- capture remaining `Paused` after selecting a group;
- `Unable to resume capture — Check the supplied values and try again.`

## Root cause

The group-selection request performed an unbounded promotion/deletion pass over
the entire pre-selection WhatsApp history before returning. A large initial
account backlog could outlive the iOS or ingress timeout. The next resume request
then found no committed selected group and returned the generic invalid-input
error.

## What changes

### Exporter backend

- Group selection and first capture activation remain atomic, but the control
  transaction no longer processes the whole message backlog.
- Only groups affected by the selection are locked; hundreds of unrelated
  discovered groups no longer add lock calls to the request.
- Durable `pending` rows are reconciled by the owning WhatsApp session worker in
  bounded pages of 250.
- A pass promotes selected messages, queues their intelligence work, discards
  unselected rows and cleans unselected quarantine rows without exceeding the
  page limit for message mutations.
- History starts only after the pending backlog is drained. The worker yields
  after 20 pages so live traffic and other sessions retain capacity.
- Restart recovery requires no extra in-memory state or migration: remaining
  `pending` rows are the durable queue.
- Image/text pairing runs after the final promotion page, so a page boundary
  cannot separate an image from its following advert.
- Resume with no selected groups now returns
  `WHATSAPP.NO_SELECTED_GROUPS`; a stale group list returns
  `WHATSAPP.GROUP_SELECTION_STALE`.
- Rejected control requests are logged with HTTP status and stable error code.

### Talia Exporter iOS

- A timeout or interrupted response is treated as ambiguous, not automatically
  described as a lack of internet.
- After an ambiguous start/pause/resume response, the app reads the authoritative
  session state. If the mutation committed, the UI proceeds without asking the
  user to repeat it.
- Resume preflights server group selection. With no selected group, the app
  opens the Groups tab and explains exactly what is required.
- A stale group list is refreshed before asking the user to choose again.
- The capture toggle is disabled while a control mutation is in flight.

## Branch order

This is a stacked PR-2. Create its branch from the branch containing the
image-intelligence PR that was supplied immediately before this package. The
backend reconciliation uses that PR's intelligence columns/jobs and conservative
media-pairing schema. Once PR-1 is merged, retarget PR-2 to `main`.

Do not copy files from this package into the PR-1 branch and commit them there;
that would mix the two review scopes.

The iOS files assume the earlier account/session-isolation client patch is
already present (`TaliaExporter-account-isolation-fixed-v1`).

## Apply

The `talia-v14/` and `TaliaExporter/` folders preserve repository-relative paths.
Copy each tree over the matching project only on the PR-2 branch.

No database migration or new environment variable is required.

## Verification

Backend:

```bash
cd services/exporter
gofmt -w \
  internal/domain/models.go \
  internal/httpapi/respond.go \
  internal/httpapi/capture_errors_test.go \
  internal/store/repository.go \
  internal/store/sessions.go \
  internal/store/groups.go \
  internal/store/media.go \
  internal/store/postgres_integration_test.go \
  internal/whatsapp/manager.go \
  internal/whatsapp/selection_reconciliation_test.go \
  contracts/exporter_api_contract_test.go
go test ./...
```

Run PostgreSQL integration coverage as usual with `TEST_DATABASE_URL` configured.

iOS:

1. Add `TaliaExporterTests/CaptureControlRecoveryTests.swift` to the unit-test
   target, not the application target.
2. Run the existing Xcode test scheme:

```bash
xcodebuild \
  -scheme TaliaExporter \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  clean test
```

## Deployment and acceptance

Deploy the backend before distributing the iOS build.

1. Sign in as Lucas Renshaw and confirm his WhatsApp remains linked.
2. Select `Testing ingestion` and start capture.
3. Confirm the screen becomes `LIVE` without an internet or supplied-values
   alert.
4. Pause and resume capture once.
5. Send a new text in that group and confirm it appears in UK Chats.
6. While the initial backlog drains, confirm logs contain
   `reconciled pending WhatsApp selection batch` and eventually show
   `remaining=false`.
7. Confirm the Exporter pod does not restart and new live messages continue to
   arrive while old bootstrap rows are reconciled.

