"""Search tools for the Pydantic AI agent."""

import os
import logging
from typing import Any, Optional
from pydantic_ai import RunContext
from models.request_context import RequestContext

from azure.search.documents.aio import SearchClient
from azure.identity.aio import DefaultAzureCredential
from azure.core.exceptions import AzureError

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Azure AI Search configuration
AZURE_SEARCH_ENDPOINT = os.getenv("AZURE_SEARCH_ENDPOINT")
AZURE_SEARCH_INDEX_NAME = os.getenv("AZURE_SEARCH_INDEX_NAME", "chunk_lg_index")
AZURE_SEARCH_SEMANTIC_CONFIG = os.getenv("AZURE_SEARCH_SEMANTIC_CONFIG", "default-semantic-config")
DEFAULT_CATEGORY_VALUE = os.getenv("DEFAULT_CATEGORY_VALUE", "all")

# Log configuration on module load
logger.debug(
    "Azure AI Search config: endpoint=%s, index=%s, semantic=%s, default_category=%s",
    'SET' if AZURE_SEARCH_ENDPOINT else 'NOT SET', AZURE_SEARCH_INDEX_NAME, AZURE_SEARCH_SEMANTIC_CONFIG, DEFAULT_CATEGORY_VALUE
)

# Initialize client
_search_client: Optional[SearchClient] = None

def _get_search_client() -> SearchClient:
    """Get or create Azure Search client."""
    global _search_client
    logger.debug("Get or create Azure Search client")
    
    if _search_client is None:
        logger.debug("Creating new Azure Search client")
        
        if not AZURE_SEARCH_ENDPOINT:
            logger.error("Azure Search configuration missing. AZURE_SEARCH_ENDPOINT environment variable not set.")
            raise ValueError("Azure Search configuration missing. Check AZURE_SEARCH_ENDPOINT environment variable.")
        
        logger.debug("Creating SearchClient for index %s", AZURE_SEARCH_INDEX_NAME)
        
        try:
            _search_client = SearchClient(
                endpoint=AZURE_SEARCH_ENDPOINT,
                index_name=AZURE_SEARCH_INDEX_NAME,
                credential=DefaultAzureCredential()
            )
            logger.debug("Azure Search client created")
        except Exception as e:
            logger.error("Failed to create Azure Search client: %s", e)
            raise
    else:
        logger.debug("Using existing Azure Search client")
    
    return _search_client

async def _perform_hybrid_semantic_search(query: str, category: Optional[str]) -> str:
    """Perform hybrid semantic search using Azure AI Search with integrated vectorization."""
    logger.debug("Hybrid search: query='%s', category='%s'", query, category)
    
    try:
        search_client = _get_search_client()
        # Build category filter (generic vs filtered search)
        normalized_default = (DEFAULT_CATEGORY_VALUE or "").strip().lower()
        normalized_category = (category or "").strip()
        category_filter: Optional[str]
        if not normalized_category or normalized_category.lower() == normalized_default:
            category_filter = None
        else:
            safe_value = normalized_category.replace("'", "''")
            category_filter = f"category eq '{safe_value}'"

        # Execute hybrid semantic search
        search_results = await search_client.search(
            search_text=query,                              # BM25 keyword search
            vector_queries=[
                {"kind": "text", "text": query, "fields": "vector", "k": 50}
            ],                                             # Integrated vectorization
            query_type="semantic",                          # Enable semantic ranking
            semantic_configuration_name=AZURE_SEARCH_SEMANTIC_CONFIG,
            filter=category_filter,                         # Category filtering
            top=10,                                        # Final result count
            select=[
                "id",
                "content",
                "page_number",
                "category",
                "blob_storage_url"
            ]
        )
        
        # Convert search results to JSON format
        logger.debug("Converting search results to JSON format")
        return await _convert_search_results_to_json(search_results, query, category)
        
    except AzureError as e:
        logger.error("Azure Search error: %s", e)
        raise
    except Exception as e:
        logger.error("Unexpected error in hybrid search: %s", e)
        raise

async def _convert_search_results_to_json(search_results, query: str, category: Optional[str]) -> str:
    """Convert search results to JSON format."""
    import json
    from urllib.parse import urlparse

    logger.debug("Converting search results to JSON")

    def _extract_download_endpoint(blob_storage_url: str, page_number: Any = None) -> str:
        """Build custom API download endpoint from blob_storage_url with optional page fragment."""
        try:
            url = (blob_storage_url or "").strip()
            if not url:
                return ""
            parsed = urlparse(url)
            path = parsed.path.lstrip('/')  # container/blob/path
            if not path or '/' not in path:
                return ""
            api_hostname = os.getenv('API_HOSTNAME', 'http://localhost:8000').rstrip('/')
            base_url = f"{api_hostname}/download/{path}"
            if page_number is not None and str(page_number).strip():
                base_url += f"#page={page_number}"
            return base_url
        except Exception:
            return ""

    try:
        result_data = {
            "query": query,
            "category": category,
            "documents": []
        }

        # Extract documents
        logger.debug("Extracting search result documents")
        async for result in search_results:
            if len(result_data["documents"]) >= 10:  # Limit to top 10 results
                break

            # Extract document data
            doc_data = {
                "id": result.get('id', ''),
                "content": result.get('content', ''),
                "api_download_endpoint": _extract_download_endpoint(result.get('blob_storage_url', ''), result.get('page_number', '')),
                "page_number": result.get('page_number', ''),
                "category": result.get('category', ''),
                "search_score": result.get('@search.score', 0),
                "reranker_score": result.get('@search.rerankerScore', 0)
            }

            result_data["documents"].append(doc_data)

        logger.debug("Extracted %d documents", len(result_data["documents"]))

        # Convert to JSON string
        json_result = json.dumps(result_data, indent=2, ensure_ascii=False)
        logger.debug("JSON result length: %d", len(json_result))
        return json_result

    except Exception as e:
        logger.error("Error converting search results to JSON: %s", e)
        # Return basic error structure as JSON
        error_result = {
            "query": query,
            "category": category,
            "error": str(e),
            "documents": []
        }
        return json.dumps(error_result, indent=2)

async def perform_search(ctx: RunContext[RequestContext], query: str) -> str:
    """Perform hybrid semantic search using Azure AI Search with integrated vectorization."""
    # Extract category from context, defaulting to DEFAULT_CATEGORY_VALUE for generic search
    category = ctx.deps.forwarded_props.get('threadMetadata', {}).get('category', DEFAULT_CATEGORY_VALUE)
    logger.info("Searching: query='%s', category='%s'", query, category)
    
    # Validate Azure AI Search configuration
    if not AZURE_SEARCH_ENDPOINT:
        logger.error("Azure AI Search not configured. AZURE_SEARCH_ENDPOINT environment variable not set.")
        raise ValueError("Azure AI Search not configured. Check AZURE_SEARCH_ENDPOINT environment variable.")
    
    logger.debug("Azure AI Search configuration validated")
    
    result = await _perform_hybrid_semantic_search(query, category)
    logger.debug("Search completed. Result length: %d", len(result))
    return result
