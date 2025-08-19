"""
Centralized prompt templates for document analysis.
Contains all LLM prompts used across document analysis functions to eliminate duplication
and provide a single source of truth for prompt engineering.
"""


class DocumentAnalysisPrompts:
    """Centralized prompt templates for document analysis operations."""
    
    # Base instruction components (reusable building blocks)
    SUMMARY_INSTRUCTIONS = "Select and organize the most important sentences and phrases directly from the text. Do not paraphrase - use exact wording from the document. Focus on key findings, conclusions, and important statements."
    
    TOPICS_INSTRUCTIONS = "Extract the 10 most important topics, themes, or subject areas covered in the document."
    
    DOCUMENT_TYPE_CATEGORIES = """Choose the most appropriate category:
- Report (research, business, technical, etc.)
- Manual (user guide, instructions, procedures)
- Policy (guidelines, regulations, standards) 
- Presentation (slides, training materials)
- Legal (contract, agreement, legal document)
- Financial (statements, budgets, financial reports)
- Academic (research paper, thesis, educational content)
- Marketing (brochures, proposals, marketing materials)
- Technical (specifications, documentation, technical guides)
- Other (if none of the above fit well)"""
    
    PUBLISHED_DATE_BASE = "Look for any dates that indicate when the document was published, created, or released. Return in MM-DD-YYYY format. If no date can be found, return '00-00-0000'."
    
    PUBLISHED_DATE_LOCATIONS = """Common locations for publication dates:
- Document headers or title pages
- Copyright notices
- Article dates
- Version dates
- Release dates
- Creation dates"""
    
    PUBLISHED_DATE_RULES = """Return the date in MM-DD-YYYY format.
If no publication date can be found, return '00-00-0000'.
If the DD is not available, use '01' for the day.
If the MM is not available, use '01' for the month.

Do not guess, only return a date if it is explicitly stated in the text or in data provided about the file. Otherwise return '00-00-0000'."""



    # Individual analysis prompts
    @classmethod
    def get_published_date_extraction(cls):
        return f"""You are an expert at extracting publication dates from documents. {cls.PUBLISHED_DATE_BASE}

{cls.PUBLISHED_DATE_LOCATIONS}

{cls.PUBLISHED_DATE_RULES}"""

    @classmethod
    def get_document_type_classification(cls):
        return f"You are an expert document classifier. Analyze the document excerpt and classify its type.\n\n{cls.DOCUMENT_TYPE_CATEGORIES}"

    @classmethod
    def get_topic_extraction(cls, max_topics: int, content_source: str):
        return f"You are an expert at extracting key topics from documents. Analyze the following document {content_source} and extract the {max_topics} most important topics, themes, or subject areas covered."

    # Map-reduce summary extraction templates
    MAP_EXTRACTION_TEMPLATE = """Extract the most important sentences and key phrases directly from this document section. Use the exact wording from the text - do not paraphrase or rewrite.

Focus on:
- Key statements, conclusions, or findings
- Important facts, data, or decisions
- Critical information or main points

Use only the original text from the section.

Document section:
{text}

Extracted Key Content:"""

    REDUCE_COMBINATION_TEMPLATE = """Based on the following extracted content from each document section, create a comprehensive extractive summary by organizing the most important extracted sentences and phrases.

Instructions:
- Use the exact wording from the section extracts provided
- Organize the content to show overall document flow and key themes
- Maintain original terminology and phrasing
- Focus on the most critical extracted information across all sections
- Do not add new interpretations - only reorganize the extracted content

Section extracts:
{text}

Final Extractive Summary:"""
