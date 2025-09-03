from dotenv import load_dotenv
import os

load_dotenv()

class Config:
    """Centralized configuration for the application."""
    
    # Azure OpenAI settings
    AZURE_OPENAI_ENDPOINT = os.getenv('AZURE_OPENAI_ENDPOINT')
    AZURE_OPENAI_API_VERSION = os.getenv('AZURE_OPENAI_API_VERSION')
    AZURE_OPENAI_DEPLOYMENT_NAME = os.getenv('AZURE_OPENAI_DEPLOYMENT_NAME')
    
    # Azure Storage settings
    AZURE_STORAGE_ACCOUNT_NAME = os.getenv('AZURE_STORAGE_ACCOUNT_NAME')

    # Microsoft Entra (Azure AD) token validation settings
    ENTRA_TENANT_ID = os.getenv('ENTRA_TENANT_ID')  # Required
    ENTRA_AUDIENCE = os.getenv('ENTRA_AUDIENCE')    # e.g., api://<client-id> or the app's client ID
