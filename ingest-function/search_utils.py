import json
import logging
import os
import re
import datetime
from typing import Any, Dict, List, Optional

from azure.identity import DefaultAzureCredential
from azure.core.credentials import AzureKeyCredential
from azure.search.documents import SearchClient


_SEARCH_CLIENT: Optional[SearchClient] = None


def get_search_client() -> SearchClient:
    """Return a cached Azure AI Search SearchClient. Prefer Managed Identity (RBAC), fallback to API key.

    Requires environment variables:
      - AZURE_SEARCH_SERVICE_ENDPOINT
      - AZURE_SEARCH_INDEX_NAME
      - AZURE_SEARCH_API_KEY (optional if using Managed Identity/RBAC)
    """
    global _SEARCH_CLIENT
    if _SEARCH_CLIENT is not None:
        return _SEARCH_CLIENT

    endpoint = os.environ.get("AZURE_SEARCH_SERVICE_ENDPOINT")
    index_name = os.environ.get("AZURE_SEARCH_INDEX_NAME")
    if not endpoint or not index_name:
        raise ValueError("AZURE_SEARCH_SERVICE_ENDPOINT and AZURE_SEARCH_INDEX_NAME environment variables are required")

    # Try DefaultAzureCredential first (requires Search Index Data Contributor/Reader roles as applicable)
    try:
        credential = DefaultAzureCredential()
        _SEARCH_CLIENT = SearchClient(endpoint=endpoint, index_name=index_name, credential=credential)
        return _SEARCH_CLIENT
    except Exception as e:
        logging.warning(f"Managed Identity authentication for SearchClient failed: {e}")

    api_key = os.environ.get("AZURE_SEARCH_API_KEY")
    if api_key:
        _SEARCH_CLIENT = SearchClient(endpoint=endpoint, index_name=index_name, credential=AzureKeyCredential(api_key))
        return _SEARCH_CLIENT

    raise ValueError(
        "Either Managed Identity (RBAC) must be configured or AZURE_SEARCH_API_KEY environment variable is required for SearchClient"
    )


def estimate_json_size_bytes(obj: Any) -> int:
    """Rough estimate of JSON size of an object in bytes."""
    try:
        return len(json.dumps(obj, ensure_ascii=False).encode("utf-8"))
    except Exception:
        return 0


def chunk_documents_for_indexing(
    docs: List[Dict[str, Any]], max_docs: int = 1000, max_bytes: int = 16 * 1024 * 1024
) -> List[List[Dict[str, Any]]]:
    """Split documents into batches under Azure limits: ≤1000 docs and ≤16 MB per batch."""
    batches: List[List[Dict[str, Any]]] = []
    current: List[Dict[str, Any]] = []
    current_bytes = 0

    for doc in docs:
        doc_bytes = estimate_json_size_bytes(doc)
        if (len(current) + 1 > max_docs) or (current_bytes + doc_bytes > max_bytes and current):
            batches.append(current)
            current = []
            current_bytes = 0
        current.append(doc)
        current_bytes += doc_bytes

    if current:
        batches.append(current)
    return batches


def validate_documents_shape(docs: List[Dict[str, Any]]) -> List[str]:
    """Basic validation: ensure id exists; optional vector length (1536) check if provided."""
    errors: List[str] = []
    for i, d in enumerate(docs):
        if "id" not in d or not d["id"]:
            errors.append(f"Document at index {i} is missing required 'id'.")
        if "vector" in d and d["vector"] is not None:
            vec = d["vector"]
            if not isinstance(vec, list):
                errors.append(f"Document id {d.get('id')} 'vector' must be a list of floats.")
            else:
                if len(vec) != 1536:
                    errors.append(f"Document id {d.get('id')} 'vector' length is {len(vec)}, expected 1536.")
    return errors


def normalize_published_date_value(val: Any) -> Optional[str]:
    """Normalize published_date to ISO 8601 or None for placeholders.

    - Treat placeholders like '00-00-0000', '0000-00-00', '00/00/0000', '' as None
    - If YYYY-MM-DD, coerce to 'YYYY-MM-DDT00:00:00Z'
    - If YYYY/MM/DD, coerce to 'YYYY-MM-DDT00:00:00Z'
    - If MM-DD-YYYY or DD-MM-YYYY, coerce to 'YYYY-MM-DDT00:00:00Z' (assume MM-DD-YYYY when ambiguous)
    - If MM/DD/YYYY or DD/MM/YYYY, coerce similarly
    - If ISO 8601 with time, return as-is
    - If datetime, convert to UTC ISO string
    """
    if val is None:
        return None
    if isinstance(val, str):
        s = val.strip()
        if not s:
            return None
        if s in ("00-00-0000", "0000-00-00", "00/00/0000"):
            return None
        if re.match(r"^\d{4}-\d{2}-\d{2}T", s):
            return s
        # Try strict ISO date without time first (YYYY-MM-DD)
        if re.match(r"^\d{4}-\d{2}-\d{2}$", s):
            return f"{s}T00:00:00Z"
        # Attempt to parse common non-ISO formats and normalize to Zulu time
        date_formats = (
            "%Y/%m/%d",  # 2025/01/31
            "%m-%d-%Y",  # 01-31-2025
            "%d-%m-%Y",  # 31-01-2025
            "%m/%d/%Y",  # 01/31/2025
            "%d/%m/%Y",  # 31/01/2025
        )
        for fmt in date_formats:
            try:
                dt = datetime.datetime.strptime(s, fmt)
                dt = dt.replace(tzinfo=datetime.timezone.utc)
                return dt.isoformat().replace("+00:00", "Z")
            except ValueError:
                pass
        # Ambiguous numeric with dashes where both mm and dd <= 12: default to MM-DD-YYYY
        if re.match(r"^\d{2}-\d{2}-\d{4}$", s):
            try:
                dt = datetime.datetime.strptime(s, "%m-%d-%Y").replace(tzinfo=datetime.timezone.utc)
                return dt.isoformat().replace("+00:00", "Z")
            except ValueError:
                return None
        # If we reach here, we couldn't confidently parse the string; return None to avoid index errors
        return None
    if isinstance(val, datetime.datetime):
        dt = val
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        return dt.astimezone(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
    return None
