package migrations

import _ "embed"

// Initial is deliberately embedded so a deployment cannot start against an
// unknown schema merely because a migration file was omitted from its image.
//
//go:embed 001_exporter.sql
var Initial string
