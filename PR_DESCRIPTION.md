# fix(exporter): make capture start/resume bounded and recoverable

## Summary

Fixes linked WhatsApp sessions becoming stuck in `paused` when the initial group
selection outlives the iOS/ingress request timeout.

The control-plane transaction now commits selection and first capture activation
without synchronously processing the full bootstrap history. The session worker
reconciles the durable pending backlog in bounded pages before starting older
history. iOS reconciles authoritative server state after ambiguous mutation
failures and presents actionable group-selection errors.

## Safety properties

- Selection and first capture activation remain atomic.
- Pending bootstrap rows remain durable across pod restarts.
- History cannot advance before selection reconciliation completes.
- Reconciliation follows the existing session-first lock order.
- Each message pass is bounded to 250 mutations and yields after 20 pages.
- Selected text promotion and intelligence-job creation share one transaction.
- Media pairing waits for the final promotion page and remains fail-closed on
  ambiguity.
- No automatic capture access is granted across Talia accounts.
- No migration, credential, storage or external service is added.

## Tests

- bounded PostgreSQL bootstrap reconciliation and atomic capture activation;
- reconciliation drain/yield worker behaviour;
- stable API errors for missing/stale group selection;
- OpenAPI bounded asynchronous control contract;
- iOS read-after-timeout recovery for start and resume;
- iOS recovery path for server-authoritative empty selection;
- iOS group refresh after a stale selection conflict.

## Rollout

Stacked on the image-intelligence PR. Deploy Exporter backend first, then release
the iOS build. Validate with Lucas Renshaw's linked account by selecting
`Testing ingestion`, starting capture, pausing/resuming once and confirming a new
WhatsApp text reaches UK Chats.
