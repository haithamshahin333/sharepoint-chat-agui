"use client";

import { useState } from "react";
import { CopilotChat } from "@copilotkit/react-ui";
import {
  useCopilotAction,
  CatchAllActionRenderProps,
  useCopilotChat,
} from "@copilotkit/react-core";
import { TextMessage, Role } from "@copilotkit/runtime-client-gql";
import { useCategoryContext } from "./components/AuthenticatedCopilotProvider";
import { useMarkdownRenderers } from "./components/MarkdownRenderers";
import { getCategoryConfig } from "./lib/categoryConfig";

const PDFModal = ({ url, isOpen, onClose }: { url: string; isOpen: boolean; onClose: () => void }) => {
  if (!isOpen) return null;
  
  // Debug log for PDF URL
  console.log('PDFModal - Loading PDF URL:', url);
  
  return (
    <div className="flex flex-col h-full w-full bg-white border-l border-gray-200">
      {/* Header with close button and title */}
      <div className="flex items-center justify-between p-4 border-b border-gray-200 bg-gray-50 flex-shrink-0">
        <h3 className="text-lg font-semibold text-gray-800">PDF Document</h3>
        <button 
          onClick={onClose}
          className="p-2 rounded-full hover:bg-gray-200 transition-colors duration-200"
          aria-label="Close PDF"
        >
          <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
          </svg>
        </button>
      </div>
      
      {/* PDF iframe container */}
      <div className="flex-1 overflow-hidden">
        <iframe 
          src={url} 
          className="w-full h-full border-0"
          title="PDF Document"
        />
      </div>
    </div>
  );
};

const CategorySelector = ({ 
  selectedCategory, 
  onCategoryChange 
}: { 
  selectedCategory: string; 
  onCategoryChange: (category: string) => void;
}) => {
  const { categories } = getCategoryConfig();

  return (
    <div className="flex items-center gap-2 p-3 bg-gray-50 border-b border-gray-200 flex-shrink-0">
      <span className="text-sm font-medium text-gray-700">Search Category:</span>
      <div className="flex gap-1">
        {categories.map((category) => (
          <button
            key={category.value}
            onClick={() => onCategoryChange(category.value)}
            className={`
              inline-flex items-center gap-1 px-3 py-1 text-xs font-medium rounded-full border transition-colors duration-200
              ${selectedCategory === category.value
                ? "bg-blue-100 text-blue-800 border-blue-300 shadow-sm"
                : "bg-white text-gray-600 border-gray-300 hover:bg-gray-100 hover:border-gray-400"
              }
            `}
          >
            <span>{category.label}</span>
          </button>
        ))}
      </div>
    </div>
  );
};

export default function CopilotKitPage() {
  return <Chat />;
}

const Chat = () => {
  // Exact dojo default - starts with CSS variable for white background
  const background = "var(--copilot-kit-background-color)";

  // Get access to the chat functions for sending messages
  const { appendMessage } = useCopilotChat();

  // PDF modal state
  const [pdfModal, setPdfModal] = useState<{ url: string; isOpen: boolean }>({
    url: "",
    isOpen: false
  });

  // Get category selection from context (now handled via properties)
  const { selectedCategory, setSelectedCategory } = useCategoryContext();

  // Custom markdown renderers for enhanced footnote display
  const customMarkdownTagRenderers = useMarkdownRenderers({
    onSendMessage: (message: string) => {
      appendMessage(new TextMessage({ 
        content: message, 
        role: Role.User 
      }));
    },
    onOpenPdf: (url: string) => {
      setPdfModal({ url, isOpen: true });
    }
  });

  // Catch-all action to render tool calls from the agent
  useCopilotAction({
    name: "*",
    render: ({ name, args, status, result }: CatchAllActionRenderProps<[]>) => {
      return (
        <div className="m-4 p-4 bg-gray-100 rounded shadow">
          <h2 className="text-sm font-medium">Tool: {name}</h2>
          
          {/* Arguments */}
          <div className="mt-2">
            <h3 className="text-xs font-medium text-gray-600">Arguments:</h3>
            <pre className="mt-1 text-xs overflow-auto bg-gray-50 p-2 rounded">
              {JSON.stringify(args, null, 2)}
            </pre>
          </div>
          
          {/* Result - only shown when complete */}
          {status === "complete" && result && (
            <div className="mt-2">
              <h3 className="text-xs font-medium text-gray-600">Response:</h3>
              <pre className="mt-1 text-xs overflow-auto bg-blue-50 p-2 rounded">
                {typeof result === 'string' ? result : JSON.stringify(result, null, 2)}
              </pre>
            </div>
          )}
          
          {status === "complete" && (
            <div className="mt-2 text-xs text-green-600">✓ Complete</div>
          )}``
        </div>
      );
    },
  });

  return (
    <div className="flex justify-center items-center h-full w-full" style={{ background }}>
      <div className="w-[90%] h-[90%] rounded-lg overflow-hidden">
        {/* Single Flexible Layout */}
        <div className={`
          flex h-full bg-white shadow-lg
          ${pdfModal.isOpen ? 'rounded-lg' : 'rounded-2xl'}
        `}>
          {/* Chat container - adjusts based on PDF state */}
          <div className={`
            flex flex-col min-h-0
            ${pdfModal.isOpen 
              ? 'flex-1 min-w-0 border-r border-gray-200' 
              : 'w-full'
            }
          `}>
            <CategorySelector 
              selectedCategory={selectedCategory}
              onCategoryChange={setSelectedCategory}
            />
            <div className="flex-1 min-h-0">
              <CopilotChat
                className="h-full"
                labels={{ initial: "Hi, I'm an agent. Want to chat?" }}
                markdownTagRenderers={customMarkdownTagRenderers}
                makeSystemMessage={() => ""}
              />
            </div>
          </div>
          
          {/* PDF container - only rendered when modal is open */}
          {pdfModal.isOpen && (
            <div className="flex-1 min-w-0">
              <PDFModal 
                url={pdfModal.url} 
                isOpen={pdfModal.isOpen} 
                onClose={() => setPdfModal({ url: "", isOpen: false })} 
              />
            </div>
          )}
        </div>
      </div>
    </div>
  );
};
