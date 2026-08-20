package migrations

import (
	"context"
	"database/sql"
	"embed"
	"fmt"
	"io/fs"
	"sort"
	"strings"
)

const lockName = "sakuravel_schema_migrations"

// migrationFiles are embedded so the same API image can initialize and update
// the database in AppRun, where docker-entrypoint-initdb.d is not available.
//
//go:embed *.sql
var migrationFiles embed.FS

// Run applies migrations that have not yet been recorded. A dedicated
// connection is used because MariaDB named locks belong to the connection.
func Run(ctx context.Context, db *sql.DB) error {
	conn, err := db.Conn(ctx)
	if err != nil {
		return fmt.Errorf("get migration connection: %w", err)
	}
	defer conn.Close()

	var locked sql.NullInt64
	if err := conn.QueryRowContext(ctx, "SELECT GET_LOCK(?, 60)", lockName).Scan(&locked); err != nil {
		return fmt.Errorf("acquire migration lock: %w", err)
	}
	if !locked.Valid || locked.Int64 != 1 {
		return fmt.Errorf("acquire migration lock: timed out")
	}
	defer func() {
		// Closing the dedicated connection also releases the lock if this fails.
		_, _ = conn.ExecContext(context.Background(), "SELECT RELEASE_LOCK(?)", lockName)
	}()

	if _, err := conn.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		version VARCHAR(255) NOT NULL PRIMARY KEY
	) DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci`); err != nil {
		return fmt.Errorf("create migration table: %w", err)
	}

	names, err := fs.Glob(migrationFiles, "*.sql")
	if err != nil {
		return fmt.Errorf("list migrations: %w", err)
	}
	sort.Strings(names)

	for _, name := range names {
		var applied bool
		if err := conn.QueryRowContext(ctx,
			"SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version = ?)", name,
		).Scan(&applied); err != nil {
			return fmt.Errorf("check migration %s: %w", name, err)
		}
		if applied {
			continue
		}

		body, err := migrationFiles.ReadFile(name)
		if err != nil {
			return fmt.Errorf("read migration %s: %w", name, err)
		}
		for _, statement := range splitStatements(string(body)) {
			if _, err := conn.ExecContext(ctx, statement); err != nil {
				return fmt.Errorf("apply migration %s: %w", name, err)
			}
		}
		if _, err := conn.ExecContext(ctx,
			"INSERT INTO schema_migrations (version) VALUES (?)", name,
		); err != nil {
			return fmt.Errorf("record migration %s: %w", name, err)
		}
	}

	return nil
}

// splitStatements is intentionally small: migration files use one statement
// per semicolon and line comments only. Keeping it here avoids adding a tool or
// enabling multiStatements for every application DB connection.
func splitStatements(sqlText string) []string {
	var statements []string
	var current strings.Builder

	for _, line := range strings.Split(sqlText, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "--") || trimmed == "" {
			continue
		}
		current.WriteString(line)
		current.WriteByte('\n')

		for {
			text := current.String()
			semicolon := strings.IndexByte(text, ';')
			if semicolon < 0 {
				break
			}
			if statement := strings.TrimSpace(text[:semicolon]); statement != "" {
				statements = append(statements, statement)
			}
			current.Reset()
			current.WriteString(text[semicolon+1:])
		}
	}
	if statement := strings.TrimSpace(current.String()); statement != "" {
		statements = append(statements, statement)
	}
	return statements
}
