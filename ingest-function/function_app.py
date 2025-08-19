import azure.functions as func
import datetime
import json
import logging
import os
import io
import re
import hashlib
import urllib.parse
from typing import List, Dict, Any, Optional
import tiktoken

from azure.ai.documentintelligence import DocumentIntelligenceClient
from azure.identity import DefaultAzureCredential
from azure.core.credentials import AzureKeyCredential
from azure.core.exceptions import AzureError
from search_utils import (
    get_search_client,
    chunk_documents_for_indexing,
    validate_documents_shape,
    normalize_published_date_value,
)

# Import document analysis utilities
from document_analysis import analyze_document_content

app = func.FunctionApp()

_DOC_INTEL_CLIENT: Optional[DocumentIntelligenceClient] = None

def get_document_intelligence_client() -> DocumentIntelligenceClient:
    """Return a cached Document Intelligence client. Prefer Managed Identity, fallback to key."""
    global _DOC_INTEL_CLIENT
    if _DOC_INTEL_CLIENT is not None:
        return _DOC_INTEL_CLIENT

    endpoint = os.environ.get("DOC_INTEL_ENDPOINT")
    if not endpoint:
        raise ValueError("DOC_INTEL_ENDPOINT environment variable is required")

    try:
        credential = DefaultAzureCredential()
        _DOC_INTEL_CLIENT = DocumentIntelligenceClient(endpoint=endpoint, credential=credential)
        return _DOC_INTEL_CLIENT
    except Exception as e:
        logging.warning(f"Managed Identity authentication failed: {e}")

    key = os.environ.get("DOCUMENT_INTELLIGENCE_KEY")
    if key:
        credential = AzureKeyCredential(key)
        _DOC_INTEL_CLIENT = DocumentIntelligenceClient(endpoint=endpoint, credential=credential)
        return _DOC_INTEL_CLIENT

    raise ValueError(
        "Either Managed Identity must be configured or DOCUMENT_INTELLIGENCE_KEY environment variable is required"
    )


def http_json(data: Any, status_code: int = 200) -> func.HttpResponse:
    """Create a JSON HttpResponse with consistent headers."""
    return func.HttpResponse(
        json.dumps(data),
        status_code=status_code,
        mimetype="application/json",
    )


def http_error(message: str, status_code: int) -> func.HttpResponse:
    """Create a standardized JSON error response."""
    return http_json({"error": message}, status_code)


def generate_base_document_id(source_url: Optional[str] = None, max_length: int = 1024) -> str:
    """
    Generate the base document ID from source URL (without page/chunk info).
    
    Azure AI Search document keys must:
    - Be 1024 characters or less
    - Contain only letters, numbers, dashes (-), underscores (_), and equal signs (=)
    - Be URL-safe for the Lookup API
    
    Args:
        source_url: Optional source URL of the document
        max_length: Maximum length for the document ID (default 1024)
    
    Returns:
        A valid base document ID that's deterministic and unique
    """
    if source_url:
        # Normalize the URL for consistent hashing
        parsed = urllib.parse.urlparse(source_url.lower().strip())
        normalized_url = urllib.parse.urlunparse((
            parsed.scheme,
            parsed.netloc,
            parsed.path.rstrip('/'),
            '',  # Remove params
            parsed.query,
            ''   # Remove fragment
        ))
        
        # Create hash of normalized URL (using full hash for zero collision risk)
        url_hash = hashlib.sha256(normalized_url.encode('utf-8')).hexdigest()
        base_document_id = f"doc_{url_hash}"
    else:
        # Fallback for when no URL is provided
        timestamp = datetime.datetime.utcnow().strftime("%Y%m%d_%H%M%S")
        base_document_id = f"doc_{timestamp}"
    
    # Ensure it meets Azure AI Search requirements
    if len(base_document_id) > max_length:
        # Truncate while keeping the doc_ prefix
        base_document_id = base_document_id[:max_length]
    
    return base_document_id


def generate_chunk_id(source_url: Optional[str] = None, page_number: int = 1, max_length: int = 1024) -> str:
    """
    Generate a complete chunk ID with chunk/page identifier.
    
    Args:
        source_url: Optional source URL of the document
        page_number: Page/chunk number for multi-page documents
        max_length: Maximum length for the document ID (default 1024)
    
    Returns:
        A valid chunk ID that's deterministic and unique with chunk identifier
    """
    base_id = generate_base_document_id(source_url, max_length)
    chunk_id = f"_chunk_{page_number}"
    document_id = f"{base_id}{chunk_id}"
    
    # Ensure it meets Azure AI Search requirements
    if len(document_id) > max_length:
        # Truncate base while keeping the chunk identifier
        prefix_length = max_length - len(chunk_id)
        document_id = base_id[:prefix_length] + chunk_id
    
    return document_id


def generate_chunk_id_from_base(base_document_id: str, page_number: int = 1, max_length: int = 1024) -> str:
    """Generate a chunk ID using a precomputed base_document_id and a page number."""
    chunk_id = f"_chunk_{page_number}"
    document_id = f"{base_document_id}{chunk_id}"
    if len(document_id) > max_length:
        prefix_length = max_length - len(chunk_id)
        document_id = base_document_id[:prefix_length] + chunk_id
    return document_id


def count_tokens(text: str) -> int:
    """
    Count tokens for embedding models using tiktoken.
    Uses cl100k_base encoding which is compatible with all Azure OpenAI embedding models.
    """
    try:
        tokenizer = tiktoken.get_encoding("cl100k_base")
        return len(tokenizer.encode(text))
    except Exception as e:
        logging.warning(f"Token counting failed: {e}")
        # Fallback approximation: ~4 characters per token for English text
        return len(text) // 4


def group_pages_for_batch_embedding(
    pages: List[Dict[str, Any]], 
    max_tokens_per_batch: int = 7500,  # Buffer under 8,191 limit
    max_items_per_batch: int = 2000    # Buffer under 2048 limit
) -> List[Dict[str, Any]]:
    """
    Group pages into batches for Azure OpenAI embedding API.
    Adds 'batch_index' field to each page.
    
    Args:
        pages: List of page dictionaries with token_count
        max_tokens_per_batch: Maximum tokens per batch (default: 7500)
        max_items_per_batch: Maximum items per batch (default: 2000)
    
    Returns:
        Updated pages list with 'batch_index' field added to each page
    """
    current_batch = 0
    current_tokens = 0
    current_items = 0
    
    for page in pages:
        page_tokens = page['token_count']
        
        # Check if adding this page would exceed limits
        if (current_tokens + page_tokens > max_tokens_per_batch or 
            current_items >= max_items_per_batch):
            # Start new batch
            current_batch += 1
            current_tokens = 0
            current_items = 0
        
        # Add page to current batch
        page['batch_index'] = current_batch
        current_tokens += page_tokens
        current_items += 1
    
    return pages




@app.function_name("index_documents")
@app.route(route="index-documents", methods=["POST"])
def index_documents_endpoint(req: func.HttpRequest) -> func.HttpResponse:
    """
    HTTP endpoint to index an array of documents into Azure AI Search using mergeOrUpload.

    Env vars required:
      - AZURE_SEARCH_SERVICE_ENDPOINT
      - AZURE_SEARCH_INDEX_NAME
      - AZURE_SEARCH_API_KEY (optional if using Managed Identity/RBAC)

    Request body: JSON array of documents matching the target index schema.
    Response: Summary of indexing results per document and batch-level counters.
    """
    try:
        try:
            body = req.get_json()
        except Exception:
            return http_error("Invalid JSON in request body; expected an array of documents", 400)

        if not isinstance(body, list):
            return http_error("Request body must be a JSON array of documents", 400)

        if not body:
            return http_error("No documents provided", 400)

        # Normalize published_date across documents
        normalized_dates: List[Optional[str]] = []
        for d in body:
            if "published_date" in d:
                d["published_date"] = normalize_published_date_value(d.get("published_date"))
                normalized_dates.append(d.get("published_date"))
        # Validate docs shape
        validation_errors = validate_documents_shape(body)
        if validation_errors:
            return http_json({
                "indexed": 0,
                "failed": len(body),
                "results": [],
                "errors": validation_errors
            }, 400)

        client = get_search_client()

        batches = chunk_documents_for_indexing(body)
        all_results = []
        total_indexed = 0
        total_failed = 0
        warnings: List[str] = []
        # Add a warning if multiple distinct non-null published_date values are present
        distinct_dates = {nd for nd in normalized_dates if nd is not None}
        if len(distinct_dates) > 1:
            warnings.append("Multiple distinct published_date values detected in request; documents will be indexed as provided.")

        for b_idx, batch in enumerate(batches):
            try:
                # Use merge_or_upload for idempotency; change to upload/merge/delete if needed later
                results = client.merge_or_upload_documents(documents=batch)
                # results: List[IndexingResult]
                for r in results:
                    item = {
                        "key": r.key,
                        "succeeded": r.succeeded,
                        "statusCode": getattr(r, "status_code", None),
                        "errorMessage": getattr(r, "error_message", None)
                    }
                    all_results.append(item)
                    if r.succeeded:
                        total_indexed += 1
                    else:
                        total_failed += 1
            except Exception as e:
                logging.error(f"Batch {b_idx} indexing error: {e}")
                # Mark entire batch as failed with generic error
                for d in batch:
                    all_results.append({
                        "key": d.get("id"),
                        "succeeded": False,
                        "statusCode": None,
                        "errorMessage": str(e)
                    })
                total_failed += len(batch)

        response = {
            "indexed": total_indexed,
            "failed": total_failed,
            "batches": {
                "count": len(batches),
                "totalDocs": len(body)
            },
            "results": all_results
        }
        if warnings:
            response["warnings"] = warnings
        # Return 200 only if all documents succeeded; otherwise return 500
        status = 200 if total_failed == 0 else 500
        return http_json(response, status)

    except ValueError as ve:
        logging.error(f"Configuration error: {ve}")
        return http_error(f"Configuration error: {str(ve)}", 500)
    except AzureError as ae:
        logging.error(f"Azure Search error: {ae}")
        return http_error(f"Search indexing failed: {str(ae)}", 502)
    except Exception as e:
        logging.error(f"Unexpected error indexing documents: {e}")
        return http_error(f"Internal server error: {str(e)}", 500)


def split_markdown_by_pages(full_markdown: str, source_url: Optional[str] = None) -> List[Dict[str, Any]]:
    """
    Split the full markdown content by page breaks using HTML comments.
    Document Intelligence includes <!-- PageBreak --> comments to mark page boundaries.
    
    Args:
        full_markdown: The full markdown content with page break comments
        source_url: Optional source URL for generating document IDs
        
    Returns:
        List of dictionaries with page_number, markdown_content, token_count, and document_id
    """
    # Split by PageBreak comments
    page_sections = full_markdown.split('<!-- PageBreak -->')
    
    pages = []
    base_id = generate_base_document_id(source_url)

    for i, section in enumerate(page_sections):
        if not section.strip():
            continue

        # Extract page number from PageNumber comment if present
        page_number = i + 1  # Default fallback
        page_number_match = re.search(r'<!-- PageNumber="(\d+)" -->', section)
        if page_number_match:
            page_number = int(page_number_match.group(1))

        # Clean up the content by removing page metadata comments
        content = section.strip()
        content = re.sub(r'<!-- (PageNumber|PageHeader|PageFooter)="[^"]*" -->\s*', '', content)
        content = content.strip()

        if content:  # Only add non-empty pages
            pages.append({
                "document_id": generate_chunk_id_from_base(base_id, page_number),
                "page_number": page_number,
                "markdown_content": content,
                "token_count": count_tokens(content)
            })
    
    # Group pages into batches for embedding API
    pages = group_pages_for_batch_embedding(pages)
    
    return pages


@app.function_name("generate_document_id_endpoint")
@app.route(route="generate-document-id", methods=["POST"])
def generate_document_id_endpoint(req: func.HttpRequest) -> func.HttpResponse:
    """
    Azure Function endpoint to generate base document IDs for Azure AI Search.
    
    Expected input (POST with JSON body):
    - source_url: URL of the source document
    
    Returns: JSON object with base_document_id
    """
    try:
        logging.info("Processing document ID generation request")

        # Get JSON body
        try:
            req_body = req.get_json()
        except Exception:
            return http_error("Invalid JSON in request body", 400)

        if not req_body:
            return http_error("Request body is required", 400)

        source_url = req_body.get('source_url')
        if not source_url:
            return http_error("source_url is required", 400)
        
        # Generate the base document ID
        base_document_id = generate_base_document_id(source_url)
        
        response_data = {
            "base_document_id": base_document_id,
            "source_url": source_url
        }
        
        logging.info(f"Generated base document ID: {base_document_id}")

        return http_json(response_data, 200)
        
    except Exception as e:
        logging.error(f"Error generating document ID: {e}")
        return func.HttpResponse(
            json.dumps({"error": f"Internal server error: {str(e)}"}),
            status_code=500,
            mimetype="application/json"
        )


@app.function_name("process_document_to_markdown")
@app.route(route="process-document", methods=["POST"])
def process_document_to_markdown(req: func.HttpRequest) -> func.HttpResponse:
    """
    Azure Function that processes document binary data and returns page-split markdown with document-level analysis.
    
    Expected input: 
    - Raw binary file data in request body
    - Optional query parameter 'source_url' for document ID generation
    
    Returns: JSON object with:
    - document_summary: Object with base_document_id, total_pages, total_tokens, summary, key_topics, document_type, analysis_status
    - pages: Array of page objects with document_id, page_number, markdown_content, token_count, and batch_index
    """
    try:
        logging.info("Processing document conversion request")

        # Get optional source URL parameter
        source_url = req.params.get('source_url')

        # Validate request
        if not req.get_body():
            return http_error("Request body is empty. Please provide document binary data.", 400)

        # Get document binary data
        document_bytes = req.get_body()
        logging.info(f"Received document of size: {len(document_bytes)} bytes")

        # Get Document Intelligence client
        client = get_document_intelligence_client()

        # Analyze document with Layout model and markdown output
        logging.info("Starting document analysis with Document Intelligence")

        # Create document stream from binary data
        document_stream = io.BytesIO(document_bytes)

        # Analyze document using Layout model with markdown output
        poller = client.begin_analyze_document(
            model_id="prebuilt-layout",
            body=document_stream,
            output_content_format="markdown"
        )

        # Wait for completion
        result = poller.result()
        logging.info("Document analysis completed successfully")

        # Get the full markdown content
        full_markdown = result.content if hasattr(result, 'content') else ""

        # Split markdown content by page breaks (using HTML comments)
        pages = split_markdown_by_pages(full_markdown, source_url)

        # Analyze document content for document-level attributes
        try:
            logging.info("Starting document analysis for summary and attributes")
            document_summary = analyze_document_content(full_markdown, pages)
            document_summary["base_document_id"] = generate_base_document_id(source_url)
            logging.info("Document analysis completed successfully")
        except Exception as e:
            logging.warning(f"Document analysis failed: {e}")
            # Fallback: basic summary with error info
            document_summary = {
                "base_document_id": generate_base_document_id(source_url),
                "total_pages": len(pages),
                "total_tokens": sum(page["token_count"] for page in pages),
                "summary": None,
                "key_topics": [],
                "document_type": "Unknown",
                "analysis_status": "failed",
                "error": str(e)
            }

        # Enhanced response structure
        response_data = {
            "document_summary": document_summary,
            "pages": pages
        }

        logging.info(f"Successfully processed document with {len(pages)} pages and document-level analysis")

        return http_json(response_data, 200)

    except ValueError as ve:
        logging.error(f"Configuration error: {ve}")
        return http_error(f"Configuration error: {str(ve)}", 500)

    except AzureError as ae:
        logging.error(f"Azure Document Intelligence error: {ae}")
        return http_error(f"Document processing failed: {str(ae)}", 502)

    except Exception as e:
        logging.error(f"Unexpected error processing document: {e}")
        return http_error(f"Internal server error: {str(e)}", 500)