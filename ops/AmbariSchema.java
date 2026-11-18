import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;
import java.util.regex.Pattern;

/** Single-file Java 17 program for the packaged Ambari 3 PostgreSQL DDL. */
class AmbariSchema {
    private static boolean predicate(Statement stmt, String query) throws Exception {
        try (ResultSet result = stmt.executeQuery(query)) {
            return result.next() && result.getBoolean(1);
        }
    }

    public static void main(String[] args) throws Exception {
        String password = Files.readString(Path.of(args[2])).replaceFirst("[\\r\\n]+$", "");
        try (Connection db = DriverManager.getConnection(args[0], args[1], password);
             Statement stmt = db.createStatement()) {
            db.setAutoCommit(false);
            stmt.execute("SET LOCAL search_path TO public");
            stmt.execute("SELECT pg_advisory_xact_lock(1836412407)");
            if (!predicate(stmt, "SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()")) {
                throw new IllegalStateException("TLS connection required");
            }
            if (args[3].equals("init")) {
                if (!predicate(stmt, "SELECT NOT EXISTS (SELECT FROM pg_class WHERE "
                        + "relnamespace='public'::regnamespace AND relkind IN ('r','p','S','v','m','f'))")) {
                    throw new IllegalStateException("Refusing to initialize a nonempty public schema");
                }
                String ddl = Files.readString(Path.of(args[4]));
                if (Pattern.compile("(?m)^\\h*\\\\").matcher(ddl).find()) {
                    throw new IllegalArgumentException("Unexpected psql meta-command in packaged DDL");
                }
                // Upstream wraps only the seed inserts in BEGIN and COMMIT. Extend
                // the transaction across both DDL and seed rows, including Quartz.
                ddl = ddl.replaceAll("(?im)^\\h*(?:BEGIN|COMMIT);\\h*\\r?$", "");
                stmt.execute(ddl);
                while (stmt.getMoreResults() || stmt.getUpdateCount() != -1) {
                    // Consume pgJDBC's results for the full multi-statement script.
                }
            } else if (!args[3].equals("verify")) {
                throw new IllegalArgumentException("Expected init or verify");
            }
            if (!predicate(stmt, "SELECT to_regclass('public.clusters') IS NOT NULL "
                    + "AND to_regclass('public.qrtz_locks') IS NOT NULL AND EXISTS "
                    + "(SELECT FROM public.metainfo WHERE metainfo_key='version')")) {
                throw new IllegalStateException("Incomplete Ambari schema");
            }
            db.commit();
        }
    }
}
