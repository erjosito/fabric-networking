# List all tables in the database
# This notebook connects to the Azure SQL Database and lists all user tables.
# Notebooks use Fabric Capacities to connect to PaaS resources, so when the database is private you
#    need to configure managed private endpoints for your Fabric Capacities.
serverName = "<your_server_name>.database.windows.net"
database = "fabnet-db"
dbPort = 1433

# Get access Token
print("Getting access token...")
access_token = mssparkutils.credentials.getToken("https://database.windows.net/")

# Construct connection
jdbcURL = f"jdbc:sqlserver://{serverName}:{dbPort};database={database};trustServerCertificate=true"
connectionProps = {
    "driver": "com.microsoft.sqlserver.jdbc.SQLServerDriver",
    "accessToken": access_token
}

# List all user tables
query = "(SELECT schema_name(t.schema_id) as schema_name, t.name as table_name, t.create_date, t.modify_date from sys.tables t) AS table_list"
df = spark.read.jdbc(url=jdbcURL, table=query, properties=connectionProps)
display(df)
