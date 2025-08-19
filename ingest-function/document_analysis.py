"""
Document analysis utilities using LangChain and Azure OpenAI.
Provides document-level analysis including summarization, topic extraction, and document type detection.

Enhanced with structured outputs using Pydantic schemas for reliable response parsing.
Features:
- Single-shot analysis for documents < 100K tokens using structured outputs
- Map-reduce approach for larger documents 
- Pydantic models ensure type safety and validation
- Token-aware routing for optimal performance
"""

import os
import logging
import re
from typing import Dict, List, Any
from azure.identity import DefaultAzureCredential, get_bearer_token_provider

# LangChain imports
from langchain_openai import AzureChatOpenAI
from langchain.prompts import PromptTemplate, ChatPromptTemplate
from langchain_text_splitters import RecursiveCharacterTextSplitter
from langchain_core.output_parsers import StrOutputParser

# Pydantic for structured outputs
from pydantic import BaseModel, Field

# Centralized prompts
from analysis_prompts import DocumentAnalysisPrompts


# Pydantic models for structured outputs
class DocumentAnalysis(BaseModel):
    """Structured document analysis result."""
    summary: str = Field(
        description="Extractive summary using exact sentences and phrases from the document"
    )
    key_topics: List[str] = Field(
        description="List of 10 most important topics, themes, or subject areas covered",
        max_items=10
    )
    document_type: str = Field(
        description="Document type classification: Report, Manual, Policy, Presentation, Legal, Financial, Academic, Marketing, Technical, or Other"
    )
    published_date: str = Field(
        description="Published date in MM-DD-YYYY format. If no date can be found, return '00-00-0000'"
    )


"""
Simplified: We keep one structured output (DocumentAnalysis) and use it for all
paths. For large documents we first produce an extractive map-reduce summary and
then run the structured analysis on that summary to derive topics/type/date.
"""


def get_azure_openai_client() -> AzureChatOpenAI:
    """
    Create Azure OpenAI client using managed identity authentication.
    
    Returns:
        AzureChatOpenAI: Configured client for Azure OpenAI
    """
    endpoint = os.environ.get("AZURE_OPENAI_ENDPOINT")
    deployment_name = os.environ.get("AZURE_OPENAI_DEPLOYMENT_NAME") 
    api_version = os.environ.get("AZURE_OPENAI_API_VERSION", "2024-10-21")
    
    if not endpoint:
        raise ValueError("AZURE_OPENAI_ENDPOINT environment variable is required")
    if not deployment_name:
        raise ValueError("AZURE_OPENAI_DEPLOYMENT_NAME environment variable is required")
    
    # Create token provider using managed identity
    credential = DefaultAzureCredential()
    token_provider = get_bearer_token_provider(
        credential, 
        "https://cognitiveservices.azure.com/.default"
    )
    
    # Create Azure OpenAI client
    return AzureChatOpenAI(
        azure_endpoint=endpoint,
        azure_deployment=deployment_name,
        api_version=api_version,
        azure_ad_token_provider=token_provider,
        temperature=0.3,  # Low temperature for consistent analysis
        max_tokens=4000   # Allow for detailed summaries
    )


def generate_single_shot_analysis(content: str, llm: AzureChatOpenAI) -> Dict[str, Any]:
    """
    Generate complete document analysis in one shot for content under 100K tokens.
    Uses structured outputs with Pydantic schemas for reliable parsing.
    
    Args:
        content: Full document content
        llm: Azure OpenAI client
        
    Returns:
        Dictionary with summary, key_topics, and document_type
    """
    try:
        # Create structured LLM with Pydantic schema
        structured_llm = llm.with_structured_output(DocumentAnalysis)
        
        # Create the prompt using ChatPromptTemplate for better control
        prompt = ChatPromptTemplate.from_messages([
            ("system", f"""You are an expert document analyst. Your task is to analyze documents and provide structured analysis.

{DocumentAnalysisPrompts.get_published_date_extraction()}

{DocumentAnalysisPrompts.get_document_type_classification()}

For key topics: {DocumentAnalysisPrompts.TOPICS_INSTRUCTIONS}

For summary: {DocumentAnalysisPrompts.SUMMARY_INSTRUCTIONS}"""),
            ("human", "Please analyze the following document:\n\n{content}")
        ])
        
        # Create the chain and invoke
        chain = prompt | structured_llm
        result = chain.invoke({"content": content})
        
        # Convert Pydantic model to dictionary
        return {
            "summary": result.summary,
            "key_topics": result.key_topics,
            "document_type": result.document_type,
            "published_date": result.published_date
        }
        
    except Exception as e:
        logging.error(f"Structured output analysis failed: {e}")
        # Return minimal error response
        return {
            "summary": "Analysis failed",
            "key_topics": [],
            "document_type": "Unknown",
            "published_date": "00-00-0000"
        }


def generate_map_reduce_summary(content: str, llm: AzureChatOpenAI, total_tokens: int) -> str:
    """
    Generate summary using map-reduce approach for large documents (>= 100K tokens).
    Uses LangChain's RecursiveCharacterTextSplitter for intelligent token-based chunking.
    
    Args:
        content: Full document content  
        llm: Azure OpenAI client
        total_tokens: Total token count for the document
        
    Returns:
        Generated summary
    """
    # Decide whether to chunk the content or use it as-is
    if total_tokens > 100000:
        # Split into practical token-sized chunks before map-reduce
        logging.info(
            f"Splitting {total_tokens} tokens using RecursiveCharacterTextSplitter (token-based)"
        )
        text_splitter = RecursiveCharacterTextSplitter.from_tiktoken_encoder(
            encoding_name="cl100k_base",
            chunk_size=50000,
            chunk_overlap=500,
            separators=["\n\n", "\n", ". ", "? ", "! ", " ", ""]
        )
        content_chunks = text_splitter.split_text(content)
    else:
        # Use content as single chunk for smaller documents
        content_chunks = [content]
    
    # Map phase: Summarize each chunk using modern pipe operator
    map_prompt = PromptTemplate(template=DocumentAnalysisPrompts.MAP_EXTRACTION_TEMPLATE, input_variables=["text"])
    parser = StrOutputParser()
    map_chain = map_prompt | llm | parser
    
    # Generate chunk summaries
    chunk_summaries = []
    for i, chunk in enumerate(content_chunks, 1):
        try:
            summary = map_chain.invoke({"text": chunk})
            chunk_summaries.append(f"Section {i}: {summary.strip()}")
        except Exception as e:
            logging.warning(f"Failed to summarize chunk {i}: {e}")
            # Include chunk without summary as fallback
            chunk_summaries.append(f"Section {i}: [Summary generation failed]")
    
    # Reduce phase: Combine chunk summaries into final summary using modern pipe operator
    reduce_prompt = PromptTemplate(template=DocumentAnalysisPrompts.REDUCE_COMBINATION_TEMPLATE, input_variables=["text"])
    reduce_chain = reduce_prompt | llm | parser
    
    # Combine all chunk summaries
    combined_summaries = "\n\n".join(chunk_summaries)
    final_summary = reduce_chain.invoke({"text": combined_summaries})

    # Sanitize quotes and ensure a single aggregated summary without extraneous quoting
    return _clean_summary_text(final_summary)


def analyze_document_content(full_markdown: str, pages: List[Dict[str, Any]]) -> Dict[str, Any]:
    """
    Analyze document content and generate document-level attributes.
    
    Args:
        full_markdown: Complete markdown content from Document Intelligence
        pages: List of page objects with token counts
        
    Returns:
        Document-level analysis including summary, topics, etc.
        Returns error info if analysis fails but doesn't raise exceptions.
    """
    try:
        # Calculate total metrics
        total_pages = len(pages)
        total_tokens = sum(page["token_count"] for page in pages)
        
        # Get Azure OpenAI client
        llm = get_azure_openai_client()
        
        # Determine analysis strategy based on token count
        if total_tokens < 100000:
            logging.info(f"Using single-shot structured analysis for {total_tokens} tokens")
            analysis_result = generate_single_shot_analysis(full_markdown, llm)
        else:
            logging.info(
                f"Using map-reduce to produce extractive summary, then single structured analysis for {total_tokens} tokens"
            )
            summary_text = generate_map_reduce_summary(full_markdown, llm, total_tokens)
            analysis_result = generate_single_shot_analysis(summary_text, llm)

        summary = analysis_result.get("summary")
        if isinstance(summary, str):
            summary = _clean_summary_text(summary)
        key_topics = analysis_result.get("key_topics", [])
        document_type = analysis_result.get("document_type", "Unknown")
        published_date = analysis_result.get("published_date", "00-00-0000")
        
        return {
            "total_pages": total_pages,
            "total_tokens": total_tokens,
            "summary": summary,
            "key_topics": key_topics,
            "document_type": document_type,
            "published_date": published_date,
            "analysis_status": "success"
        }
        
    except Exception as e:
        logging.error(f"Document analysis failed: {e}")
        # Return basic metrics with error info
        return {
            "total_pages": len(pages),
            "total_tokens": sum(page.get("token_count", 0) for page in pages),
            "summary": None,
            "key_topics": [],
            "document_type": "Unknown",
            "published_date": "00-00-0000",
            "analysis_status": "failed",
            "error": str(e)
        }


def _clean_summary_text(text: str) -> str:
    """Clean up LLM-produced summaries by removing extraneous quotes and
    normalizing any remaining quotes to single quotes.

    Rules:
    - Trim whitespace
    - Remove matching leading/trailing quotes (", ', “ ”)
    - Remove quotes that wrap entire lines (common after reduce)
    - Convert remaining double quotes to single quotes
    - Collapse excessive blank lines
    """
    if not isinstance(text, str):
        return text

    s = (text or "").strip()

    # Strip matching leading/trailing quotes
    if (s.startswith('"') and s.endswith('"')) or (s.startswith('“') and s.endswith('”')) or (
        s.startswith("'") and s.endswith("'")
    ):
        s = s[1:-1].strip()

    # Clean per-line quoting and normalize internal quotes
    cleaned_lines: List[str] = []
    for line in s.splitlines():
        l = line.strip()
        # Remove wrapping quotes on the line
        if (l.startswith('"') and l.endswith('"')) or (l.startswith('“') and l.endswith('”')) or (
            l.startswith("'") and l.endswith("'")
        ):
            l = l[1:-1].strip()
        # Strip stray unicode or ascii quotes at ends then convert remaining " to '
        l = l.strip('"“”')
        l = l.replace('"', "'")
        cleaned_lines.append(l)

    s = "\n".join(cleaned_lines)
    # Collapse 3+ newlines to max 2
    s = re.sub(r"\n{3,}", "\n\n", s)
    return s.strip()
