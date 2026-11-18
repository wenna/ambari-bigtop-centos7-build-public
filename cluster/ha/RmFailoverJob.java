import java.io.IOException;
import java.util.concurrent.TimeUnit;
import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.fs.FSDataOutputStream;
import org.apache.hadoop.fs.FileSystem;
import org.apache.hadoop.fs.Path;
import org.apache.hadoop.io.LongWritable;
import org.apache.hadoop.io.NullWritable;
import org.apache.hadoop.io.Text;
import org.apache.hadoop.mapreduce.Job;
import org.apache.hadoop.mapreduce.Mapper;
import org.apache.hadoop.mapreduce.lib.input.FileInputFormat;
import org.apache.hadoop.mapreduce.lib.output.FileOutputFormat;

/** Keep one actual map container running until the test observes RM promotion. */
public final class RmFailoverJob {
    public static class WaitingMapper extends Mapper<LongWritable, Text, NullWritable, Text> {
        @Override
        protected void map(LongWritable offset, Text line, Context context)
                throws IOException, InterruptedException {
            String container = System.getenv("CONTAINER_ID");
            if (container == null || !container.startsWith("container_")) {
                throw new IOException("Missing YARN container ID");
            }
            FileSystem fs = FileSystem.get(context.getConfiguration());
            try (FSDataOutputStream out = fs.create(new Path("/ha-check/rm-ready"), false)) {
                out.writeBytes(container + "\n");
            }
            Path release = new Path("/ha-check/rm-release");
            long started = System.nanoTime();
            while (!fs.exists(release)) {
                if (System.nanoTime() - started > TimeUnit.MINUTES.toNanos(8)) {
                    throw new IOException("Timed out waiting for RM failover");
                }
                context.progress();
                Thread.sleep(1000);
            }
            context.write(NullWritable.get(), new Text(container));
        }
    }

    public static void main(String[] args) throws Exception {
        Configuration conf = new Configuration();
        conf.setInt("mapreduce.am.max-attempts", 1);
        Job job = Job.getInstance(conf, "rm-failover-check");
        job.setJarByClass(RmFailoverJob.class);
        job.setMapperClass(WaitingMapper.class);
        job.setMaxMapAttempts(1);
        job.setSpeculativeExecution(false);
        job.setNumReduceTasks(0);
        job.setOutputKeyClass(NullWritable.class);
        job.setOutputValueClass(Text.class);
        FileInputFormat.addInputPath(job, new Path("/ha-check/rm-input"));
        FileOutputFormat.setOutputPath(job, new Path("/ha-check/rm-output"));
        job.submit();
        System.out.println(job.getJobID().toString().replaceFirst("^job_", "application_"));
    }
}
