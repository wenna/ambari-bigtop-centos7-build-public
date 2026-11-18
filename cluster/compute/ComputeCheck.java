import org.apache.spark.SparkConf;
import org.apache.spark.api.java.JavaSparkContext;
import scala.Tuple2;

public final class ComputeCheck {
    public static void main(String[] args) {
        try (JavaSparkContext context = new JavaSparkContext(new SparkConf())) {
            String id = context.sc().applicationId();
            context.textFile(args[0], 2)
                    .mapToPair(line -> {
                        String[] fields = line.split(",");
                        return new Tuple2<>(fields[0], Integer.parseInt(fields[1]));
                    })
                    .reduceByKey(Integer::sum, 2)
                    .map(row -> id + "\t" + row._1 + "\t" + row._2)
                    .saveAsTextFile(args[1]);
        }
    }
}
