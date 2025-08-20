from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from openai import AsyncAzureOpenAI
from pydantic_ai.models.openai import OpenAIModel
from pydantic_ai.providers.openai import OpenAIProvider

from config import Config

# Azure authentication setup
token_provider = get_bearer_token_provider(
    DefaultAzureCredential(), 
    "https://cognitiveservices.azure.com/.default"
)

# Azure OpenAI client
client = AsyncAzureOpenAI(
    azure_endpoint=Config.AZURE_OPENAI_ENDPOINT,
    api_version=Config.AZURE_OPENAI_API_VERSION,
    azure_ad_token_provider=token_provider,
)


def create_openai_model() -> OpenAIModel:
    """Create configured OpenAI model with Azure provider."""
    return OpenAIModel(
        Config.AZURE_OPENAI_DEPLOYMENT_NAME,
        provider=OpenAIProvider(openai_client=client)
    )
