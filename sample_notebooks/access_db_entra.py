# Connecting to data database
# This notebook has commands to connect to the Azure SQL Database provisioned in the lab environment.
# Notebooks use Fabric Capacities to connect to PaaS resources, so when the database is private you 
#    need to configure managed private endpoints for your Fabric Capacities.
serverName = "<your_server_name>.database.windows.net"
database = "fabnet-db"
dbPort = 1433

# Get access Token
print("Getting access token...")
access_token = mssparkutils.credentials.getToken("https://database.windows.net/")
# print("Access token:", access_token)
# print("Access token length:", len(access_token))

# Construct connection
jdbcURL = f"jdbc:sqlserver://{serverName}:{dbPort};database={database};trustServerCertificate=true"
connectionProps = {
    "driver": "com.microsoft.sqlserver.jdbc.SQLServerDriver",
    "accessToken": access_token
}

# Send query and display results
df = spark.read.jdbc(url=jdbcURL, table="dbo.Animals", properties=connectionProps)
display(df)

# Write back to your Fabric Lakehouse
#df.write.mode("overwrite").format("delta").saveAsTable("Customers")