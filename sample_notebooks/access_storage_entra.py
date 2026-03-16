# Connecting to Azure Blob Storage
# This notebook has commands to connect to the Azure Storage Account provisioned in the lab environment.
# Notebooks use Fabric Capacities to connect to PaaS resources, so when the storage is private you
#    need to configure managed private endpoints for your Fabric Capacities.

STORAGE_ACCOUNT_NAME = "<your_storage_account_name>"   # e.g. fabnetdataabc123
CONTAINER_NAME       = "starwars"                  # create this container first, or use an existing one
BLOB_NAME            = "people.csv"  # upload this file to your container, or use an existing one


# Get access token (same pattern as the SQL notebook)
print("Getting access token...")
access_token = mssparkutils.credentials.getToken("https://storage.azure.com/")
# print("Access token:", access_token)
# print("Access token length:", len(access_token))

# Wrap the token so the Azure Storage SDK can use it
from azure.core.credentials import AccessToken

class FabricTokenCredential:
    """Wraps a raw token string into the credential interface the Azure SDK expects."""
    def __init__(self, token):
        self._token = token
    def get_token(self, *scopes, **kwargs):
        return AccessToken(self._token, 9999999999)

credential = FabricTokenCredential(access_token)

# Connect to the storage account
from azure.storage.blob import BlobServiceClient

blob_service = BlobServiceClient(
    account_url=f"https://{STORAGE_ACCOUNT_NAME}.blob.core.windows.net",
    credential=credential,
)

# List containers
print("Containers:")
for c in blob_service.list_containers():
    print(f"  - {c['name']}")

# List blobs in the target container
container_client = blob_service.get_container_client(CONTAINER_NAME)
print(f"\nBlobs in '{CONTAINER_NAME}':")
for blob in container_client.list_blobs():
    print(f"  {blob.name}  ({blob.size} bytes)")

# Download and read a file
blob_client = container_client.get_blob_client(BLOB_NAME)
downloaded = blob_client.download_blob().readall().decode("utf-8")
# print("\nDownloaded content:")
# print(downloaded)

# Read into a Spark DataFrame
import pandas as pd
from io import StringIO

pdf = pd.read_csv(StringIO(downloaded))
df = spark.createDataFrame(pdf)
display(df)

# Write back to your Fabric Lakehouse
#df.write.mode("overwrite").format("delta").saveAsTable("StorageData")
