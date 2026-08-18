package migrations

import _ "embed"

// Initial is deliberately embedded so a deployment cannot start against an
// unknown schema merely because a migration file was omitted from its image.
//
//go:embed 001_exporter.sql
var Initial string

//go:embed 002_history_sync.sql
var HistorySync string

// All returns the full idempotent schema required by this binary.
func All() string {
	return Initial + "\n" + HistorySync
}
