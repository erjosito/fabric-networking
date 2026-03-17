# Drop a table in Azure SQL Database using PySpark
# This notebook connects to Azure SQL via Entra ID (JDBC) and executes a DROP TABLE command.
# Reuses the same connection pattern as access_db_entra.py.

serverName = "<your_server_name>.database.windows.net"
database = "fabnet-db"
dbPort = 1433
tableName = "dbo.Animals"  # Table to drop

# Get Entra ID access token
print("Getting access token...")
access_token = mssparkutils.credentials.getToken("https://database.windows.net/")

# Build JDBC URL and run the DROP TABLE statement
jdbcURL = f"jdbc:sqlserver://{serverName}:{dbPort};database={database};trustServerCertificate=true"

print(f"Dropping table {tableName}...")
props = spark._sc._gateway.jvm.java.util.Properties()
props.put("accessToken", access_token)
props.put("driver", "com.microsoft.sqlserver.jdbc.SQLServerDriver")

connection = spark._sc._gateway.jvm.java.sql.DriverManager.getConnection(jdbcURL, props)
try:
    stmt = connection.createStatement()
    stmt.executeUpdate(f"DROP TABLE IF EXISTS {tableName}")
    print(f"Table {tableName} dropped successfully.")
finally:
    connection.close()
