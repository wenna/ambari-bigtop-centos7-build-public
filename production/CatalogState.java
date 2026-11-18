import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;
import java.util.Arrays;
import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.fs.Path;

/** Distinguish an empty, dedicated PostgreSQL catalog from an existing or partial schema. */
public class CatalogState {
    public static void main(String[] args) throws Exception {
        Configuration conf = new Configuration();
        conf.addResource(new Path("/etc/hive/metastore/hive-site.xml"));
        char[] secret = conf.getPassword("javax.jdo.option.ConnectionPassword");
        if (secret == null || secret.length == 0) throw new IllegalStateException("Missing Hive JCEKS alias");
        String sql = "SELECT CASE WHEN current_schema() IS DISTINCT FROM 'public' THEN 'partial' "
                + "WHEN to_regclass('public.\"VERSION\"') IS NOT NULL THEN 'existing' "
                + "WHEN EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace "
                + "WHERE n.nspname NOT IN ('information_schema','pg_catalog') AND n.nspname !~ '^pg_' "
                + "AND c.relkind IN ('r','p','S','v','m','f')) THEN 'partial' ELSE 'empty' END";
        try (Connection db = DriverManager.getConnection(conf.get("javax.jdo.option.ConnectionURL"),
                conf.get("javax.jdo.option.ConnectionUserName"), new String(secret));
             Statement stmt = db.createStatement(); ResultSet rows = stmt.executeQuery(sql)) {
            rows.next();
            System.out.println(rows.getString(1));
        } finally {
            Arrays.fill(secret, '\0');
        }
    }
}
