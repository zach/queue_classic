module QC
  class Database

    MAX_TOP_BOUND = 9
    DEFAULT_QUEUE_NAME = "queue_classic_jobs"

    def self.create_queue(name)
      db = new(:name => name)
      db.init_db
      true
    end

    attr_reader :table_name

    def initialize(queue_name=nil)
      @top_boundry = ENV["TOP_BOUND"] || MAX_TOP_BOUND
      @table_name = queue_name || DEFAULT_QUEUE_NAME
      @db_params = URI.parse(ENV["DATABASE_URL"])
    end

    def init_db
      drop_table
      create_table
      load_functions
    end

    def waiting_conns
      execute("SELECT * FROM pg_stat_activity WHERE datname = '#{@name}' AND waiting = 't'")
    end

    def all_conns
      execute("SELECT * FROM pg_stat_activity WHERE datname = '#{@name}'")
    end

    def silence_warnings
      execute("SET client_min_messages TO 'warning'")
    end

    def execute(sql)
      connection.exec(sql)
    end

    def disconnect
      connection.finish
    end

    def connection
      if defined? @connection
        @connection
      else
        @name = @db_params.path.gsub("/","")
        @connection = PGconn.connect(
          :dbname   => @db_params.path.gsub("/",""),
          :user     => @db_params.user,
          :password => @db_params.password,
          :host     => @db_params.host
        )
        @connection.exec("LISTEN queue_classic_jobs")
        silence_warnings unless ENV["LOGGING_ENABLED"]
        @connection
      end
    end

    def drop_table
      execute("DROP TABLE IF EXISTS #{@table_name} CASCADE")
    end

    def create_table
      execute("CREATE TABLE #{@table_name} (id serial, details text, locked_at timestamp)")
      execute("CREATE INDEX #{@table_name}_id_idx ON #{@table_name} (id)")
    end

    def load_functions
      execute(<<-EOD)
        CREATE OR REPLACE FUNCTION lock_head_on_#{@table_name}() RETURNS SETOF #{@table_name} AS $$
        DECLARE
          unlocked integer;
          relative_top integer;
          job_count integer;
          job #{@table_name}%rowtype;

        BEGIN
          SELECT TRUNC(random() * #{@top_boundry} + 1) INTO relative_top;
          SELECT count(*) from #{@table_name} INTO job_count;

          IF job_count < 10 THEN
            relative_top = 0;
          END IF;

          SELECT id INTO unlocked
            FROM #{@table_name}
            WHERE locked_at IS NULL
            ORDER BY id ASC
            LIMIT 1
            OFFSET relative_top
            FOR UPDATE NOWAIT;
          RETURN QUERY UPDATE #{@table_name}
            SET locked_at = (CURRENT_TIMESTAMP)
            WHERE id = unlocked AND locked_at IS NULL
            RETURNING *;
        END;
        $$ LANGUAGE plpgsql;
      EOD
    end

  end
end