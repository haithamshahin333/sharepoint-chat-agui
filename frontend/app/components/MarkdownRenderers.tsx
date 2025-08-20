"use client";

import { ComponentsMap } from "@copilotkit/react-ui";

export interface MarkdownRenderersProps {
  onSendMessage: (message: string) => void;
  onOpenPdf: (url: string) => void;
}

export function useMarkdownRenderers({ 
  onSendMessage, 
  onOpenPdf 
}: MarkdownRenderersProps): ComponentsMap {
  return {
    // Custom suggestion button component for clickable follow-up questions
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    "suggestion-button": (props: any) => {
      const { text, message } = props;
      
      const handleClick = () => {
        // Send the message when button is clicked
        onSendMessage(message || text);
      };

      return (
        <button 
          onClick={handleClick}
          className="inline-flex items-center px-3 py-1 mx-1 my-1 bg-blue-100 hover:bg-blue-200 
                     text-blue-800 text-sm font-medium rounded-full border border-blue-300 
                     cursor-pointer transition-colors duration-200 hover:shadow-sm"
        >
          {text}
        </button>
      );
    },
    
    // Custom footnote reference component
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    "footnote-ref": (props: any) => {
      const { id, source } = props;
      return (
        <span className="inline-flex items-center">
          <sup className="text-blue-600 hover:text-blue-800 cursor-pointer font-medium">
            [{id}]
          </sup>
          {source && (
            <span className="ml-1 text-xs text-gray-500 max-w-xs truncate">
              {source}
            </span>
          )}
        </span>
      );
    },
    
    // Enhanced source citation component
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    "footnote-source": (props: any) => {
      const { children, id, url } = props;
      
      const handleClick = (e: React.MouseEvent) => {
        // Check if URL contains .pdf (handles fragments like #page=17)
        const isPdfUrl = url?.toLowerCase().includes('.pdf');
        console.log('footnote-source clicked:', { url, isPdfUrl });
        
        if (isPdfUrl) {
          e.preventDefault();
          console.log('Opening PDF in modal:', url);
          onOpenPdf(url);
        }
      };

      return (
        <span className="inline-flex items-center ml-2 px-2 py-1 bg-blue-50 border border-blue-200 rounded text-xs">
          <span className="font-medium text-blue-700">[{id}]</span>
          <span className="ml-1">
            {url ? (
              <a 
                href={url} 
                onClick={handleClick}
                target="_blank" 
                rel="noopener noreferrer"
                className="text-blue-600 hover:text-blue-800 underline cursor-pointer"
              >
                {children}
              </a>
            ) : (
              <span className="text-gray-700">{children}</span>
            )}
          </span>
        </span>
      );
    },
  };
}
